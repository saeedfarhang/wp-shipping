# Troubleshooting

## First checks

```bash
cd /opt/wordpress-infra
docker compose ps
./scripts/healthcheck.sh
docker compose logs --tail=100
df -h
docker system df
docker stats --no-stream
```

A container in `unhealthy` or `restarting` is the usual starting point. Read that service's logs before recreating anything.

## Common failures

### `healthcheck.sh` fails on HTTP

```bash
curl -v http://127.0.0.1:8080/healthz
curl -v http://127.0.0.1:8081/healthz
docker compose logs nginx-prod
docker compose logs wordpress-prod
```

- If curl to `127.0.0.1` works but the public IP does not, the firewall or cloud security group is blocking 8080/8081.
- If `/healthz` works but `/` does not, PHP-FPM or the volume is the problem, not Nginx binding.

### WordPress installer or white screen

```bash
docker compose logs wordpress-prod
docker compose exec -u www-data wordpress-prod wp core is-installed
docker compose exec wordpress-prod php -m | grep redis
```

Confirm `.env` database names match the MariaDB init values and that `mariadb` is healthy.

### Database connection errors

```bash
docker compose exec -T mariadb healthcheck.sh --connect --innodb_initialized
./scripts/maintenance.sh db-status
docker compose logs mariadb
```

Init scripts run only on an empty `mariadb_data` volume. If the volume already existed without the app users, create them manually (see [operations.md](operations.md)).

### Redis plugin reports a failure

```bash
./scripts/maintenance.sh enable-redis
docker compose exec -u www-data wordpress-prod wp redis status
docker compose exec redis-prod redis-cli ping
```

`REDISCLI_AUTH` is set in the Redis containers. From the host you cannot connect to 6379; that is intentional.

### Staging deploy restarted production

`./scripts/deploy.sh staging` uses `--no-deps` and only staging services. If you ran `./scripts/deploy.sh all` or `docker compose up -d` with no service list, Compose may recreate any service whose config changed, including production. Use the staged deploy script for day-to-day CI.

### `wp-config.php` has old credentials

The official entrypoint writes `wp-config.php` once. Changing `.env` does not rewrite it. Update the file in the volume or remove only `wp-config.php` and recreate the WordPress container.

### Disk full

```bash
df -h
docker system df
du -sh backups /var/lib/docker
```

Rotate or upload backups, then `docker image prune`. Do not `docker volume prune`.

### Permalinks 404

Nginx `try_files` sends unknown paths to `index.php`. If 404s persist:

```bash
./scripts/maintenance.sh wp-prod rewrite flush
```

and confirm the site URL uses the same `http://VPS_IP:8080` host you browse.

### GitLab deploy job cannot find `/opt/wordpress-infra`

Complete the initial clone documented in [deployment.md](deployment.md). CI does not clone into a fresh directory; it updates the existing checkout so `.env` is not wiped.

### GitLab job cannot talk to Docker

`gitlab-runner` must be in the `docker` group and the runner service restarted. `permission denied` on `/var/run/docker.sock` is this issue.

### Port already allocated

```bash
sudo ss -lntp | grep -E '8080|8081'
```

Stop the conflicting process or change `PROD_PORT` / `STAGE_PORT` (and the firewall) together.

## Recovery patterns

| Problem | Safe action |
| --- | --- |
| Bad application deploy | Revert git SHA, `./scripts/deploy.sh staging` then production |
| Bad database change | `restore-db.sh` from the last dump (production needs `--confirm-production`) |
| Broken staging after sync | Restore the `pre-restore` or staging backup taken by the sync script |
| Unhealthy single container | `docker compose up -d --no-deps <service>` |
| Host reboot | `restart: unless-stopped` brings the stack back; run `healthcheck.sh` |

Do not recreate volumes to fix a software error.
