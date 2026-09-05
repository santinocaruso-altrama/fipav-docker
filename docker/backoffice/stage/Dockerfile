# Immagine di staging per fipav-backoffice (Vite + React): build multi-stage
# DENTRO l'immagine, non piu' a runtime in un bind mount come in dev (vedi
# docker/backoffice/dev/Dockerfile). Il context di questo build e' il repo
# sibling ../fipav-backoffice (non questa cartella) - vedi docker-compose.stage.yml.
#
# Il container che ne risulta non ha un dev server: copia gli asset gia'
# pronti in un volume condiviso col gateway e termina. Zero npm/vite install
# a ogni `docker compose up`: quel lavoro e' successo qui, in fase di build,
# dove Docker puo' anche mettere in cache i layer fra un `make build` e l'altro.

FROM node:22-bookworm-slim AS build
WORKDIR /app

# Solo i manifest prima del sorgente: se package.json/package-lock.json non
# cambiano, Docker riusa questo layer (npm ci compreso) anche se il sorgente
# e' cambiato - la parte piu' lenta della build salta quasi sempre.
COPY package.json package-lock.json ./
RUN npm ci

COPY . .

# VITE_* va iniettato PRIMA di `vite build`: Vite lo sostituisce
# staticamente nel bundle in quel momento (import.meta.env.VITE_SENTRY_DSN),
# un env var solo a runtime non servirebbe a niente qui - il container non
# resta in ascolto, copia gli asset e termina.
ARG VITE_SENTRY_DSN
ENV VITE_SENTRY_DSN=$VITE_SENTRY_DSN

# Stessa ragione del command override che questo Dockerfile sostituisce (vedi
# git blame docker-compose.stage.yml): NODE_ENV va forzato DENTRO il comando,
# non con un ENV prima - con NODE_ENV=production gia' impostato, `npm ci`
# sopra avrebbe messo `dev` in `omit` di default e vite/typescript/tailwind
# non sarebbero stati installati.
RUN export NODE_ENV=production && ./node_modules/.bin/vite build

# ─── Stage finale: nessun processo Node, solo gli asset pronti ───────
#
# Non serve un'immagine Node per un `cp`: alpine basta e pesa una frazione.
FROM alpine:latest
COPY --from=build /app/build /build-output

# Non un ENTRYPOINT/CMD che resta in ascolto: copia e termina, come faceva
# `vite build` in staging prima di questo Dockerfile (restart: "no" in
# docker-compose.stage.yml, invariato).
CMD ["sh", "-c", "cp -a /build-output/. /srv/backoffice/ && echo '[backoffice] Asset copiati in /srv/backoffice.'"]
