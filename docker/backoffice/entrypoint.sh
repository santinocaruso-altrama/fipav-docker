#!/bin/sh
set -e

# I node_modules vivono in un volume named che maschera quelli dell'host
# (binari darwin-arm64, inutilizzabili in un container linux). Al primo avvio
# il volume e' vuoto e va popolato.
#
# Il marker registra il checksum di package-lock.json: se il lockfile cambia
# (branch diverso, dipendenza aggiunta) l'install viene rifatto, altrimenti si
# salta e il container parte in un paio di secondi.

MARKER="node_modules/.install-marker"
LOCKFILE="package-lock.json"

if [ ! -f "$LOCKFILE" ]; then
    echo "[backoffice] ERRORE: $LOCKFILE non trovato in /app."
    echo "[backoffice] Il bind mount di fipav-backoffice non e' montato correttamente."
    exit 1
fi

CURRENT_SUM="$(md5sum "$LOCKFILE" | cut -d' ' -f1)"

if [ ! -f "$MARKER" ] || [ "$(cat "$MARKER")" != "$CURRENT_SUM" ]; then
    echo "[backoffice] Installazione dipendenze (npm ci)..."
    echo "[backoffice] Al primo avvio richiede qualche minuto; nel frattempo"
    echo "[backoffice] http://localhost/backoffice/ risponde 502. E' atteso."
    npm ci
    mkdir -p node_modules
    echo "$CURRENT_SUM" > "$MARKER"
    echo "[backoffice] Dipendenze installate."
else
    echo "[backoffice] Dipendenze già presenti e allineate al lockfile."
fi

echo "[backoffice] Avvio: $*"
exec "$@"