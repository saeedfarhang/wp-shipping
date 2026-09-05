# Architecture

Two isolated WordPress environments share one VPS and one MariaDB process. They do not share files, Redis, or database credentials.

```text
                         Internet
                            │
                 ┌──────────┴──────────┐
                 │                     │
              :8080                 :8081
                 │                     │
                 ▼                     ▼
            nginx-prod            nginx-stage
                 │                     │
                 ▼                     ▼
          wordpress-prod         wordpress-stage
                 │                     │
           ┌─────┴─────┐         ┌─────┴─────┐
           ▼           ▼         ▼           ▼
      redis-prod    mariadb   redis-stage  mariadb
                       │
                ┌──────┴──────┐
                │             │
           wordpress_prod  wordpress_stage
```

## Design decisions

| Decision | Choice | Why |
| --- | --- | --- |
| Orchestration | Docker Compose v2 on one VPS | Matches the operational model. No Kubernetes. |
| Public access | `VPS_IP:8080` and `VPS_IP:8081` | No TLS, DNS, or CDN in this repository. |
| Reverse proxy | One Nginx per environment | Staging can be restarted without bouncing production Nginx. |
| Database | One MariaDB, two databases/users | Less RAM than two database containers; credentials stay isolated. |
| Cache | Separate Redis instances | Object cache isolation. Persistence disabled. |
| WordPress runtime | Named volumes | Recreating containers does not delete uploads or `wp-config.php`. |
| WP-CLI / Redis PHP | Custom image based on official `wordpress:*-php8.3-fpm` | Official image has neither WP-CLI nor phpredis. |
| MariaDB init | `/docker-entrypoint-initdb.d` | Runs only when `mariadb_data` is empty. |

## Services

| Service | Image | Published ports | Network |
| --- | --- | --- | --- |
| `nginx-prod` | `nginx:1.26-alpine` | `${PROD_PORT}:80` (default 8080) | frontend |
| `nginx-stage` | `nginx:1.26-alpine` | `${STAGE_PORT}:80` (default 8081) | frontend |
| `wordpress-prod` | built from `wordpress:6.8-php8.3-fpm` | none | frontend + backend |
| `wordpress-stage` | same image | none | frontend + backend |
| `mariadb` | `mariadb:11.4` | none | backend (internal) |
| `redis-prod` | `redis:7.4-alpine` | none | backend (internal) |
| `redis-stage` | `redis:7.4-alpine` | none | backend (internal) |

The backend network is `internal: true`. MariaDB and Redis cannot reach the Internet and cannot be published accidentally through that network.

Nginx resolves PHP-FPM through Docker DNS (`127.0.0.11`) and a variable `fastcgi_pass`. That survives container IP changes and lets `nginx -t` run in CI without the WordPress hostname existing.

## Volumes

| Volume | Contents |
| --- | --- |
| `wordpress_mariadb_data` | MariaDB data directory |
| `wordpress_wordpress_prod_data` | Production `/var/www/html` |
| `wordpress_wordpress_stage_data` | Staging `/var/www/html` |
| `wordpress_redis_prod_data` | Production Redis working dir (cache only) |
| `wordpress_redis_stage_data` | Staging Redis working dir (cache only) |

Volume names are prefixed with `PROJECT_NAME` so they stay stable if CI and manual deploys use different working directories.

## Resource planning (8 vCPU / 16 GB)

These are cgroup **limits**, not reservations of exclusive RAM. Staging is capped lower than production so a busy or broken staging site cannot exhaust the host.

| Component | CPU limit | Memory limit | Notes |
| --- | --- | --- | --- |
| wordpress-prod | 2.0 | 4G | PHP-FPM workers + OPcache |
| wordpress-stage | 1.0 | 2G | Fewer FPM children |
| mariadb | 2.0 | 4G | InnoDB buffer pool defaults to 512M |
| redis-prod | 0.50 | 1G | `maxmemory` defaults to 256mb |
| redis-stage | 0.25 | 512M | `maxmemory` defaults to 128mb |
| nginx-prod | 0.50 | 128M | Static files + FastCGI |
| nginx-stage | 0.25 | 128M | Same role, smaller cap |
| OS / Docker / runner | remaining | remaining | Leave headroom |

On a smaller VPS, lower `WORDPRESS_*_MEM_LIMIT`, `MARIADB_MEM_LIMIT`, and `MARIADB_INNODB_BUFFER_POOL_SIZE` in `.env` before the first start.

`WORDPRESS_PROD_MEMORY_LIMIT` is the **PHP** `memory_limit`. It is not the container memory cap.

## WordPress persistence

The official image copies core files into the volume on first start. Later image upgrades update core files in that volume without deleting `wp-content`.

Custom code that should be in Git goes in `custom/themes` and `custom/plugins`. Uploads stay in the volume.

## Redis object cache

Compose injects `WP_REDIS_*` constants. The `redis` PHP extension is compiled into the image. After the web installer finishes, enable the plugin:

```bash
./scripts/maintenance.sh enable-redis
```

Redis is configured with `allkeys-lru` and without RDB/AOF. Restarting Redis only drops the object cache.

## MariaDB initialization

`docker/mariadb/init/01-init-databases.sh` creates:

- `wordpress_prod` / `wordpress_prod_user`
- `wordpress_stage` / `wordpress_stage_user`

Each user is granted only its own database (no cross-grants). The script runs **only** when the data directory is first created. Changing passwords later is a manual SQL operation; see [operations.md](operations.md).

## Logging

Every service uses the `json-file` driver with `max-size=10m` and `max-file=5`. Inspect logs with `docker compose logs`. Do not disable rotation.
