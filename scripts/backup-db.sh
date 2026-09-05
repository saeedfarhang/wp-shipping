#!/usr/bin/env bash
# Create compressed SQL dumps and optionally upload them to S3.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  echo "Usage: backup-db.sh [all|production|staging]"
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

dump_db() {
  local env="$1"
  local db_name prefix outfile
  db_name="$(db_name_for "${env}")"
  prefix="$(backup_prefix_for "${env}")"
  outfile="${BACKUP_DIR}/${prefix}-${DATE_STAMP}.sql.gz"

  log "Dumping ${env} database ${db_name} -> ${outfile}"
  compose exec -T mariadb sh -c \
    'mariadb-dump -u root -p"$MYSQL_ROOT_PASSWORD" --single-transaction --routines --triggers --hex-blob "$1"' \
    sh "${db_name}" | gzip -c > "${outfile}.partial"

  if [[ ! -s "${outfile}.partial" ]]; then
    rm -f "${outfile}.partial"
    die "Database dump for ${env} was empty"
  fi

  mv "${outfile}.partial" "${outfile}"
  # Keep a timestamped copy as well so same-day reruns do not clobber S3 objects.
  cp -a "${outfile}" "${BACKUP_DIR}/${prefix}-${TIME_STAMP}.sql.gz"

  local to_upload
  to_upload="$(encrypt_if_configured "${BACKUP_DIR}/${prefix}-${TIME_STAMP}.sql.gz")"
  s3_upload "${to_upload}" "database"
  log "Created ${outfile}"
}

case "${TARGET}" in
  all)
    dump_db production
    dump_db staging
    ;;
  production|staging)
    dump_db "${TARGET}"
    ;;
esac

prune_local_backups
log "Database backup completed"
