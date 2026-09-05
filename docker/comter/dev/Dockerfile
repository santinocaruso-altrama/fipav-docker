# Immagine di sviluppo per fipav-comter-frontend (Next.js).
#
# Base node + bun installato: bun perche' il progetto ha solo bun.lock (nessun
# package-lock.json) e vogliamo un install riproducibile; node perche' i tool
# di Next lo richiedono e la versione e' vincolata da package.json
# ("engines": { "node": ">=22.12.0" }).
#
# Come per il backoffice il sorgente arriva da bind mount e i node_modules
# stanno in un volume named: quelli dell'host sono compilati per darwin-arm64
# (next-swc, sharp, @tailwindcss/oxide).

FROM node:22-bookworm-slim

# tini come init: senza un PID 1 che inoltri i segnali, il dev server di Next
# ignora SIGTERM e `docker compose down` aspetta i 10s di timeout.
RUN apt-get update \
    && apt-get install -y --no-install-recommends tini curl unzip ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# bun installato via npm: l'installer ufficiale via curl richiede piu' layer e
# non aggiunge nulla per l'uso che ne facciamo (solo `bun install`).
RUN npm install -g bun@1.2.19

ENV TZ=Europe/Rome
ENV NODE_ENV=development

WORKDIR /app

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 3000

# bun serve per l'install, non per il runtime: il binario di next ha shebang
# `#!/usr/bin/env node`, quindi invocandolo direttamente Next gira su node —
# il runtime su cui e' supportato. --hostname 0.0.0.0 perche' di default
# ascolterebbe solo su loopback, irraggiungibile dal gateway.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["./node_modules/.bin/next", "dev", "--hostname", "0.0.0.0", "--port", "3000"]