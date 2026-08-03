#!/usr/bin/env bash
# Diagnostica lentezza dello stack: isola rete, disco e applicativo con una
# sequenza di misure, poi stampa un riepilogo con soglie indicative.
#
# Va eseguito sulla macchina dove gira lo stack (dev o staging), da questa
# cartella o con `make diagnose`. Assume che i container siano su.
#
# Uso: docker/diagnose.sh [dominio]
# Default dominio: quello pubblico di staging.
#
# Il confronto chiave e' tra il curl "esterno" (DNS reale + rete pubblica +
# TLS + gateway + app) e quello con --resolve forzato su 127.0.0.1 (stessa
# richiesta ma senza uscire dalla macchina): se il secondo e' quasi altrettanto
# lento, il problema non e' la rete tra il client e il server.
set -uo pipefail
cd "$(dirname "$0")/.."

DOMAIN_URL="${1:-https://calabria.fipav.altrama.it/}"
HOST="$(echo "$DOMAIN_URL" | sed -E 's#^https?://##; s#/.*##')"
OUTDIR="diagnose-$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUTDIR"
SUMMARY="$OUTDIR/summary.txt"

CURL_FMT='dns=%{time_namelookup} connect=%{time_connect} tls=%{time_appconnect} ttfb=%{time_starttransfer} total=%{time_total} code=%{http_code}'

log() { echo "$@" | tee -a "$SUMMARY"; }
section() { log ""; log "=== $1 ==="; }

have() { command -v "$1" >/dev/null 2>&1; }

avg_field() {
    # avg_field <file> <nomecampo> - media di un campo "nome=valore" su piu' righe
    awk -F "$2=" '{split($2,a," "); sum+=a[1]; n++} END {if (n>0) printf "%.3f", sum/n; else print "n/d"}' "$1"
}

# ─── 0. Stato di tutti i servizi + limiti configurati ────────────────────

section "0. Stato servizi e limiti risorse"
log "-- docker compose ps --"
docker compose ps -a | tee -a "$SUMMARY"

log ""
log "-- Risorse host --"
if have nproc; then log "CPU core disponibili: $(nproc)"; fi
if have free; then free -h | tee -a "$SUMMARY"; fi

log ""
log "-- Limiti configurati per container (nessuno = puo' usare tutta la risorsa host) --"
CONTAINERS=$(docker compose ps -a -q)
{
    printf "%-24s %-10s %-12s\n" "CONTAINER" "CPU LIMIT" "MEM LIMIT"
    for c in $CONTAINERS; do
        NAME=$(docker inspect -f '{{.Name}}' "$c" | sed 's#^/##')
        NANOCPUS=$(docker inspect -f '{{.HostConfig.NanoCpus}}' "$c")
        MEMBYTES=$(docker inspect -f '{{.HostConfig.Memory}}' "$c")
        CPULIM="nessuno"
        [ "$NANOCPUS" != "0" ] && CPULIM=$(awk -v n="$NANOCPUS" 'BEGIN{printf "%.2f", n/1000000000}')
        MEMLIM="nessuno"
        [ "$MEMBYTES" != "0" ] && MEMLIM=$(awk -v b="$MEMBYTES" 'BEGIN{printf "%.0fMB", b/1024/1024}')
        printf "%-24s %-10s %-12s\n" "$NAME" "$CPULIM" "$MEMLIM"
    done
} | tee -a "$SUMMARY"

# ─── 1. Curl esterno: percorso reale del client ──────────────────────────

section "1. Curl esterno (DNS reale, rete pubblica, TLS, gateway, app)"
EXT_FILE="$OUTDIR/curl_esterno.txt"
: > "$EXT_FILE"
for i in 1 2 3; do
    curl -s -o /dev/null -w "$CURL_FMT\n" --max-time 20 "$DOMAIN_URL" >> "$EXT_FILE" 2>>"$OUTDIR/curl_esterno.err" || echo "code=ERR" >> "$EXT_FILE"
done
cat "$EXT_FILE" | tee -a "$SUMMARY"
EXT_TOTAL_AVG=$(avg_field "$EXT_FILE" total)
EXT_TTFB_AVG=$(avg_field "$EXT_FILE" ttfb)
log "media total=${EXT_TOTAL_AVG}s ttfb=${EXT_TTFB_AVG}s"

# ─── 2. Stesso URL ma senza uscire dalla macchina ────────────────────────

section "2. Curl con --resolve su 127.0.0.1 (stessa richiesta, senza rete pubblica)"
LOCAL_FILE="$OUTDIR/curl_locale.txt"
: > "$LOCAL_FILE"
for i in 1 2 3; do
    curl -s -o /dev/null -w "$CURL_FMT\n" --max-time 20 --resolve "${HOST}:443:127.0.0.1" "$DOMAIN_URL" >> "$LOCAL_FILE" 2>>"$OUTDIR/curl_locale.err" || echo "code=ERR" >> "$LOCAL_FILE"
done
cat "$LOCAL_FILE" | tee -a "$SUMMARY"
LOCAL_TOTAL_AVG=$(avg_field "$LOCAL_FILE" total)
LOCAL_TTFB_AVG=$(avg_field "$LOCAL_FILE" ttfb)
log "media total=${LOCAL_TOTAL_AVG}s ttfb=${LOCAL_TTFB_AVG}s"

# ─── 3. Tempo diretto sul layer applicativo (fipav-core, dentro nginx) ───

section "3. Tempo diretto fipav-core (dentro il container nginx, salta gateway/TLS)"
CORE_MS="n/d"
if docker compose exec -T nginx sh -c 'command -v wget' >/dev/null 2>&1; then
    CORE_MS=$(docker compose exec -T nginx sh -c \
        'start=$(date +%s%N); wget -q -O /dev/null http://localhost/ 2>/dev/null; end=$(date +%s%N); echo $(( (end-start)/1000000 ))' 2>>"$OUTDIR/core.err")
    log "fipav-core (nginx->php-fpm), senza gateway/TLS: ${CORE_MS} ms"
else
    log "wget non disponibile nel container nginx, salto questa misura"
fi

# ─── 4. Tempo diretto su comter (Next.js) ────────────────────────────────

section "4. Tempo diretto comter (dentro il container, salta gateway/TLS)"
COMTER_MS="n/d"
if docker compose exec -T comter sh -c 'command -v wget' >/dev/null 2>&1; then
    COMTER_MS=$(docker compose exec -T comter sh -c \
        'start=$(date +%s%N); wget -q -O /dev/null http://localhost:3000/ 2>/dev/null; end=$(date +%s%N); echo $(( (end-start)/1000000 ))' 2>>"$OUTDIR/comter.err")
    log "comter (Next.js), senza gateway/TLS: ${COMTER_MS} ms"
else
    log "wget non disponibile nel container comter, salto questa misura"
fi

# ─── 5. Risorse per container ────────────────────────────────────────────

section "5. docker stats (CPU / memoria / IO per container)"
STATS_FILE="$OUTDIR/docker_stats.txt"
docker stats --no-stream --format "{{.Name}}|{{.CPUPerc}}|{{.MemPerc}}|{{.MemUsage}}|{{.NetIO}}|{{.BlockIO}}" > "$STATS_FILE"
{
    printf "%-24s %-8s %-8s %-20s %-20s %-20s\n" "CONTAINER" "CPU%" "MEM%" "MEM USAGE" "NET IO" "BLOCK IO"
    awk -F'|' '{printf "%-24s %-8s %-8s %-20s %-20s %-20s\n", $1, $2, $3, $4, $5, $6}' "$STATS_FILE"
} | tee -a "$SUMMARY"

CORES=$(nproc 2>/dev/null || echo 1)
CPU_BUDGET=$(awk -v c="$CORES" 'BEGIN{printf "%.0f", c*100*0.8}')
FLAGGED="$OUTDIR/sfora_risorse.txt"
: > "$FLAGGED"
awk -F'|' -v cpubudget="$CPU_BUDGET" -v cores="$CORES" '{
    cpu=$2; sub(/%/,"",cpu);
    mem=$3; sub(/%/,"",mem);
    if (cpu+0 > cpubudget+0) print $1": CPU al "$2" (soglia: 80% di "cores" core = "cpubudget"%)";
    if (mem+0 > 80) print $1": MEM al "$3" (soglia: 80% della RAM assegnabile)";
}' "$STATS_FILE" > "$FLAGGED"
if [ -s "$FLAGGED" ]; then
    log ""
    log "-- Container che sforano le soglie (CPU>80% di ${CORES} core, MEM>80%) --"
    cat "$FLAGGED" | tee -a "$SUMMARY"
else
    log ""
    log "Nessun container sopra l'80% di CPU o memoria in questo snapshot."
fi

# ─── 6. Disco ─────────────────────────────────────────────────────────────

section "6. Disco"
log "-- df -h --"
df -h | tee -a "$SUMMARY"
if have iostat; then
    log ""
    log "-- iostat -x (3 campioni, 1s) --"
    iostat -x 1 3 | tee -a "$SUMMARY"
else
    log "iostat non installato (sysstat). Su Debian/Ubuntu: apt install sysstat"
fi

# ─── 7. MariaDB ───────────────────────────────────────────────────────────

section "7. MariaDB (query attive, slow query, connessioni)"
DB_FILE="$OUTDIR/mariadb.txt"
if docker compose exec -T mariadb mariadb -ufipav -pfipav camp2013 \
    -e "SHOW FULL PROCESSLIST; SHOW GLOBAL STATUS LIKE 'Slow_queries'; SHOW GLOBAL STATUS LIKE 'Threads_connected'; SHOW GLOBAL STATUS LIKE 'Threads_running';" \
    > "$DB_FILE" 2>&1; then
    cat "$DB_FILE" | tee -a "$SUMMARY"
else
    log "impossibile interrogare mariadb (vedi $DB_FILE)"
    cat "$DB_FILE" >> "$SUMMARY"
fi

# ─── 8. Redis ─────────────────────────────────────────────────────────────

section "8. Redis (latenza PING)"
if docker compose exec -T redis redis-cli --no-raw PING >/dev/null 2>&1; then
    docker compose exec -T redis redis-cli --latency -i 1 > /tmp/redis-latency.$$ 2>/dev/null &
    RPID=$!
    sleep 2
    kill "$RPID" 2>/dev/null
    wait "$RPID" 2>/dev/null
    tail -n 1 /tmp/redis-latency.$$ 2>/dev/null | tee -a "$SUMMARY"
    rm -f /tmp/redis-latency.$$
else
    log "redis non raggiungibile"
fi

# ─── Riepilogo ────────────────────────────────────────────────────────────

section "RIEPILOGO"
log "Esterno   (rete+TLS+app): total=${EXT_TOTAL_AVG}s  ttfb=${EXT_TTFB_AVG}s"
log "Locale    (solo TLS+app): total=${LOCAL_TOTAL_AVG}s  ttfb=${LOCAL_TTFB_AVG}s"
log "fipav-core diretto      : ${CORE_MS} ms"
log "comter diretto          : ${COMTER_MS} ms"
log ""

verdict() {
    awk -v ext="$EXT_TOTAL_AVG" -v loc="$LOCAL_TOTAL_AVG" 'BEGIN {
        if (ext == "n/d" || loc == "n/d") { print "Dati insufficienti per un verdetto automatico."; exit }
        diff = ext - loc
        if (diff > 0.3) {
            printf "La differenza esterno/locale e'"'"' di %.2fs: parte del ritardo e'"'"' fuori dalla macchina (rete/DNS/routing verso il client).\n", diff
        } else {
            print "Il ritardo esterno e locale sono simili: il problema NON e'"'"' la rete tra client e server, cerca in disco/applicativo/DB qui sotto."
        }
    }'
}
verdict | tee -a "$SUMMARY"

log ""
log "Controlla in docker stats sopra se un container ha CPU vicina al 100%"
log "o BLOCK I/O molto piu alto degli altri: e il sospetto principale per il layer applicativo."
log "Controlla df -h e iostat per il disco (%util alto = disco saturo)."
log "Controlla SHOW FULL PROCESSLIST per query MariaDB ferme a lungo."
log ""
log "Report completo salvato in: $OUTDIR/"
