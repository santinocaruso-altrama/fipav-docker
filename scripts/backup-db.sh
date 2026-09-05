#!/usr/bin/env bash
# Backup schedulabile di tutti i database (stesso elenco di `make db-backups`),
# compresso e con rotazione automatica. Pensato per staging: una macchina
# pubblica con dati reali (camp2013) merita un backup che gira da solo, non
# solo `make db-backups` lanciato a mano quando qualcuno se ne ricorda.
#
# Uso: scripts/backup-db.sh   (o `make backup-db`)
#
# Crontab sulla macchina di staging (fuori dallo scope di questo repo: va
# aggiunta a mano una volta, `crontab -e`):
#   0 3 * * * cd /percorso/fipav-docker && ./scripts/backup-db.sh >> backups/backup.log 2>&1
#
# Retention: BACKUP_RETENTION_DAYS (default 14) - i .sql.gz piu' vecchi
# vengono cancellati DOPO che il backups nuovo e' andato a buon fine, mai prima.
#
# Per ripristinare un backup: gunzip e poi `make db-restore file=...sql`
# (la rimozione delle CONSTRAINT che fa quel target serve anche qui).
set -euo pipefail
cd "$(dirname "$0")/.."

BACKUP_DIR="backups"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
DATABASES="camp2013 camp2003 corsi2016 live refertoelettronico vnl_ticketing"

if [ -z "$(docker compose ps -q mariadb 2>/dev/null)" ]; then
    echo "[backup-db] mariadb non e' in esecuzione: niente da fare."
    exit 1
fi

env_value() {
    grep -E "^${1}=" .env.stage 2>/dev/null | tail -n1 | cut -d'=' -f2-
}
ROOT_PASSWORD="$(env_value MARIADB_ROOT_PASSWORD)"
ROOT_PASSWORD="${ROOT_PASSWORD:-root}"

mkdir -p "$BACKUP_DIR"
OUT="$BACKUP_DIR/$(date +%Y%m%d_%H%M%S).sql.gz"
TMP="$OUT.tmp"

echo "[backup-db] Dump di: $DATABASES"
# shellcheck disable=SC2086
docker compose exec -T mariadb mariadb-backups -uroot -p"$ROOT_PASSWORD" --databases $DATABASES \
    | gzip > "$TMP"
mv "$TMP" "$OUT"
echo "[backup-db] Salvato $OUT ($(du -h "$OUT" | cut -f1))"

DELETED=0
while IFS= read -r -d '' old; do
    rm -f "$old"
    DELETED=$((DELETED + 1))
done < <(find "$BACKUP_DIR" -name '*.sql.gz' -mtime "+${RETENTION_DAYS}" -print0)

if [ "$DELETED" -gt 0 ]; then
    echo "[backup-db] Rimossi $DELETED backup piu' vecchi di ${RETENTION_DAYS} giorni."
fi
