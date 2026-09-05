#!/usr/bin/env bash
# Rigenera docker/gateway/stage/sites.conf dai comitati attivi in DB, e se
# e' cambiato ricarica SOLO la configurazione di Caddy (nessun container
# ricreato). Solo per staging: in locale il sito e' docker/gateway/dev/
# sites.conf, statico, e questo script esce subito. In produzione non serve nemmeno in staging:
# la produzione gira su tutt'altro stack, con un certificato wildcard.
#
# La fonte di verita' e' la stessa tabella che il backend usa per risolvere
# il tenant a runtime (vedi
# fipav-core/src/app/Http/Middleware/IdentifyTenant.php): `tenants.slug` con
# `attivo = 1`. Ogni slug attivo diventa un blocco
# "<slug>.$COMTER_ROOT_DOMAIN { import site }" nel file che Caddy importa.
#
# NON include $COMTER_ROOT_DOMAIN da solo (senza sottodominio): quasi
# certamente non risolve via DNS (un record A wildcard *.dominio NON copre
# l'apice dominio, serve un record A separato) - un blocco per un hostname
# che non risolve fa solo fallire Automatic HTTPS in loop. Le chiamate
# server-side di comter non ne hanno comunque bisogno: vedi il blocco statico
# "http://gateway" nel Caddyfile, che non dipende da nessun hostname pubblico.
#
# Uso: scripts/sync-sites.sh   (o `make sync-sites`, o dentro `make up-stage`)
#
# Non parla ACME/challenge di persona: si limita a dire a Caddy quali
# hostname servire, e Caddy fa il resto (Automatic HTTPS) come gia' fa oggi.
set -euo pipefail
cd "$(dirname "$0")/.."

SITES_FILE="docker/gateway/stage/sites.conf"

# Con .env.stage assente lo stack non e' configurato per lo staging: niente
# da generare.
if [ ! -f .env.stage ]; then
    echo "[sync-sites] Nessun .env.stage: niente da sincronizzare (serve per lo staging)."
    exit 0
fi

# Lettura testuale della riga, non un source del file: .env.stage puo'
# contenere valori con `$` non pensati per l'espansione di shell (es. l'hash
# bcrypt di HORIZON_BASIC_AUTH_HASH, "$2a$14$..."), che un `source` proverebbe
# a espandere come parametri posizionali e romperebbe lo script sotto `set -u`.
env_value() {
    grep -E "^${1}=" .env.stage | tail -n1 | cut -d'=' -f2-
}

ROOT_DOMAIN="$(env_value COMTER_ROOT_DOMAIN)"

if [ -z "$ROOT_DOMAIN" ] || [ "$ROOT_DOMAIN" = "localhost" ]; then
    echo "[sync-sites] COMTER_ROOT_DOMAIN non e' impostato su un dominio pubblico"
    echo "[sync-sites] (vale '$ROOT_DOMAIN'): questo script serve solo in staging."
    exit 0
fi

if [ -z "$(docker compose ps -q mariadb 2>/dev/null)" ]; then
    echo "[sync-sites] mariadb non e' in esecuzione: avvia lo stack prima (make up-stage)."
    exit 1
fi

# -N: niente intestazioni di colonna. -s: niente bordi/tabulazione tra
# colonne (qui ce n'e' una sola, ma -s evita ambiguita' se in futuro se ne
# aggiunge un'altra). Credenziali da .env.stage, non hardcoded: dopo un
# `make rotate-db-password` l'utente fipav/fipav di default non e' piu'
# quello vero, e questo script gira anche da solo dentro `make up-stage`.
DB_USER="$(env_value MARIADB_USER)"
DB_USER="${DB_USER:-fipav}"
DB_PASSWORD="$(env_value MARIADB_PASSWORD)"
DB_PASSWORD="${DB_PASSWORD:-fipav}"

SLUGS="$(docker compose exec -T mariadb \
    mariadb -u"$DB_USER" -p"$DB_PASSWORD" -N -s \
    -e "SELECT slug FROM tenants WHERE attivo = 1 ORDER BY slug" \
    camp2013)"

OLD_CONTENT="$([ -f "$SITES_FILE" ] && cat "$SITES_FILE" || true)"

# Quanti blocchi hostname c'erano gia': se erano piu' di zero e la query
# torna zero comitati, e' quasi certamente un errore di connessione al DB,
# non un elenco davvero svuotato - meglio fermarsi che pubblicare un file
# dimezzato (che toglierebbe di colpo i certificati di TUTTI i comitati).
OLD_HOST_COUNT="$(grep -cE '^[a-zA-Z0-9.-]+ \{' "$SITES_FILE" 2>/dev/null || true)"
if [ -z "$SLUGS" ] && [ "${OLD_HOST_COUNT:-0}" -gt 0 ]; then
    echo "[sync-sites] Nessun tenant attivo trovato, ma $SITES_FILE ne aveva $OLD_HOST_COUNT:"
    echo "[sync-sites] non lo tocco (sembra un errore di connessione al DB, non un"
    echo "[sync-sites] elenco comitati davvero svuotato)."
    exit 1
fi

if [ -n "$SLUGS" ]; then
    NEW_CONTENT="$(awk -v domain="$ROOT_DOMAIN" '
        BEGIN { print "# Generato da scripts/sync-sites.sh - non modificare a mano." }
        { printf "%s.%s {\n\timport site\n}\n", $0, domain }
    ' <<< "$SLUGS")"
else
    NEW_CONTENT="$(printf '# Nessun comitato attivo in tenants (camp2013). Rigenerato da\n# scripts/sync-sites.sh - non modificare a mano.\n')"
fi

if [ "$NEW_CONTENT" = "$OLD_CONTENT" ]; then
    echo "[sync-sites] $SITES_FILE gia' allineato. Nessuna modifica."
    exit 0
fi

echo "$NEW_CONTENT" > "$SITES_FILE"
echo "[sync-sites] $SITES_FILE aggiornato:"
if [ -n "$SLUGS" ]; then
    echo "$SLUGS" | sed 's/^/[sync-sites]   /'
else
    echo "[sync-sites]   (nessun comitato attivo)"
fi

if [ -z "$(docker compose ps -q gateway 2>/dev/null)" ]; then
    echo "[sync-sites] Il gateway non e' ancora su: il file e' pronto per il suo primo avvio."
    exit 0
fi

echo "[sync-sites] Ricarico la configurazione di Caddy (nessun container ricreato)..."
docker compose exec gateway caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile

echo "[sync-sites] Fatto. Segui l'emissione dei certificati nuovi con:"
echo "[sync-sites]   make logs-gateway"
