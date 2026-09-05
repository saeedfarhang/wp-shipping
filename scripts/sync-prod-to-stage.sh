#!/usr/bin/env bash
# Copy production data into staging only. Never writes to production.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

INCLUDE_FILES=0
CONFIRMED=0

usage() {
  cat <<'EOF'
Usage: sync-prod-to-stage.sh --confirm [--include-files]

Copies the production database into staging, then rewrites public URLs.
Optionally copies wp-content (excluding cache) from production to staging.

This command cannot target production. Staging is backed up first.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm) CONFIRMED=1; shift ;;
    --include-files) INCLUDE_FILES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "Unknown argument: $1" ;;
  esac
done

if [[ "${CONFIRMED}" -ne 1 ]]; then
  die "Refusing to overwrite staging without --confirm"
fi

load_env
require_runtime_env
ensure_backup_dir

PROD_URL="$(public_url production)"
STAGE_URL="$(public_url staging)"

log "Backing up staging before overwrite"
"${SCRIPT_DIR}/backup-db.sh" staging
if [[ "${INCLUDE_FILES}" -eq 1 ]]; then
  "${SCRIPT_DIR}/backup-files.sh" staging
fi

TMP_DUMP="${BACKUP_DIR}/sync-prod-$(date -u +'%Y-%m-%dT%H%M%SZ').sql.gz"
log "Dumping production database for staging import"
compose exec -T mariadb sh -c \
  'mariadb-dump -u root -p"$MYSQL_ROOT_PASSWORD" --single-transaction --routines --triggers --hex-blob "$1"' \
  sh "${PROD_DB_NAME}" | gzip -c > "${TMP_DUMP}"

log "Importing production dump into staging database ${STAGE_DB_NAME}"
gzip -dc "${TMP_DUMP}" | compose exec -T mariadb sh -c \
  'mariadb -u root -p"$MYSQL_ROOT_PASSWORD" "$1"' sh "${STAGE_DB_NAME}"

if wp wordpress-stage core is-installed >/dev/null 2>&1; then
  log "Rewriting URLs ${PROD_URL} -> ${STAGE_URL}"
  wp wordpress-stage search-replace "${PROD_URL}" "${STAGE_URL}" --all-tables --skip-columns=guid || true
  wp wordpress-stage cache flush || true
  wp wordpress-stage rewrite flush || true
else
  log "WordPress is not installed in staging yet; import the files and finish setup in the browser"
fi

if [[ "${INCLUDE_FILES}" -eq 1 ]]; then
  log "Copying production wp-content into staging (cache excluded)"
  compose exec -T wordpress-prod tar \
    --exclude='wp-content/cache' \
    --exclude='wp-content/upgrade' \
    --exclude='wp-content/upgrade-temp-backup' \
    -C /var/www/html -cf - wp-content \
    | compose exec -T wordpress-stage tar -C /var/www/html -xf -
fi

log "Production -> staging sync completed"
log "Verify ${STAGE_URL} before sharing the staging site"
