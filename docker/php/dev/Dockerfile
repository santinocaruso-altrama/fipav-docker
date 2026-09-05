# Immagine di sviluppo per fipav-core (Laravel): identica a
# docker/php/stage/Dockerfile tranne per Xdebug, installato solo qui - vedi
# il commento piu' sotto sul perche' non serve in staging.
FROM php:8.4-fpm

# Install system dependencies
RUN apt-get update && apt-get install -y \
    git \
    curl \
    libpng-dev \
    libjpeg-dev \
    libfreetype6-dev \
    libwebp-dev \
    libavif-dev \
    libonig-dev \
    libxml2-dev \
    libzip-dev \
    libicu-dev \
    zip \
    unzip \
    default-mysql-client \
    pv \
    && rm -rf /var/lib/apt/lists/*

# Configure and install PHP extensions
# --with-webp e --with-avif servono a generare derivate leggere dei media: un
# JPEG da 6 MB riconvertito a larghezza utile in WebP sta in poche centinaia di
# KB. Senza questi flag GD compila lo stesso, ma imagewebp()/imageavif() non
# esistono e ogni tentativo di conversione fallisce a runtime.
RUN docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp --with-avif \
    && docker-php-ext-configure intl \
    && docker-php-ext-install \
        pdo_mysql \
        mbstring \
        exif \
        pcntl \
        bcmath \
        gd \
        zip \
        intl \
        opcache

# Install Redis and Xdebug extensions via pecl. Xdebug solo qui: in staging
# (docker/php/stage/Dockerfile) non e' nemmeno installato, non solo spento a
# runtime - un'estensione in meno da caricare, un'immagine piu' piccola, una
# build piu' veloce.
RUN pecl install redis xdebug && docker-php-ext-enable redis xdebug

# Configure Xdebug
RUN echo "xdebug.mode=debug" >> /usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini \
    && echo "xdebug.start_with_request=yes" >> /usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini \
    && echo "xdebug.client_host=host.docker.internal" >> /usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini \
    && echo "xdebug.client_port=9003" >> /usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini \
    && echo "xdebug.log=/tmp/xdebug.log" >> /usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini \
    && echo "xdebug.idekey=VSCODE" >> /usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini

# Tuning di OPcache, molto piu' leggero di docker/php/stage/Dockerfile: li'
# serve evitare invalidazioni sotto traffico reale (vedi il commento in
# quel file), qui no. Un solo sviluppatore, richieste manuali, e
# `validate_timestamps` resta comunque On (default) perche' il sorgente
# arriva da bind mount e `make update` fa git pull senza riavviare php-fpm -
# quindi la cache si invalida e ricompila da sola a ogni modifica ANCHE con
# questi valori piu' bassi. Riservare 256 MB su un laptop condiviso con
# altri programmi per un vantaggio che qui non si sente sarebbe solo un
# costo.
RUN { \
        echo "opcache.memory_consumption=64"; \
        echo "opcache.interned_strings_buffer=8"; \
        echo "opcache.max_accelerated_files=10000"; \
    } > /usr/local/etc/php/conf.d/zz-opcache-tuning.ini

# Install Composer
COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

# Set working directory
WORKDIR /var/www/html

# Set permissions
# /var/www/.composer non e' un bind mount come html: senza questo, resta di
# proprieta' di root (ereditato dall'immagine base) e `composer install`, che
# gira sempre come www-data (vedi `user: www-data` in docker-compose.yml), non
# puo' scriverci la cache - fallisce silenziosamente con un warning e basta.
RUN mkdir -p /var/www/.composer/cache \
    && chown -R www-data:www-data /var/www/.composer /var/www/html

# Set timezone inside the image (Debian-based)
ENV TZ=Europe/Rome
RUN apt-get update \
    && apt-get install -y --no-install-recommends tzdata \
    && ln -snf /usr/share/zoneinfo/$TZ /etc/localtime \
    && echo $TZ > /etc/timezone \
    && printf "date.timezone=%s\n" "$TZ" > /usr/local/etc/php/conf.d/zz-timezone.ini \
    && rm -rf /var/lib/apt/lists/*

EXPOSE 9000
CMD ["php-fpm"]
