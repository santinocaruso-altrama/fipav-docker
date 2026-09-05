#!/usr/bin/env bash
# Ruota la password dell'utente applicativo (default "fipav") su un volume
# mariadb GIA' ESISTENTE - l'unico modo che funziona davvero: MARIADB_PASSWORD
# nel .env.stage non ha effetto su un volume gia' popolato (l'entrypoint di
# MariaDB lo legge solo alla creazione del volume, mai piu' dopo - vedi
# .env.example). Serve un ALTER USER sul database live.
#
# Fa tre cose in ordine, e si ferma al primo errore:
#   1. ALTER USER sul DB live (mariadb deve essere in esecuzione)
#   2. aggiorna MARIADB_PASSWORD in .env.stage
#   3. aggiorna DB_PASSWORD in ../fipav-core/src/.env
# Le due copie devono SEMPRE coincidere (`make up-stage` lo controlla prima
# di partire): farlo in un solo script evita di dimenticarne una a meta'.
#
# Uso: scripts/rotate-db-password.sh [nuova-password]   (o `make rotate-db-password`)
# Senza argomento, ne genera una con `openssl rand -base64 24`.
#
# NON riavvia php/horizon da solo: i processi gia' in esecuzione tengono la
# connessione aperta con la vecchia password finche' non li riavvii a mano
# con `make restart`, l'ultimo passo dopo questo script.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -z "$(docker compose ps -q mariadb 2>/dev/null)" ]; then
    echo "[rotate-db-password] mariadb non e' in esecuzione: avvia lo stack prima (make up-stage)."
    exit 1
fi

NEW_PASSWORD="${1:-$(openssl rand -base64 24)}"

# Stessa lettura testuale (non source) usata da sync-sites.sh/backup-db.sh:
# un .env.stage puo' contenere valori con `$` non pensati per l'espansione
# di shell.
env_value() {
    grep -E "^${2}=" "$1" 2>/dev/null | tail -n1 | cut -d'=' -f2-
}

ROOT_PASSWORD="$(env_value .env.stage MARIADB_ROOT_PASSWORD)"
ROOT_PASSWORD="${ROOT_PASSWORD:-root}"
DB_USER="$(env_value .env.stage MARIADB_USER)"
DB_USER="${DB_USER:-fipav}"

echo "[rotate-db-password] Ruoto la password di '$DB_USER'@'%' sul DB live..."
docker compose exec -T mariadb mariadb -uroot -p"$ROOT_PASSWORD" \
    -e "ALTER USER '$DB_USER'@'%' IDENTIFIED BY '$NEW_PASSWORD'"

# Aggiorna (o aggiunge) KEY=... in un file .env, senza toccare il resto.
update_env() {
    local file="$1" key="$2" value="$3"
    if grep -q "^${key}=" "$file" 2>/dev/null; then
        sed -i.bak "s|^${key}=.*|${key}=${value}|" "$file"
        rm -f "$file.bak"
    else
        printf '%s=%s\n' "$key" "$value" >> "$file"
    fi
}

echo "[rotate-db-password] Aggiorno .env.stage..."
update_env .env.stage MARIADB_PASSWORD "$NEW_PASSWORD"

CORE_ENV="../fipav-core/src/.env"
if [ -f "$CORE_ENV" ]; then
    echo "[rotate-db-password] Aggiorno $CORE_ENV..."
    update_env "$CORE_ENV" DB_PASSWORD "$NEW_PASSWORD"
else
    echo "[rotate-db-password] $CORE_ENV non trovato: aggiorna DB_PASSWORD li' a mano."
fi

echo ""
echo "[rotate-db-password] Fatto. Nuova password: $NEW_PASSWORD"
echo "[rotate-db-password] Applicala ai processi gia' in esecuzione con: make restart"
