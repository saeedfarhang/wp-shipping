ARG WORDPRESS_IMAGE=wordpress:6.8-php8.3-fpm
FROM ${WORDPRESS_IMAGE}

# Official image entrypoint must start as root so it can fix volume permissions.
USER root

ARG PHPREDIS_VERSION=6.1.0

ENV DEBIAN_FRONTEND=noninteractive

# Install phpredis from GitHub. pecl.php.net often returns
# "No releases available for package pecl.php.net/redis" from this VPS.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        less \
        libfcgi-bin \
        mariadb-client \
        $PHPIZE_DEPS \
    ; \
    curl -fsSL "https://github.com/phpredis/phpredis/archive/refs/tags/${PHPREDIS_VERSION}.tar.gz" \
      -o /tmp/phpredis.tar.gz; \
    mkdir -p /usr/src/php/ext/redis; \
    tar -xzf /tmp/phpredis.tar.gz -C /usr/src/php/ext/redis --strip-components=1; \
    rm /tmp/phpredis.tar.gz; \
    docker-php-ext-install redis; \
    apt-get purge -y --auto-remove $PHPIZE_DEPS; \
    rm -rf /var/lib/apt/lists/* /usr/src/php/ext/redis; \
    curl -fsSL -o /usr/local/bin/wp https://github.com/wp-cli/wp-cli/releases/download/v2.11.0/wp-cli-2.11.0.phar; \
    chmod +x /usr/local/bin/wp; \
    wp --info --allow-root

COPY php-fpm.d/zz-health.conf /usr/local/etc/php-fpm.d/zz-health.conf
COPY entrypoint-wrapper.sh /usr/local/bin/entrypoint-wrapper.sh
RUN chmod +x /usr/local/bin/entrypoint-wrapper.sh

ENTRYPOINT ["entrypoint-wrapper.sh"]
CMD ["php-fpm"]
