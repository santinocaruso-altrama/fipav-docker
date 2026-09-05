# Immagine di staging per fipav-core (Laravel): identica a
# docker/php/dev/Dockerfile tranne per Xdebug, non installato qui - inutile
# su una macchina pubblica (nessuno si collega con un IDE), e un'estensione
# in meno da caricare, un'immagine piu' piccola, una build piu' veloce.
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

# Install Redis extension via pecl. Nessun Xdebug: vedi il commento in cima
# al file.
RUN pecl install redis && docker-php-ext-enable redis

# Tuning di OPcache, piu' alto di docker/php/dev/Dockerfile (li' un solo
# sviluppatore non sente il vantaggio, qui traffico reale si'). E' gia'
# abilitato di default da PHP, ma con i default generici (128 MB, 10000
# file). fipav-core da solo conta 9587 file .php: al
# primo margine di crescita (una dipendenza composer in piu') si supera il
# tetto e opcache ricomincia a invalidare/ricompilare invece di servire dalla
# cache, vanificando il vantaggio. `validate_timestamps` resta On (default):
# il sorgente arriva da bind mount e `make update` fa git pull senza
# riavviare php-fpm, quindi serve che opcache si accorga dei file cambiati
# senza un restart esplicito del container.
RUN { \
        echo "opcache.memory_consumption=256"; \
        echo "opcache.interned_strings_buffer=16"; \
        echo "opcache.max_accelerated_files=20000"; \
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
