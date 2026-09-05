# Operations

## Day-to-day commands

Run from `/opt/wordpress-infra` unless noted.

```bash
docker compose ps
docker compose logs -f wordpress-prod
docker compose logs -f wordpress-stage
docker compose logs mariadb
docker compose logs nginx-prod
docker stats
docker system df
df -h
./scripts/healthcheck.sh
./scripts/maintenance.sh status
./scripts/maintenance.sh disk
./scripts/maintenance.sh db-status
```

Restart a single service (volumes stay):

```bash
docker compose restart wordpress-prod
docker compose restart wordpress-stage
```

## WP-CLI

The WordPress image includes WP-CLI. Run as `www-data`:

```bash
docker compose exec -u www-data wordpress-prod wp core version
docker compose exec -u www-data wordpress-stage wp core version
```

Wrappers:

```bash
./scripts/maintenance.sh wp-prod core version
./scripts/maintenance.sh wp-prod plugin list
./scripts/maintenance.sh wp-prod theme list
./scripts/maintenance.sh wp-prod cache flush
./scripts/maintenance.sh wp-prod db check
./scripts/maintenance.sh wp-stage plugin list
```

Do not install binaries into a running container. Rebuild the image if you need extra tools.

## How updates are applied

| Component | Method | Notes |
| --- | --- | --- |
| This repository (Compose, Nginx, scripts) | Git + deploy | CI or `./scripts/deploy.sh` |
| WordPress core (image) | Bump `WORDPRESS_IMAGE` / `WORDPRESS_TAG` | Deploy staging, test, backup, manual production |
| PHP version | Same image tag change (`php8.3` → `php8.4`) | Rebuild custom image |
| Plugins / themes (admin-installed) | WP-CLI or wp-admin | Runtime lives in the volume |
| Git-managed plugins / themes | `custom/` then restart PHP | Production OPcache does not re-read files until restart |
| MariaDB / Redis / Nginx | Bump `*_IMAGE` in `.env` | Staging first for Nginx/WordPress; MariaDB during a production deploy window |
| Redis object cache plugin | `./scripts/maintenance.sh enable-redis` | After first install or image rebuild |

Recommended order for image bumps:

```text
update tag in .env (on the branch)
    → merge / deploy staging
    → test http://VPS_IP:8081
    → backup-db.sh + backup-files.sh
    → manual production job
```

Never use `*:latest`.

## WordPress core, plugins, and themes

Prefer WP-CLI on staging, test, then repeat on production:

```bash
./scripts/maintenance.sh wp-stage core update
./scripts/maintenance.sh wp-stage plugin update --all
./scripts/maintenance.sh wp-stage theme update --all
./scripts/maintenance.sh wp-stage core update-db
```

Image upgrades also refresh core files in the volume via the official entrypoint. Take a database backup before that deploy.

`DISALLOW_FILE_EDIT` is on in both environments. `AUTOMATIC_UPDATER_DISABLED` is on so the VPS does not auto-write core.

## Changing database passwords after the first init

`01-init-databases.sh` does **not** run again. Example for the production app user:

```bash
docker compose exec -T mariadb sh -c \
  'mariadb -u root -p"$MYSQL_ROOT_PASSWORD" -e "ALTER USER '\''wordpress_prod_user'\''@'\''%'\'' IDENTIFIED BY '\''NEW_PASSWORD'\''; FLUSH PRIVILEGES;"'
```

Then set `PROD_DB_PASSWORD` in `.env` and recreate the WordPress container:

```bash
docker compose up -d wordpress-prod
```

If `wp-config.php` already exists, update `DB_PASSWORD` in the volume or delete only that file so the official entrypoint regenerates it (uploads are kept).

## Safe cleanup

Safe:

```bash
docker image prune -f
./scripts/maintenance.sh prune-images
docker builder prune
```

Unsafe as generic cleanup (destroys data):

```bash
docker compose down -v
docker volume prune
docker system prune --volumes
```

`docker system prune` without `--volumes` still removes unused networks and stopped containers. Do not use it as a daily habit on this host.

## Logging

```bash
docker compose logs --tail=200 mariadb
docker compose logs --since 1h wordpress-prod
```

Rotation is `10m × 5` files per service. If the disk still fills, check `backups/`, WordPress uploads, and `docker system df`.

## External monitoring

This stack does not include Prometheus or Grafana. Point an external checker at:

```text
http://VPS_IP:8080/healthz
http://VPS_IP:8081/healthz
```

and alert when `./scripts/healthcheck.sh` is non-zero from cron.

## Staging notes

- `WP_ENVIRONMENT_TYPE=staging`
- `WP_DEBUG` / `WP_DEBUG_LOG` are on; `WP_DEBUG_DISPLAY` is off
- Nginx sends `X-Robots-Tag: noindex`
- Resource limits are lower than production
