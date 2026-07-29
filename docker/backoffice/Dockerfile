# Immagine di sviluppo per fipav-backoffice (Vite + React).
#
# Il sorgente non viene copiato nell'immagine: arriva da un bind mount cosi'
# che l'HMR veda le modifiche fatte sul Mac. Le dipendenze vengono installate
# a runtime dall'entrypoint in un volume named, perche' i node_modules
# dell'host sono compilati per darwin-arm64 (esbuild, @vitejs/plugin-react-swc,
# @tailwindcss/oxide) e non sono utilizzabili qui.

FROM node:22-bookworm-slim

# tini come init: senza un PID 1 che inoltri i segnali, il dev server di Vite
# ignora SIGTERM e `docker compose down` aspetta i 10s di timeout.
RUN apt-get update \
    && apt-get install -y --no-install-recommends tini curl \
    && rm -rf /var/lib/apt/lists/*

ENV TZ=Europe/Rome
ENV NODE_ENV=development

# Segnala a vite.config.ts di usare il profilo container (host 0.0.0.0,
# nessuna apertura del browser, Host arbitrari ammessi, HMR sulla porta del
# gateway). Vedi fipav-backoffice/vite.config.ts.
ENV DOCKER_DEV=true

WORKDIR /app

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 3000

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["npm", "run", "dev"]