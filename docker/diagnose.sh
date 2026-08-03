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

# Con locale it_IT, awk usa la virgola come separatore decimale e non
# riconosce piu' i numeri con il punto (es. "0.166518" letto come 0): tutte
# le medie e le soglie sotto risulterebbero azzerate. LC_ALL=C forza il punto
# ovunque nello script, indipendentemente dal locale della macchina.
export LC_ALL=C

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

# Tabella finale OK/WARNING/KO: ogni test aggiunge una riga con add_result,
# classify_num decide lo stato in base a due soglie (buono/attenzione/critico).
RESULTS_FILE="$OUTDIR/results.tsv"
: > "$RESULTS_FILE"
add_result() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$RESULTS_FILE"; }

classify_num() {
    # classify_num <valore> <soglia_ok> <soglia_warning> - oltre soglia_warning e' KO.
    # "n/d" (dato non misurabile) e' trattato come WARNING, non KO: non e' detto
    # che il test sia fallito, spesso e' solo uno strumento mancante.
    local v="$1" ok="$2" warn="$3"
    if [ "$v" = "n/d" ]; then echo "WARNING"; return; fi
    awk -v v="$v" -v ok="$ok" -v warn="$warn" 'BEGIN {
        if (v+0 <= ok+0) print "OK";
        else if (v+0 <= warn+0) print "WARNING";
        else print "KO";
    }'
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
TOTAL_CONTAINERS=0
NOT_RUNNING_COUNT=0
NOT_RUNNING_NAMES=""
{
    printf "%-24s %-10s %-12s %-10s\n" "CONTAINER" "CPU LIMIT" "MEM LIMIT" "STATO"
    for c in $CONTAINERS; do
        NAME=$(docker inspect -f '{{.Name}}' "$c" | sed 's#^/##')
        NANOCPUS=$(docker inspect -f '{{.HostConfig.NanoCpus}}' "$c")
        MEMBYTES=$(docker inspect -f '{{.HostConfig.Memory}}' "$c")
        STATE=$(docker inspect -f '{{.State.Status}}' "$c")
        CPULIM="nessuno"
        [ "$NANOCPUS" != "0" ] && CPULIM=$(awk -v n="$NANOCPUS" 'BEGIN{printf "%.2f", n/1000000000}')
        MEMLIM="nessuno"
        [ "$MEMBYTES" != "0" ] && MEMLIM=$(awk -v b="$MEMBYTES" 'BEGIN{printf "%.0fMB", b/1024/1024}')
        printf "%-24s %-10s %-12s %-10s\n" "$NAME" "$CPULIM" "$MEMLIM" "$STATE"
        TOTAL_CONTAINERS=$((TOTAL_CONTAINERS + 1))
        if [ "$STATE" != "running" ]; then
            NOT_RUNNING_COUNT=$((NOT_RUNNING_COUNT + 1))
            NOT_RUNNING_NAMES="$NOT_RUNNING_NAMES $NAME($STATE)"
        fi
    done
} | tee -a "$SUMMARY"

if [ "$TOTAL_CONTAINERS" -eq 0 ]; then
    add_result "Servizi Docker" "KO" "nessun container trovato (Docker non raggiungibile o stack giu')"
elif [ "$NOT_RUNNING_COUNT" -eq 0 ]; then
    add_result "Servizi Docker" "OK" "$TOTAL_CONTAINERS container, tutti running"
else
    add_result "Servizi Docker" "KO" "${NOT_RUNNING_COUNT}/${TOTAL_CONTAINERS} non running:$NOT_RUNNING_NAMES"
fi

# ─── 1. Curl esterno: percorso reale del client ──────────────────────────

section "1. Curl esterno (DNS reale, rete pubblica, TLS, gateway, app)"
EXT_FILE="$OUTDIR/curl_esterno.txt"
: > "$EXT_FILE"
for i in 1 2 3; do
    # curl scrive il formato -w anche quando la richiesta fallisce (code=000),
    # quindi niente fallback aggiuntivo: raddoppierebbe le righe e falserebbe la media.
    curl -s -o /dev/null -w "$CURL_FMT\n" --max-time 20 "$DOMAIN_URL" >> "$EXT_FILE" 2>>"$OUTDIR/curl_esterno.err"
done
cat "$EXT_FILE" | tee -a "$SUMMARY"
EXT_TOTAL_AVG=$(avg_field "$EXT_FILE" total)
EXT_TTFB_AVG=$(avg_field "$EXT_FILE" ttfb)
log "media total=${EXT_TOTAL_AVG}s ttfb=${EXT_TTFB_AVG}s"
EXT_CODE=$(grep -o 'code=[0-9]*' "$EXT_FILE" | tail -1 | cut -d= -f2)
STATUS1=$(classify_num "$EXT_TOTAL_AVG" 1.0 3.0)
if [ -z "$EXT_CODE" ] || { [ "${EXT_CODE#2}" = "$EXT_CODE" ] && [ "${EXT_CODE#3}" = "$EXT_CODE" ]; }; then
    STATUS1="KO"
    EXT_CODE="${EXT_CODE:-nessuna risposta}"
fi
add_result "Curl esterno (rete+TLS+app)" "$STATUS1" "total medio ${EXT_TOTAL_AVG}s, HTTP ${EXT_CODE}"

# ─── 2. Stesso URL ma senza uscire dalla macchina ────────────────────────

section "2. Curl con --resolve su 127.0.0.1 (stessa richiesta, senza rete pubblica)"
LOCAL_FILE="$OUTDIR/curl_locale.txt"
: > "$LOCAL_FILE"
for i in 1 2 3; do
    curl -s -o /dev/null -w "$CURL_FMT\n" --max-time 20 --resolve "${HOST}:443:127.0.0.1" "$DOMAIN_URL" >> "$LOCAL_FILE" 2>>"$OUTDIR/curl_locale.err"
done
cat "$LOCAL_FILE" | tee -a "$SUMMARY"
LOCAL_TOTAL_AVG=$(avg_field "$LOCAL_FILE" total)
LOCAL_TTFB_AVG=$(avg_field "$LOCAL_FILE" ttfb)
log "media total=${LOCAL_TOTAL_AVG}s ttfb=${LOCAL_TTFB_AVG}s"
LOCAL_CODE=$(grep -o 'code=[0-9]*' "$LOCAL_FILE" | tail -1 | cut -d= -f2)
STATUS2=$(classify_num "$LOCAL_TOTAL_AVG" 1.0 3.0)
if [ -z "$LOCAL_CODE" ] || { [ "${LOCAL_CODE#2}" = "$LOCAL_CODE" ] && [ "${LOCAL_CODE#3}" = "$LOCAL_CODE" ]; }; then
    STATUS2="KO"
    LOCAL_CODE="${LOCAL_CODE:-nessuna risposta}"
fi
add_result "Curl locale (solo TLS+app)" "$STATUS2" "total medio ${LOCAL_TOTAL_AVG}s, HTTP ${LOCAL_CODE}"

if [ "$EXT_TOTAL_AVG" != "n/d" ] && [ "$LOCAL_TOTAL_AVG" != "n/d" ]; then
    NET_DIFF=$(awk -v e="$EXT_TOTAL_AVG" -v l="$LOCAL_TOTAL_AVG" 'BEGIN{printf "%.3f", e-l}')
    STATUS_NET=$(classify_num "$NET_DIFF" 0.3 1.0)
    add_result "Rete (differenza esterno - locale)" "$STATUS_NET" "diff ${NET_DIFF}s"
else
    add_result "Rete (differenza esterno - locale)" "WARNING" "dati insufficienti per il confronto"
fi

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
STATUS3=$(classify_num "$CORE_MS" 300 1000)
add_result "fipav-core diretto (no gateway/TLS)" "$STATUS3" "${CORE_MS} ms"

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
STATUS4=$(classify_num "$COMTER_MS" 300 1000)
add_result "comter diretto (no gateway/TLS)" "$STATUS4" "${COMTER_MS} ms"

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
    FLAG_COUNT=$(wc -l < "$FLAGGED" | tr -d ' ')
    STATUS5="WARNING"
    [ "$FLAG_COUNT" -ge 3 ] && STATUS5="KO"
    add_result "Risorse container (CPU/MEM)" "$STATUS5" "$FLAG_COUNT segnalazioni sopra soglia"
else
    log ""
    log "Nessun container sopra l'80% di CPU o memoria in questo snapshot."
    add_result "Risorse container (CPU/MEM)" "OK" "nessun container sopra le soglie"
fi

# ─── 6. Disco ─────────────────────────────────────────────────────────────

section "6. Disco"
log "-- df -h --"
df -h | tee -a "$SUMMARY"
DISK_PCT=$(df -P / | awk 'NR==2{gsub("%","",$5); print $5}')
STATUS_DISK=$(classify_num "${DISK_PCT:-n/d}" 80 90)
add_result "Disco (spazio su /)" "$STATUS_DISK" "uso ${DISK_PCT:-n/d}%"

if have iostat; then
    log ""
    log "-- iostat -x (3 campioni, 1s) --"
    IOSTAT_FILE="$OUTDIR/iostat.txt"
    iostat -x 1 3 > "$IOSTAT_FILE"
    cat "$IOSTAT_FILE" | tee -a "$SUMMARY"
    IOSTAT_MAX_UTIL=$(awk '
        /^Device/ {indevice=1; next}
        indevice && NF>0 {u=$NF; gsub(",",".",u); if (u+0>max+0) max=u}
        /^$/ {indevice=0}
        END {if (max=="") print "n/d"; else printf "%.1f", max}
    ' "$IOSTAT_FILE")
    STATUS_IO=$(classify_num "$IOSTAT_MAX_UTIL" 70 90)
    add_result "Disco (I/O %util)" "$STATUS_IO" "%util massimo ${IOSTAT_MAX_UTIL}"
else
    log "iostat non installato (sysstat). Su Debian/Ubuntu: apt install sysstat"
    add_result "Disco (I/O %util)" "WARNING" "iostat non installato"
fi

# ─── 7. MariaDB ───────────────────────────────────────────────────────────

section "7. MariaDB (query attive, slow query, connessioni)"
DB_FILE="$OUTDIR/mariadb.txt"
if docker compose exec -T mariadb mariadb -ufipav -pfipav camp2013 \
    -e "SHOW FULL PROCESSLIST; SHOW GLOBAL STATUS LIKE 'Slow_queries'; SHOW GLOBAL STATUS LIKE 'Threads_connected'; SHOW GLOBAL STATUS LIKE 'Threads_running';" \
    > "$DB_FILE" 2>&1; then
    cat "$DB_FILE" | tee -a "$SUMMARY"
    THREADS_RUNNING=$(awk -F'\t' '/^Threads_running/{print $2}' "$DB_FILE" | tail -1)
    add_result "MariaDB (query attive)" "$(classify_num "${THREADS_RUNNING:-n/d}" 5 20)" "Threads_running=${THREADS_RUNNING:-n/d}"
else
    log "impossibile interrogare mariadb (vedi $DB_FILE)"
    cat "$DB_FILE" >> "$SUMMARY"
    add_result "MariaDB (query attive)" "KO" "connessione al DB fallita"
fi

# ─── 8. Redis ─────────────────────────────────────────────────────────────

section "8. Redis (latenza PING)"
if docker compose exec -T redis redis-cli --no-raw PING >/dev/null 2>&1; then
    REDIS_LAT_FILE="$OUTDIR/redis_latency.txt"
    docker compose exec -T redis redis-cli --latency -i 1 > "$REDIS_LAT_FILE" 2>/dev/null &
    RPID=$!
    sleep 2
    kill "$RPID" 2>/dev/null
    wait "$RPID" 2>/dev/null
    tail -n 1 "$REDIS_LAT_FILE" | tee -a "$SUMMARY"
    REDIS_AVG=$(grep -oE 'avg: [0-9.]+' "$REDIS_LAT_FILE" | tail -1 | awk '{print $2}')
    add_result "Redis (latenza PING)" "$(classify_num "${REDIS_AVG:-n/d}" 1 10)" "avg ${REDIS_AVG:-n/d} ms"
else
    log "redis non raggiungibile"
    add_result "Redis (latenza PING)" "KO" "non raggiungibile"
fi

# ─── Riepilogo ────────────────────────────────────────────────────────────

section "RIEPILOGO"
{
    printf "%-34s %-8s %s\n" "TEST" "STATO" "DETTAGLIO"
    awk -F'\t' '{printf "%-34s %-8s %s\n", $1, $2, $3}' "$RESULTS_FILE"
} | tee -a "$SUMMARY"

OK_COUNT=$(awk -F'\t' '$2=="OK"' "$RESULTS_FILE" | wc -l | tr -d ' ')
WARNING_COUNT=$(awk -F'\t' '$2=="WARNING"' "$RESULTS_FILE" | wc -l | tr -d ' ')
KO_COUNT=$(awk -F'\t' '$2=="KO"' "$RESULTS_FILE" | wc -l | tr -d ' ')
TOTAL_COUNT=$((OK_COUNT + WARNING_COUNT + KO_COUNT))

OVERALL="OK"
[ "$WARNING_COUNT" -gt 0 ] && OVERALL="WARNING"
[ "$KO_COUNT" -gt 0 ] && OVERALL="KO"

log ""
log "${OK_COUNT} OK, ${WARNING_COUNT} WARNING, ${KO_COUNT} KO su ${TOTAL_COUNT} test. Stato generale: ${OVERALL}"
log ""

verdict() {
    awk -v ext="$EXT_TOTAL_AVG" -v loc="$LOCAL_TOTAL_AVG" 'BEGIN {
        if (ext == "n/d" || loc == "n/d") { print "Dati insufficienti per un verdetto automatico sulla rete."; exit }
        diff = ext - loc
        if (diff > 0.3) {
            printf "La differenza esterno/locale e'"'"' di %.2fs: parte del ritardo e'"'"' fuori dalla macchina (rete/DNS/routing verso il client).\n", diff
        } else {
            print "Il ritardo esterno e locale sono simili: il problema NON e'"'"' la rete tra client e server, guarda le righe KO/WARNING sopra."
        }
    }'
}
verdict | tee -a "$SUMMARY"

log ""
log "Report completo salvato in: $OUTDIR/"
