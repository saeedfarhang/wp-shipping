# WordPress infrastructure

Two isolated WordPress environments — production and staging — on a single Ubuntu VPS, managed with Docker Compose and GitLab CI.

```text
http://VPS_IP:8080  →  nginx-prod   →  wordpress-prod  →  mariadb / redis-prod
http://VPS_IP:8081  →  nginx-stage  →  wordpress-stage →  mariadb / redis-stage
```

MariaDB is shared as a process and split into two databases with two users. Redis, volumes, and Nginx are separate. Only ports **8080** and **8081** are published.

This repository does not include Kubernetes, TLS, DNS, or a CDN.

## Architecture

See [docs/architecture.md](docs/architecture.md) for networking, volumes, image pins, and resource limits.

Services: `nginx-prod`, `nginx-stage`, `wordpress-prod`, `wordpress-stage`, `mariadb`, `redis-prod`, `redis-stage`.

Pinned defaults (override in `.env`):

| Component | Image |
| --- | --- |
| WordPress (build base) | `wordpress:6.8-php8.3-fpm` |
| Nginx | `nginx:1.26-alpine` |
| MariaDB | `mariadb:11.4` |
| Redis | `redis:7.4-alpine` |

WordPress images are rebuilt locally to add WP-CLI, the `redis` PHP extension, and a PHP-FPM ping used by healthchecks.

## Requirements

- Ubuntu 24.04 LTS (8 vCPU / 16 GB / NVMe is the sizing target; smaller hosts work if you lower memory limits)
- Docker Engine + Docker Compose v2
- GitLab project and a **shell** runner on this VPS tagged `wordpress-infra`
- Firewall: `22`, `8080`, `8081` only
- S3-compatible bucket for backups (strongly recommended)

## Repository layout

```text
compose.yml                 Full stack
.env.example                All documented variables
docker/nginx/               Per-environment HTTP configs
docker/wordpress/           Dockerfile, PHP-FPM, php.ini
docker/mariadb/             First-boot init + conservative my.cnf
scripts/                    Deploy, health, backup, restore, maintenance
custom/                     Optional Git-managed themes/plugins
docs/                       Architecture and runbooks
cron/backups.example        Host cron (not installed by Compose)
```

Runtime WordPress files and databases live in named Docker volumes, not in git.

## Initial setup

```bash
git clone <gitlab-repository-url> /opt/wordpress-infra
cd /opt/wordpress-infra

cp .env.example .env
chmod 600 .env
vim .env
```

Set unique passwords for root, production, and staging. Set `VPS_IP`. Leave `S3_*` blank only for a short local test.

```bash
docker compose config
docker compose pull
docker compose build
docker compose up -d
./scripts/healthcheck.sh
```

Access:

```text
Production:  http://VPS_IP:8080
Staging:     http://VPS_IP:8081
```

Finish the WordPress installer on each site, then:

```bash
./scripts/maintenance.sh enable-redis
```

Full runner and firewall notes: [docs/deployment.md](docs/deployment.md).

## Configuration

`.env` is gitignored. Every variable in `.env.example` is documented there.

Critical groups:

- Ports: `PROD_PORT`, `STAGE_PORT`
- Isolated DB: `PROD_DB_*` vs `STAGE_DB_*`
- Isolated Redis: `REDIS_PROD_PASSWORD` vs `REDIS_STAGE_PASSWORD`
- PHP limits: `WORDPRESS_*_MEMORY_LIMIT`, `PHP_UPLOAD_MAX_FILESIZE`, …
- Cgroup caps: `WORDPRESS_PROD_MEM_LIMIT=4G` vs `WORDPRESS_STAGE_MEM_LIMIT=2G`
- Backups: `S3_*`, `BACKUP_LOCAL_RETENTION_DAYS`

MariaDB init runs **once**, when `mariadb_data` is created. Later password changes are manual ([docs/operations.md](docs/operations.md)).

## GitLab Runner and CI

Runner: **shell** executor, tag **`wordpress-infra`**, user `gitlab-runner` in the `docker` group (that group is root-equivalent; restrict pipeline access).

```text
push → validate → test → deploy staging → manual production
```

CI updates `/opt/wordpress-infra` in place (`GIT_STRATEGY: none`) so `.env` is not deleted by a clean checkout. Production is a **manual** job.

See [docs/deployment.md](docs/deployment.md).

## Deployment

```bash
./scripts/deploy.sh staging      # staging services only
./scripts/deploy.sh production   # prod + mariadb; never down -v
./scripts/deploy.sh all          # initial / shared changes
```

Deployments pull/build, run `docker compose up -d`, then `healthcheck.sh`. Volumes are never removed.

## Backups and restore

```bash
./scripts/backup-db.sh
./scripts/backup-files.sh
./scripts/restore-db.sh staging backups/stage-2026-09-05.sql.gz
./scripts/restore-db.sh production backups/prod-2026-09-05.sql.gz --confirm-production
```

Install host cron from `cron/backups.example`. Details: [docs/backup-restore.md](docs/backup-restore.md).

## Staging synchronization

Production → staging only, with an explicit flag:

```bash
./scripts/sync-prod-to-stage.sh --confirm
./scripts/sync-prod-to-stage.sh --confirm --include-files
```

## WordPress updates

| What | Where |
| --- | --- |
| Compose / Nginx / scripts | Git, then CI |
| WP / PHP / MariaDB / Redis images | Version pins in `.env`, staging then manual production |
| Plugins and themes | WP-CLI or wp-admin; Git-managed code in `custom/` |

Do not use `latest` tags. See [docs/operations.md](docs/operations.md).

## Troubleshooting

```bash
docker compose ps
docker compose logs -f wordpress-prod
docker compose logs -f wordpress-stage
docker compose logs mariadb
docker stats
df -h
docker system df
```

Runbook: [docs/troubleshooting.md](docs/troubleshooting.md).

## Security

- `.env` is not committed; mode `600`
- No `privileged: true`, no Docker socket in app containers
- Backend network is internal; 3306 / 6379 / 9000 are unpublished
- Separate DB users and Redis instances
- Nginx denies `.env`, `.git`, `wp-config.php`, SQL/backup downloads, PHP in uploads
- Staging debug output is not displayed to clients
- Production restore requires `--confirm-production`
- Adding `gitlab-runner` to `docker` grants host-level power; treat the runner as production-sensitive
