# Multi-stage build: Composer creates a fresh Laravel 11 project → PHP 8.4 + Apache runtime
# with dd-trace-php pre-installed.

# ── Stage 1: Build ────────────────────────────────────────────────────────────
FROM wwongpai/composer:2 AS build
WORKDIR /app
RUN composer create-project --no-interaction --prefer-dist laravel/laravel:^11.0 /app
COPY routes/web.php /app/routes/web.php
RUN cp /app/.env.example /app/.env && php /app/artisan key:generate --force

# ── Stage 2: Runtime ──────────────────────────────────────────────────────────
FROM wwongpai/php:8.4-apache
WORKDIR /var/www/html

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /app /var/www/html

# Install the Datadog PHP tracer
RUN curl -L https://github.com/DataDog/dd-trace-php/releases/latest/download/datadog-setup.php \
       -o /tmp/dd-setup.php \
    && php /tmp/dd-setup.php --php-bin php --enable-appsec=no --enable-profiling=no \
    && rm -f /tmp/dd-setup.php

RUN rm -f /var/www/html/bootstrap/cache/*.php \
    && chown -R www-data:www-data /var/www/html \
    && chmod -R 775 /var/www/html/storage /var/www/html/bootstrap/cache \
    && a2enmod rewrite

EXPOSE 80

ENV APACHE_DOCUMENT_ROOT=/var/www/html/public

RUN sed -ri \
      -e 's!/var/www/html!/var/www/html/public!g' \
      /etc/apache2/sites-available/*.conf \
    && sed -ri \
      -e 's!/var/www/!/var/www/html/public!g' \
      /etc/apache2/apache2.conf /etc/apache2/conf-available/*.conf

CMD ["apache2-foreground"]
