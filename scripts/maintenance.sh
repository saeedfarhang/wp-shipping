#!/usr/bin/env bash
# Safe operational helpers. Nothing here deletes volumes.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: maintenance.sh <command>

Commands:
  status           Container and health overview
  disk             Host and Docker disk usage
  db-status        MariaDB overview
  prune-images     Remove unused images only (never volumes)
  enable-redis     Install/activate Redis Object Cache on both sites if WordPress is installed
  wp-prod ARGS     Run WP-CLI in production (as www-data)
  wp-stage ARGS    Run WP-CLI in staging (as www-data)
EOF
}

COMMAND="${1:-}"
if [[ -z "${COMMAND}" || "${COMMAND}" == "-h" || "${COMMAND}" == "--help" ]]; then
  usage
  [[ -n "${COMMAND}" ]] || exit 1
  exit 0
fi
shift || true

load_env
require_runtime_env

enable_redis_for() {
  local service="$1"
  if ! wp "${service}" core is-installed >/dev/null 2>&1; then
    log "${service}: WordPress is not installed yet; skip Redis plugin"
    return 0
  fi
  wp "${service}" plugin install redis-cache --activate
  wp "${service}" redis enable || true
  wp "${service}" redis status || true
}

case "${COMMAND}" in
  status)
    compose ps
    "${SCRIPT_DIR}/healthcheck.sh" all || true
    ;;
  disk)
    df -h
    echo
    docker system df
    echo
    log "Unused images can be removed with: $0 prune-images"
    log "Never run docker compose down -v or docker volume prune unless you intend to destroy data"
    ;;
  db-status)
    compose exec -T mariadb sh -c \
      'mariadb -u root -p"$MYSQL_ROOT_PASSWORD" -e "SHOW DATABASES; SHOW STATUS LIKE '\''Threads_connected'\''; SHOW VARIABLES LIKE '\''innodb_buffer_pool_size'\'';"'
    ;;
  prune-images)
    log "Pruning unused images only"
    docker image prune -f
    ;;
  enable-redis)
    enable_redis_for wordpress-prod
    enable_redis_for wordpress-stage
    ;;
  wp-prod)
    wp wordpress-prod "$@"
    ;;
  wp-stage)
    wp wordpress-stage "$@"
    ;;
  *)
    usage
    die "Unknown command: ${COMMAND}"
    ;;
esac
