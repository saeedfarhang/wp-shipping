#!/usr/bin/env bash
# Back up wp-content from persistent WordPress volumes.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  echo "Usage: backup-files.sh [all|production|staging]"
}

TARGET="${1:-all}"
case "${TARGET}" in
  all|production|staging) ;;
  -h|--help) usage; exit 0 ;;
  *) usage; die "Unknown target: ${TARGET}" ;;
esac

load_env
require_runtime_env
ensure_backup_dir

DATE_STAMP="$(date -u +'%Y-%m-%d')"
TIME_STAMP="$(date -u +'%Y-%m-%dT%H%M%SZ')"

backup_files() {
  local env="$1"
  local service prefix outfile
  service="$(wp_service_for "${env}")"
  prefix="$(backup_prefix_for "${env}")"
  outfile="${BACKUP_DIR}/${prefix}-wp-content-${DATE_STAMP}.tar.gz"

  log "Archiving ${env} wp-content -> ${outfile}"
  compose exec -T -u www-data "${service}" tar \
    --exclude='wp-content/cache' \
    --exclude='wp-content/upgrade' \
    --exclude='wp-content/upgrade-temp-backup' \
    -C /var/www/html \
    -czf - wp-content > "${outfile}.partial"

  if [[ ! -s "${outfile}.partial" ]]; then
    rm -f "${outfile}.partial"
    die "File backup for ${env} was empty"
  fi

  mv "${outfile}.partial" "${outfile}"
  cp -a "${outfile}" "${BACKUP_DIR}/${prefix}-wp-content-${TIME_STAMP}.tar.gz"

  local to_upload
  to_upload="$(encrypt_if_configured "${BACKUP_DIR}/${prefix}-wp-content-${TIME_STAMP}.tar.gz")"
  s3_upload "${to_upload}" "files"
  log "Created ${outfile}"
}

case "${TARGET}" in
  all)
    backup_files production
    backup_files staging
    ;;
  production|staging)
    backup_files "${TARGET}"
    ;;
esac

prune_local_backups
log "File backup completed"
