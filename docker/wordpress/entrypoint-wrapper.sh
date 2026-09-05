#!/bin/sh
set -eu

# Runtime PHP limits come from Compose environment so .env is the single source.
cat > /usr/local/etc/php/conf.d/zz-runtime.ini <<EOF
memory_limit=${WORDPRESS_MEMORY_LIMIT:-256M}
upload_max_filesize=${PHP_UPLOAD_MAX_FILESIZE:-64M}
post_max_size=${PHP_POST_MAX_SIZE:-64M}
max_execution_time=${PHP_MAX_EXECUTION_TIME:-120}
max_input_time=${PHP_MAX_EXECUTION_TIME:-120}
date.timezone=${TZ:-UTC}
EOF

exec docker-entrypoint.sh "$@"
