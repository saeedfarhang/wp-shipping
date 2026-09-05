#!/bin/bash
# Runs ONLY when the MariaDB data volume is first initialized.
# Subsequent deploys never re-run this file. Changing passwords later
# must be done manually (see docs/operations.md).
set -Eeuo pipefail

: "${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD is required}"
: "${PROD_DB_NAME:?PROD_DB_NAME is required}"
: "${PROD_DB_USER:?PROD_DB_USER is required}"
: "${PROD_DB_PASSWORD:?PROD_DB_PASSWORD is required}"
: "${STAGE_DB_NAME:?STAGE_DB_NAME is required}"
: "${STAGE_DB_USER:?STAGE_DB_USER is required}"
: "${STAGE_DB_PASSWORD:?STAGE_DB_PASSWORD is required}"

if [[ "${PROD_DB_NAME}" == "${STAGE_DB_NAME}" ]]; then
  echo "PROD_DB_NAME and STAGE_DB_NAME must be different" >&2
  exit 1
fi

if [[ "${PROD_DB_USER}" == "${STAGE_DB_USER}" ]]; then
  echo "PROD_DB_USER and STAGE_DB_USER must be different" >&2
  exit 1
fi

if [[ "${PROD_DB_PASSWORD}" == "${STAGE_DB_PASSWORD}" ]]; then
  echo "PROD_DB_PASSWORD and STAGE_DB_PASSWORD must be different" >&2
  exit 1
fi

mariadb -u root -p"${MYSQL_ROOT_PASSWORD}" <<SQL
CREATE DATABASE IF NOT EXISTS \`${PROD_DB_NAME}\`
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

CREATE DATABASE IF NOT EXISTS \`${STAGE_DB_NAME}\`
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS '${PROD_DB_USER}'@'%' IDENTIFIED BY '${PROD_DB_PASSWORD}';
CREATE USER IF NOT EXISTS '${STAGE_DB_USER}'@'%' IDENTIFIED BY '${STAGE_DB_PASSWORD}';

ALTER USER '${PROD_DB_USER}'@'%' IDENTIFIED BY '${PROD_DB_PASSWORD}';
ALTER USER '${STAGE_DB_USER}'@'%' IDENTIFIED BY '${STAGE_DB_PASSWORD}';

GRANT ALL PRIVILEGES ON \`${PROD_DB_NAME}\`.* TO '${PROD_DB_USER}'@'%';
GRANT ALL PRIVILEGES ON \`${STAGE_DB_NAME}\`.* TO '${STAGE_DB_USER}'@'%';

FLUSH PRIVILEGES;
SQL

echo "Initialized isolated databases: ${PROD_DB_NAME}, ${STAGE_DB_NAME}"
