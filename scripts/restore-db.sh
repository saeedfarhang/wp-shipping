#!/usr/bin/env bash
# Restore a compressed SQL dump into staging or production.
# Production requires --confirm-production. This script never drops volumes.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage:
  restore-db.sh staging <backup.sql.gz>
  restore-db.sh production <backup.sql.gz> --confirm-production

The backup file may be a local path. If it ends with .enc, BACKUP_ENCRYPTION_KEY
must be set so the file can be decrypted.
EOF
}

TARGET="${1:-}"
BACKUP_FILE="${2:-}"
CONFIRM="${3:-}"

if [[ "${TARGET}" == "-h" || "${TARGET}" == "--help" || -z "${TARGET}" || -z "${BACKUP_FILE}" ]]; then
  usage
  [[ -n "${TARGET}" && -n "${BACKUP_FILE}" ]] || exit 1
  exit 0
fi

case "${TARGET}" in
  production|staging) ;;
  *) usage; die "Target must be production or staging" ;;
esac

if [[ "${TARGET}" == "production" && "${CONFIRM}" != "--confirm-production" ]]; then
  die "Refusing to restore production without --confirm-production"
fi

if [[ "${TARGET}" == "staging" && "${CONFIRM}" == "--confirm-production" ]]; then
  die "--confirm-production is only valid for production restores"
fi

load_env
require_runtime_env

if [[ ! -f "${BACKUP_FILE}" ]]; then
  # Allow bare filenames from backups/
  if [[ -f "${BACKUP_DIR}/${BACKUP_FILE}" ]]; then
    BACKUP_FILE="${BACKUP_DIR}/${BACKUP_FILE}"
  else
    die "Backup file not found: ${BACKUP_FILE}"
  fi
fi

case "${BACKUP_FILE}" in
  *.sql.gz|*.sql.gz.enc|*.sql|*.enc) ;;
  *) die "Backup must be a .sql, .sql.gz, or .enc file" ;;
esac

DB_NAME="$(db_name_for "${TARGET}")"
ensure_backup_dir

WORK_FILE="${BACKUP_FILE}"
CLEANUP_FILE=""

if [[ "${WORK_FILE}" == *.enc ]]; then
  [[ -n "${BACKUP_ENCRYPTION_KEY:-}" ]] || die "BACKUP_ENCRYPTION_KEY is required to decrypt ${WORK_FILE}"
  CLEANUP_FILE="$(mktemp "${BACKUP_DIR}/restore.XXXXXX")"
  openssl enc -d -aes-256-cbc -pbkdf2 -pass env:BACKUP_ENCRYPTION_KEY -in "${WORK_FILE}" -out "${CLEANUP_FILE}"
  WORK_FILE="${CLEANUP_FILE}"
fi

log "Taking a safety dump of ${TARGET} (${DB_NAME}) before restore"
SAFETY_DUMP="${BACKUP_DIR}/pre-restore-${TARGET}-$(date -u +'%Y-%m-%dT%H%M%SZ').sql.gz"
compose exec -T mariadb sh -c \
  'mariadb-dump -u root -p"$MYSQL_ROOT_PASSWORD" --single-transaction --routines --triggers --hex-blob "$1"' \
  sh "${DB_NAME}" | gzip -c > "${SAFETY_DUMP}"
log "Safety dump written to ${SAFETY_DUMP}"

log "Restoring ${WORK_FILE} into ${TARGET} database ${DB_NAME}"
# Dumps are table-level (no CREATE DATABASE), so the selected target is authoritative.
if [[ "${WORK_FILE}" == *.gz ]]; then
  gzip -dc "${WORK_FILE}" | compose exec -T mariadb sh -c \
    'mariadb -u root -p"$MYSQL_ROOT_PASSWORD" "$1"' sh "${DB_NAME}"
else
  compose exec -T mariadb sh -c \
    'mariadb -u root -p"$MYSQL_ROOT_PASSWORD" "$1"' sh "${DB_NAME}" < "${WORK_FILE}"
fi

if [[ -n "${CLEANUP_FILE}" ]]; then
  rm -f "${CLEANUP_FILE}"
fi

log "Restore into ${TARGET} completed"
log "If this was a production-to-staging copy, run search-replace for URLs (see docs/backup-restore.md)"
