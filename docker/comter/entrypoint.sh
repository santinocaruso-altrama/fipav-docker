#!/bin/sh
set -e

# I node_modules vivono in un volume named che maschera quelli dell'host
# (binari darwin-arm64, inutilizzabili in un container linux). Al primo avvio
# il volume e' vuoto e va popolato.
#
# Il marker registra il checksum di bun.lock: se il lockfile cambia l'install
# viene rifatto, altrimenti si salta e il container parte in pochi secondi.

MARKER="node_modules/.install-marker"
LOCKFILE="bun.lock"

if [ ! -f "$LOCKFILE" ]; then
    echo "[comter] ERRORE: $LOCKFILE non trovato in /app."
    echo "[comter] Il bind mount di fipav-comter-frontend non e' montato correttamente."
    exit 1
fi

CURRENT_SUM="$(md5sum "$LOCKFILE" | cut -d' ' -f1)"

if [ ! -f "$MARKER" ] || [ "$(cat "$MARKER")" != "$CURRENT_SUM" ]; then
    echo "[comter] Installazione dipendenze (bun install --frozen-lockfile)..."
    echo "[comter] Al primo avvio richiede qualche minuto; nel frattempo"
    echo "[comter] http://localhost/ risponde 502. E' atteso."
    bun install --frozen-lockfile
    mkdir -p node_modules
    echo "$CURRENT_SUM" > "$MARKER"
    echo "[comter] Dipendenze installate."
else
    echo "[comter] Dipendenze già presenti e allineate al lockfile."
fi

# La cache di build di Next vive nel bind mount: se contiene artefatti prodotti
# su macOS, il dev server in linux fallisce con errori di modulo non trovato.
if [ -d .next ] && [ ! -f .next/.docker-built ]; then
    echo "[comter] Cache .next creata fuori dal container: la rimuovo."
    rm -rf .next
    mkdir -p .next
    touch .next/.docker-built
fi

echo "[comter] Avvio: $*"
exec "$@"