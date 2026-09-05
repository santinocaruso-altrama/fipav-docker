# Immagine di staging per fipav-comter-frontend (Next.js): build multi-stage
# DENTRO l'immagine, non piu' a runtime in un bind mount come in dev (vedi
# docker/comter/dev/Dockerfile). Il context di questo build e' il repo
# sibling ../fipav-comter-frontend (non questa cartella) - vedi
# docker-compose.stage.yml.
#
# A differenza di backoffice (che compila e termina), comter resta un
# server persistente (`next start`): questa immagine parte gia' pronta,
# senza bind mount del sorgente ne' volume node_modules - il container si
# ricrea per deployare codice nuovo (serve un `make build` prima).

FROM node:22-bookworm-slim AS build
WORKDIR /app

# bun installato via npm, stesso motivo del Dockerfile di dev: l'installer
# ufficiale via curl richiede piu' layer e non aggiunge nulla per il solo
# `bun install`.
RUN npm install -g bun@1.2.19

# Solo i manifest prima del sorgente: se package.json/bun.lock non cambiano,
# Docker riusa questo layer (bun install compreso) anche se il sorgente e'
# cambiato - la parte piu' lenta della build salta quasi sempre.
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile

COPY . .

# NEXT_PUBLIC_* va iniettato PRIMA di `next build`: Next lo sostituisce
# staticamente nel bundle browser in quel momento, un env var solo a runtime
# (docker-compose.yml, per il lato server) non basterebbe per il client.
ARG NEXT_PUBLIC_SENTRY_DSN
ENV NEXT_PUBLIC_SENTRY_DSN=$NEXT_PUBLIC_SENTRY_DSN

# Stessa ragione del command override che questo Dockerfile sostituisce (vedi
# git blame docker-compose.stage.yml): NODE_ENV va forzato DENTRO il comando,
# non con un ENV prima - `next build` lo imposta da se' solo se non e' gia'
# valorizzato, e trovandolo a "development" (readable dal Dockerfile di dev,
# qui non c'entra ma il rischio e' lo stesso) risolverebbe react/react-dom con
# la export condition sbagliata durante il prerender, con l'app che muore su
# /_global-error: "Cannot read properties of null (reading 'useContext')".
RUN export NODE_ENV=production && ./node_modules/.bin/next build

# ─── Stage finale: server persistente, immagine self-contained ──────
FROM node:22-bookworm-slim AS runtime

# tini come init: senza un PID 1 che inoltri i segnali, Next ignora SIGTERM e
# `docker compose down` aspetta i 10s di timeout - stesso motivo del
# Dockerfile di dev, qui serve ancora perche' il processo resta in ascolto.
RUN apt-get update \
    && apt-get install -y --no-install-recommends tini \
    && rm -rf /var/lib/apt/lists/*

ENV TZ=Europe/Rome
ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1

WORKDIR /app

# L'intera /app della fase di build, node_modules compreso: senza
# `output: "standalone"` in next.config.ts, `next start` si aspetta i
# node_modules completi, non un bundle ridotto.
COPY --from=build /app ./

EXPOSE 3000

# --hostname 0.0.0.0 perche' di default ascolterebbe solo su loopback,
# irraggiungibile dal gateway.
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["./node_modules/.bin/next", "start", "--hostname", "0.0.0.0", "--port", "3000"]
