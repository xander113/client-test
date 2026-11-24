FROM php:8.4-fpm-bookworm AS php
RUN apt-get update \
    && apt-get install -y --no-install-recommends libpq-dev unzip \
    && docker-php-ext-install -j"$(nproc)" pdo_pgsql opcache \
    && rm -rf /var/lib/apt/lists/*
COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer
WORKDIR /var/www/pot

FROM php AS production
ENV COMPOSER_ALLOW_SUPERUSER=1
COPY composer.json composer.lock ./
RUN --mount=type=secret,id=build_ca \
    if [ -s /run/secrets/build_ca ]; then export COMPOSER_CAFILE=/run/secrets/build_ca; fi; \
    composer install --no-dev --prefer-dist --no-interaction --no-scripts --optimize-autoloader
COPY . .
RUN mkdir -p storage/app/private storage/framework/cache/data storage/framework/sessions storage/framework/views storage/logs bootstrap/cache \
    && chmod -R a+rX /var/www/pot \
    && chown -R www-data:www-data storage bootstrap/cache
