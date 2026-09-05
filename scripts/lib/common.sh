#!/usr/bin/env bash
# Shared helpers for operational scripts. Sourced, not executed.
# shellcheck shell=bash

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "common.sh is meant to be sourced" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE_FILE="${ROOT_DIR}/compose.yml"
BACKUP_DIR="${ROOT_DIR}/backups"

log() { printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"; }
err() { printf '%s ERROR: %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die() { err "$*"; exit 1; }

load_env() {
  local env_file="${ROOT_DIR}/.env"
  if [[ ! -f "${env_file}" ]]; then
    die "Missing ${env_file}. Copy .env.example and set secrets (chmod 600 .env)."
  fi
  set -a
  # shellcheck disable=SC1090
  source "${env_file}"
  set +a
  PROJECT_NAME="${PROJECT_NAME:-wordpress}"
  PROD_PORT="${PROD_PORT:-8080}"
  STAGE_PORT="${STAGE_PORT:-8081}"
  VPS_IP="${VPS_IP:-127.0.0.1}"
  BACKUP_LOCAL_RETENTION_DAYS="${BACKUP_LOCAL_RETENTION_DAYS:-7}"
  S3_PREFIX="${S3_PREFIX:-wordpress-infra}"
  AWS_CLI_IMAGE="${AWS_CLI_IMAGE:-amazon/aws-cli:2.17.54}"
}

require_vars() {
  local missing=0
  local name
  for name in "$@"; do
    if [[ -z "${!name:-}" ]]; then
      err "Required variable ${name} is empty"
      missing=1
    fi
  done
  if [[ "${missing}" -ne 0 ]]; then
    die "One or more required environment variables are missing"
  fi
}

require_distinct() {
  local left_name="$1"
  local right_name="$2"
  if [[ "${!left_name}" == "${!right_name}" ]]; then
    die "${left_name} and ${right_name} must be different"
  fi
}

require_runtime_env() {
  require_vars \
    PROJECT_NAME \
    MYSQL_ROOT_PASSWORD \
    PROD_DB_NAME PROD_DB_USER PROD_DB_PASSWORD \
    STAGE_DB_NAME STAGE_DB_USER STAGE_DB_PASSWORD \
    REDIS_PROD_PASSWORD REDIS_STAGE_PASSWORD

  require_distinct PROD_DB_NAME STAGE_DB_NAME
  require_distinct PROD_DB_USER STAGE_DB_USER
  require_distinct PROD_DB_PASSWORD STAGE_DB_PASSWORD
  require_distinct REDIS_PROD_PASSWORD REDIS_STAGE_PASSWORD

  local secret
  for secret in MYSQL_ROOT_PASSWORD PROD_DB_PASSWORD STAGE_DB_PASSWORD REDIS_PROD_PASSWORD REDIS_STAGE_PASSWORD; do
    if [[ "${!secret}" == *"'"* ]]; then
      die "${secret} must not contain single quotes (used in MariaDB init SQL)"
    fi
  done
}

compose() {
  docker compose --project-directory "${ROOT_DIR}" -f "${COMPOSE_FILE}" "$@"
}

public_url() {
  local env="$1"
  case "${env}" in
    production)
      echo "${PROD_PUBLIC_URL:-http://${VPS_IP}:${PROD_PORT}}"
      ;;
    staging)
      echo "${STAGE_PUBLIC_URL:-http://${VPS_IP}:${STAGE_PORT}}"
      ;;
    *)
      die "Unknown environment: ${env}"
      ;;
  esac
}

host_port() {
  local env="$1"
  case "${env}" in
    production) echo "${PROD_PORT}" ;;
    staging) echo "${STAGE_PORT}" ;;
    *) die "Unknown environment: ${env}" ;;
  esac
}

db_name_for() {
  local env="$1"
  case "${env}" in
    production) echo "${PROD_DB_NAME}" ;;
    staging) echo "${STAGE_DB_NAME}" ;;
    *) die "Unknown environment: ${env}" ;;
  esac
}

wp_service_for() {
  local env="$1"
  case "${env}" in
    production) echo "wordpress-prod" ;;
    staging) echo "wordpress-stage" ;;
    *) die "Unknown environment: ${env}" ;;
  esac
}

backup_prefix_for() {
  local env="$1"
  case "${env}" in
    production) echo "prod" ;;
    staging) echo "stage" ;;
    *) die "Unknown environment: ${env}" ;;
  esac
}

ensure_backup_dir() {
  mkdir -p "${BACKUP_DIR}"
  chmod 700 "${BACKUP_DIR}"
}

prune_local_backups() {
  local days="${BACKUP_LOCAL_RETENTION_DAYS}"
  if [[ ! "${days}" =~ ^[0-9]+$ ]]; then
    die "BACKUP_LOCAL_RETENTION_DAYS must be an integer"
  fi
  find "${BACKUP_DIR}" -type f \( -name '*.sql.gz' -o -name '*.tar.gz' -o -name '*.enc' \) -mtime "+${days}" -delete || true
}

encrypt_if_configured() {
  local src="$1"
  if [[ -z "${BACKUP_ENCRYPTION_KEY:-}" ]]; then
    echo "${src}"
    return 0
  fi
  local dest="${src}.enc"
  openssl enc -aes-256-cbc -pbkdf2 -salt -pass env:BACKUP_ENCRYPTION_KEY -in "${src}" -out "${dest}"
  rm -f "${src}"
  echo "${dest}"
}

s3_configured() {
  [[ -n "${S3_BUCKET:-}" && -n "${S3_ACCESS_KEY:-}" && -n "${S3_SECRET_KEY:-}" ]]
}

s3_upload() {
  local file="$1"
  local kind="${2:-misc}"
  if ! s3_configured; then
    log "S3 is not configured; leaving ${file} on local disk only"
    return 0
  fi

  local dest="s3://${S3_BUCKET}/${S3_PREFIX}/${kind}/$(basename "${file}")"
  local extra=()
  if [[ -n "${S3_ENDPOINT:-}" ]]; then
    extra+=(--endpoint-url "${S3_ENDPOINT}")
  fi

  if command -v aws >/dev/null 2>&1; then
    AWS_ACCESS_KEY_ID="${S3_ACCESS_KEY}" \
    AWS_SECRET_ACCESS_KEY="${S3_SECRET_KEY}" \
    AWS_DEFAULT_REGION="${S3_REGION:-us-east-1}" \
      aws "${extra[@]}" s3 cp "${file}" "${dest}"
  else
    docker run --rm \
      -e AWS_ACCESS_KEY_ID="${S3_ACCESS_KEY}" \
      -e AWS_SECRET_ACCESS_KEY="${S3_SECRET_KEY}" \
      -e AWS_DEFAULT_REGION="${S3_REGION:-us-east-1}" \
      -v "${file}:/data/$(basename "${file}"):ro" \
      "${AWS_CLI_IMAGE}" \
      "${extra[@]}" s3 cp "/data/$(basename "${file}")" "${dest}"
  fi
  log "Uploaded ${file} -> ${dest}"
}

wp() {
  local service="$1"
  shift
  compose exec -T -u www-data "${service}" wp --path=/var/www/html "$@"
}
