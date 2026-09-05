#!/usr/bin/env bash
# Returns non-zero if the selected stack is unhealthy.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  echo "Usage: healthcheck.sh [all|staging|production]"
}

TARGET="${1:-all}"
case "${TARGET}" in
  all|staging|production) ;;
  -h|--help) usage; exit 0 ;;
  *) usage; die "Unknown target: ${TARGET}" ;;
esac

load_env
require_vars PROJECT_NAME PROD_PORT STAGE_PORT VPS_IP

FAILURES=0

check_container() {
  local service="$1"
  local cid
  cid="$(compose ps -q "${service}" 2>/dev/null || true)"
  if [[ -z "${cid}" ]]; then
    err "${service}: container is not running"
    FAILURES=$((FAILURES + 1))
    return
  fi

  local status health
  status="$(docker inspect -f '{{.State.Status}}' "${cid}")"
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${cid}")"

  if [[ "${status}" != "running" ]]; then
    err "${service}: status=${status} (expected running)"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if [[ "${health}" != "healthy" && "${health}" != "none" ]]; then
    err "${service}: health=${health}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  log "${service}: running/${health}"
}

check_http() {
  local name="$1"
  local url="$2"
  if curl -fsS --max-time 10 "${url}" | grep -q ok; then
    log "${name}: ${url} ok"
  else
    err "${name}: ${url} failed"
    FAILURES=$((FAILURES + 1))
  fi
}

SERVICES=()
HTTP_CHECKS=()

case "${TARGET}" in
  staging)
    SERVICES=(nginx-stage wordpress-stage redis-stage mariadb)
    HTTP_CHECKS+=("staging|http://127.0.0.1:${STAGE_PORT}/healthz")
    ;;
  production)
    SERVICES=(nginx-prod wordpress-prod redis-prod mariadb)
    HTTP_CHECKS+=("production|http://127.0.0.1:${PROD_PORT}/healthz")
    ;;
  all)
    SERVICES=(nginx-prod nginx-stage wordpress-prod wordpress-stage mariadb redis-prod redis-stage)
    HTTP_CHECKS+=("production|http://127.0.0.1:${PROD_PORT}/healthz")
    HTTP_CHECKS+=("staging|http://127.0.0.1:${STAGE_PORT}/healthz")
    ;;
esac

for service in "${SERVICES[@]}"; do
  check_container "${service}"
done

for item in "${HTTP_CHECKS[@]}"; do
  check_http "${item%%|*}" "${item#*|}"
done

if [[ "${FAILURES}" -ne 0 ]]; then
  die "${FAILURES} health check(s) failed"
fi

log "Health checks passed for ${TARGET}"
