# Backup and restore

Local files under `backups/` are a convenience, not the only copy. Configure S3-compatible storage in `.env` so every backup is uploaded off the VPS.

## What is backed up

| Script | Contents | Example filename |
| --- | --- | --- |
| `scripts/backup-db.sh` | One compressed SQL dump per database (tables only, no `CREATE DATABASE`) | `prod-2026-09-05.sql.gz` |
| `scripts/backup-files.sh` | `wp-content/` from the WordPress volume, excluding cache/upgrade dirs | `prod-wp-content-2026-09-05.tar.gz` |

Dumps do not include `CREATE DATABASE` / `USE` statements. Restore always targets the environment you pass on the command line. A production dump can be loaded into staging without touching the production database.

## Database backup

```bash
./scripts/backup-db.sh            # both
./scripts/backup-db.sh production
./scripts/backup-db.sh staging
```

Uses `mariadb-dump --single-transaction` as root inside the MariaDB container.

## File backup

```bash
./scripts/backup-files.sh
./scripts/backup-files.sh production
./scripts/backup-files.sh staging
```

## S3-compatible upload

Set all of:

```text
S3_ENDPOINT      # empty for AWS; set for MinIO / other S3 APIs
S3_BUCKET
S3_REGION
S3_ACCESS_KEY
S3_SECRET_KEY
S3_PREFIX        # default wordpress-infra
```

The scripts use host `aws` if present, otherwise `amazon/aws-cli:2.17.54`.

Optional `BACKUP_ENCRYPTION_KEY` encrypts the timestamped object with `openssl enc -aes-256-cbc -pbkdf2` before upload. Keep that key outside git.

If `S3_BUCKET` is empty, backups stay in `./backups` only. That is not a production backup strategy.

## Retention

`BACKUP_LOCAL_RETENTION_DAYS` (default `7`) deletes local `*.sql.gz`, `*.tar.gz`, and `*.enc` files older than that many days.

Remote retention belongs in the bucket lifecycle policy. Recommended starting point:

```text
daily    7 days
weekly   4 weeks
monthly  3–6 months
```

Verify a backup after the first cron run: the file is non-empty, `gzip -t` succeeds, and the object exists in the bucket.

## Cron

This repository does not install cron. Copy the example on the VPS:

```bash
sudo cp /opt/wordpress-infra/cron/backups.example /etc/cron.d/wordpress-infra
sudo chmod 644 /etc/cron.d/wordpress-infra
sudo touch /var/log/wordpress-infra-backup.log /var/log/wordpress-infra-health.log
sudo chown gitlab-runner:gitlab-runner /var/log/wordpress-infra-backup.log /var/log/wordpress-infra-health.log
```

Default schedule:

```text
02:00  database backup
03:00  wp-content backup
Sunday 04:00  healthcheck
```

## Restore a database

```bash
./scripts/restore-db.sh staging backups/stage-2026-09-05.sql.gz
./scripts/restore-db.sh production backups/prod-2026-09-05.sql.gz --confirm-production
```

Production restore **requires** `--confirm-production`. The script refuses other targets, missing files, and production without that flag.

Before import it writes a safety dump:

```text
backups/pre-restore-<target>-<timestamp>.sql.gz
```

Encrypted backups (`*.enc`) need `BACKUP_ENCRYPTION_KEY` in `.env`.

After restore, flush caches:

```bash
./scripts/maintenance.sh wp-prod cache flush
./scripts/maintenance.sh wp-stage cache flush
```

## Restore wp-content

There is no automatic file-restore script (to avoid silently overwriting uploads). Example for staging:

```bash
docker compose exec -T wordpress-stage tar -C /var/www/html -xzf - < backups/stage-wp-content-2026-09-05.tar.gz
```

Use production only after taking a fresh `backup-files.sh production` copy.

## Production → staging sync

One direction only. The script cannot write to production.

```bash
./scripts/sync-prod-to-stage.sh --confirm
./scripts/sync-prod-to-stage.sh --confirm --include-files
```

It backs up staging first, imports the production dump into `wordpress_stage`, then runs WP-CLI `search-replace` from `PROD_PUBLIC_URL` (or `http://VPS_IP:PROD_PORT`) to the staging URL.

If the live site URL in the database differs from `.env`, set `PROD_PUBLIC_URL` and `STAGE_PUBLIC_URL` before syncing.

Sanitize staging after a copy (users, payment keys, webhooks) before exposing it. This repository does not invent application-specific sanitization.
