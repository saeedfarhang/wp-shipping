ARG WORDPRESS_IMAGE=wordpress:6.8-php8.3-fpm
FROM ${WORDPRESS_IMAGE}

# Official image entrypoint must start as root so it can fix volume permissions.
USER root

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        less \
        libfcgi-bin \
        mariadb-client \
        $PHPIZE_DEPS \
    ; \
    pecl install redis-6.1.0; \
    docker-php-ext-enable redis; \
    apt-get purge -y --auto-remove $PHPIZE_DEPS; \
    rm -rf /var/lib/apt/lists/*; \
    curl -fsSL -o /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar; \
    chmod +x /usr/local/bin/wp; \
    wp --info --allow-root

COPY php-fpm.d/zz-health.conf /usr/local/etc/php-fpm.d/zz-health.conf
COPY entrypoint-wrapper.sh /usr/local/bin/entrypoint-wrapper.sh
RUN chmod +x /usr/local/bin/entrypoint-wrapper.sh

ENTRYPOINT ["entrypoint-wrapper.sh"]
CMD ["php-fpm"]
