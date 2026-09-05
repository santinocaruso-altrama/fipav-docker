#!/usr/bin/env bash
# Scarica gli upload reali (storage/app/public) dalla macchina di staging al
# Mac, per testare in locale con media veri invece di placeholder.
#
# SOLO remoto -> locale, mai il contrario: apre SSH solo in lettura (rsync
# senza --delete lato remoto, nessun comando che scriva sul remoto). Uno
# script nella direzione opposta rischierebbe di sovrascrivere upload reali
# di utenti sulla macchina di staging - deliberatamente non implementato qui.
#
# Configurazione in rsync.yaml (non tracciato - copia da rsync.yaml.example):
#   host, port, remote_path, local_path
#
# Uso: scripts/sync-storage.sh
# Senza --delete di default: aggiunge/aggiorna, non cancella file locali
# assenti sul remoto (potrebbero essere file di test che tieni solo in
# locale). Per un mirror esatto: scripts/sync-storage.sh --delete
set -euo pipefail
cd "$(dirname "$0")"

CONFIG_FILE="rsync.yaml"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "[sync-storage] Manca $CONFIG_FILE. Copialo da scripts/rsync.yaml.example e"
    echo "[sync-storage] mettici l'host SSH reale della macchina di staging:"
    echo ""
    echo "  cp scripts/rsync.yaml.example scripts/rsync.yaml"
    echo ""
    exit 1
fi

# Lettura testuale (non un parser YAML vero: il file e' volutamente solo
# key: value su una riga, senza nesting - grep basta, come env_value() negli
# altri script di questo repo).
yaml_value() {
    grep -E "^${1}:" "$CONFIG_FILE" | tail -n1 | cut -d':' -f2- | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/'
}

HOST="$(yaml_value host)"
PORT="$(yaml_value port)"
PORT="${PORT:-22}"
IDENTITY_FILE="$(yaml_value identity_file)"
REMOTE_PATH="$(yaml_value remote_path)"
LOCAL_PATH="$(yaml_value local_path)"

for name in HOST REMOTE_PATH LOCAL_PATH; do
    if [ -z "${!name}" ]; then
        echo "[sync-storage] $CONFIG_FILE non ha un valore per '${name,,}'."
        exit 1
    fi
done

# Le barre finali contano per rsync: con la barra sincronizza il CONTENUTO
# della cartella remota dentro quella locale; senza, creerebbe una
# sottocartella in piu' (locale/public invece che locale/*).
REMOTE_PATH="${REMOTE_PATH%/}/"
LOCAL_PATH="${LOCAL_PATH%/}/"

mkdir -p "$LOCAL_PATH"

# Stringa, non un array: la bash 3.2 di stock su macOS tratta
# "${array[@]}" su un array vuoto come variabile non definita sotto `set -u`
# - verificato, romperebbe lo script nel caso comune (nessun --delete).
DELETE_FLAG=""
if [ "${1:-}" = "--delete" ]; then
    echo "[sync-storage] --delete attivo: i file locali assenti sul remoto verranno rimossi."
    DELETE_FLAG="--delete"
fi

SSH_CMD="ssh -p $PORT"
if [ -n "$IDENTITY_FILE" ]; then
    # Espande una `~` iniziale senza eval (il valore viene da un file,
    # meglio non passarlo a eval anche se e' solo config locale).
    IDENTITY_FILE="${IDENTITY_FILE/#\~/$HOME}"
    # IdentitiesOnly=yes forza SSH a usare SOLO questa chiave: senza,
    # prova prima l'agent/le chiavi di default, e se il server le rifiuta
    # tutte finisce per chiedere la password invece di arrivare a questa -
    # il sintomo che si voleva evitare aggiungendo identity_file.
    SSH_CMD="$SSH_CMD -i $IDENTITY_FILE -o IdentitiesOnly=yes"
fi

echo "[sync-storage] $HOST:$REMOTE_PATH -> $LOCAL_PATH"
# shellcheck disable=SC2086
rsync -avz --progress $DELETE_FLAG \
    -e "$SSH_CMD" \
    "$HOST:$REMOTE_PATH" "$LOCAL_PATH"

echo "[sync-storage] Fatto."
