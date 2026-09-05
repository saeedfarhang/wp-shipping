#!/usr/bin/env bash
# Idempotent deployment. Never removes volumes.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: deploy.sh [all|staging|production]

  all          Build/pull and start the full stack (initial install or shared changes)
  staging      Update only nginx-stage, wordpress-stage, redis-stage
  production   Update nginx-prod, wordpress-prod, redis-prod, and mariadb

GitLab CI should call staging or production. Do not use docker compose down -v.
EOF
}

TARGET="${1:-all}"
case "${TARGET}" in
  all|staging|production) ;;
  -h|--help) usage; exit 0 ;;
  *) usage; die "Unknown target: ${TARGET}" ;;
esac

load_env
require_runtime_env

if ! command -v docker >/dev/null 2>&1; then
  die "docker is not installed or not on PATH"
fi

if ! docker compose version >/dev/null 2>&1; then
  die "docker compose v2 is required"
fi

# CI already has the intended commit checked out in DEPLOY_DIR.
if [[ -z "${CI:-}" && -d "${ROOT_DIR}/.git" ]]; then
  if [[ "${DEPLOY_SKIP_GIT_PULL:-0}" != "1" ]]; then
    log "Fetching repository updates"
    git -C "${ROOT_DIR}" pull --ff-only
  fi
fi

log "Validating Compose file"
compose config --quiet

STAGING_SERVICES=(nginx-stage wordpress-stage redis-stage)
PRODUCTION_SERVICES=(nginx-prod wordpress-prod redis-prod mariadb)

case "${TARGET}" in
  staging)
    SERVICES=("${STAGING_SERVICES[@]}")
    ;;
  production)
    SERVICES=("${PRODUCTION_SERVICES[@]}")
    ;;
  all)
    SERVICES=(nginx-prod nginx-stage wordpress-prod wordpress-stage mariadb redis-prod redis-stage)
    ;;
esac

log "Building WordPress image if needed"
case "${TARGET}" in
  staging) compose build wordpress-stage ;;
  production) compose build wordpress-prod ;;
  all) compose build wordpress-prod wordpress-stage ;;
esac

log "Pulling published images (WordPress is built locally)"
PULL_IMAGES=()
case "${TARGET}" in
  staging) PULL_IMAGES=(nginx-stage redis-stage) ;;
  production) PULL_IMAGES=(nginx-prod redis-prod mariadb) ;;
  all) PULL_IMAGES=(nginx-prod nginx-stage redis-prod redis-stage mariadb) ;;
esac
compose pull "${PULL_IMAGES[@]}"

log "Applying Compose changes (volumes are preserved)"
# --no-deps avoids restarting healthy production services when only staging changes.
if [[ "${TARGET}" == "all" ]]; then
  compose up -d --remove-orphans "${SERVICES[@]}"
else
  compose up -d --no-deps --remove-orphans "${SERVICES[@]}"
fi

log "Service status"
compose ps

log "Running health checks"
"${SCRIPT_DIR}/healthcheck.sh" "${TARGET}"

log "Deployment of ${TARGET} completed"
