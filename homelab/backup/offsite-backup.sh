#!/usr/bin/env bash
# Backup hors site : HP -> PC chez mes parents (rest-server en ajout seul, sur le tailnet), §18.
# Sans couper les services : Postgres d'Immich vidé par pg_dumpall, bases SQLite copiées par
# sqlite3 .backup, le reste (photos, /opt/homelab, config) lu tel quel. À la fin, le HP éteint le PC.
#   offsite-backup.sh          sauvegarde (offsite-backup.service)
#   offsite-backup.sh --probe  démarre offsite-backup.service si le PC est en ligne (offsite-probe.timer)
set -euo pipefail

ENV_FILE=${ENV_FILE:-/etc/offsite-backup.env}
# shellcheck disable=SC1090
source "$ENV_FILE"
: "${OFFSITE_HOST:?}" "${OFFSITE_REST_PASSWORD:?}" "${RESTIC_PASSWORD_FILE:?}"

OFFSITE_PORT=${OFFSITE_PORT:-8000}
OFFSITE_USER=${OFFSITE_USER:-homelab}
# Identifiants du rest-server dans des variables à part : ils n'apparaissent pas dans l'URL du dépôt.
RESTIC_REPOSITORY="rest:http://$OFFSITE_HOST:$OFFSITE_PORT/$OFFSITE_USER/"
RESTIC_REST_USERNAME=$OFFSITE_USER
RESTIC_REST_PASSWORD=$OFFSITE_REST_PASSWORD
export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE RESTIC_REST_USERNAME RESTIC_REST_PASSWORD

STATE_DIR=${OFFSITE_STATE_DIR:-/var/lib/offsite-backup}
STAGE=${OFFSITE_STAGE:-/var/backups/offsite-stage}
SQLITE_DBS=${OFFSITE_SQLITE_DBS:-/opt/homelab/vaultwarden/data/db.sqlite3 /opt/homelab/memos/data/memos_prod.db /opt/homelab/simple-finance/data/finance.sqlite}
IMMICH_DB_CONTAINER=${IMMICH_DB_CONTAINER:-immich_postgres}
IMMICH_DB_USER=${IMMICH_DB_USER:-postgres}
IMMICH_PG_DIR=${IMMICH_PG_DIR:-/opt/homelab/immich/postgres}
IMMICH_LIBRARY=${IMMICH_LIBRARY:-/mnt/data/immich/library}

die() { echo "$*" >&2; exit 1; }

# Vrai si le fichier $1 a été modifié il y a moins de $2 secondes.
recent() { [ -e "$1" ] && [ $(( $(date +%s) - $(stat -c %Y "$1") )) -lt "$2" ]; }

# --- Mode probe (toutes les 5 min) : silencieux tant que le PC est éteint -----
if [ "${1:-}" = --probe ]; then
  # Toute réponse HTTP (même 401) prouve que le rest-server écoute.
  curl -s -m 5 -o /dev/null "http://$OFFSITE_HOST:$OFFSITE_PORT/" || exit 0
  # Une fois par visite : rien si un backup a réussi il y a moins de 12 h. Après un échec,
  # nouvel essai au bout d'une heure (le PC reste allumé, voir plus bas).
  recent "$STATE_DIR/last-success" $((12 * 3600)) && exit 0
  recent "$STATE_DIR/last-attempt" 3600 && exit 0
  exec systemctl start --no-block offsite-backup.service
fi
[ -z "${1:-}" ] || { echo "Usage : $0 [--probe]" >&2; exit 2; }

hc_ping() {
  [ -n "${OFFSITE_HC_PING_URL:-}" ] || return 0
  curl -fsS -m 10 --retry 3 -o /dev/null "${OFFSITE_HC_PING_URL}${1:-}" || true
}

cleanup() {
  rc=$?
  rm -rf "$STAGE"
  if [ "$rc" -ne 0 ]; then hc_ping /fail; fi
  exit "$rc"
}
trap cleanup EXIT

hc_ping /start
install -d -m 700 "$STATE_DIR"
touch "$STATE_DIR/last-attempt"
rm -rf "$STAGE"
# 711 : traversable par l'uid des apps (copies SQLite), mais pas listable.
install -d -m 711 "$STAGE"

# --- Copies cohérentes des bases, à chaud ---------------------------------------
docker exec "$IMMICH_DB_CONTAINER" pg_dumpall --clean --if-exists -U "$IMMICH_DB_USER" >"$STAGE/immich-db.sql"
[ -s "$STAGE/immich-db.sql" ] || die "Dump Postgres d'Immich vide"

EXCLUDES=()
for db in $SQLITE_DBS; do
  [ -s "$db" ] || die "Base introuvable ou vide : $db"
  # Comme les backups de chaque nuit : sqlite3 tourne avec l'uid propriétaire de la base,
  # sinon il laisserait des -wal/-shm root que l'app ne pourrait plus ouvrir.
  owner=$(stat -c '%u:%g' "$db")
  tmp=$(mktemp -d "$STAGE/sqlite.XXXXXX")
  chown "$owner" "$tmp"
  setpriv --reuid="${owner%:*}" --regid="${owner#*:}" --clear-groups \
    sqlite3 "$db" ".timeout 30000" ".backup '$tmp/copy'"
  [ "$(setpriv --reuid="${owner%:*}" --regid="${owner#*:}" --clear-groups \
    sqlite3 "$tmp/copy" 'PRAGMA integrity_check;')" = "ok" ] || die "Copie corrompue : $db"
  # Rangée sous son chemin d'origine : stage/sqlite/opt/homelab/…
  install -d -m 700 "$STAGE/sqlite$(dirname "$db")"
  mv "$tmp/copy" "$STAGE/sqlite$db"
  rmdir "$tmp"
  # Le fichier vivant serait copié en cours d'écriture : seule la copie est sauvegardée.
  EXCLUDES+=(--exclude "$db" --exclude "$db-wal" --exclude "$db-shm" --exclude "$db-journal")
done

# --- Sauvegarde -----------------------------------------------------------------
TARGETS=("$STAGE")
for p in /opt/homelab /mnt/data /etc /root /home /usr/local; do
  if [ -e "$p" ]; then TARGETS+=("$p"); fi
done

# Exclus en plus : les fichiers de Postgres en marche (le dump les remplace), les miniatures et
# vidéos réencodées d'Immich (régénérées depuis les originaux), le monitoring (historique sans
# valeur, copié à froid par le backup USB §17) et les caches.
restic backup --host homelab --tag offsite --exclude-caches \
  ${OFFSITE_LIMIT_UPLOAD:+--limit-upload "$OFFSITE_LIMIT_UPLOAD"} \
  --exclude "$IMMICH_PG_DIR" \
  --exclude "$IMMICH_LIBRARY/thumbs" --exclude "$IMMICH_LIBRARY/encoded-video" \
  --exclude /opt/homelab/beszel \
  --exclude '/home/*/.cache' --exclude /root/.cache \
  "${EXCLUDES[@]}" \
  "${TARGETS[@]}"

# Relit un échantillon de taille fixe : 5 % ferait télécharger des Go depuis la box des parents.
restic check --read-data-subset "${OFFSITE_CHECK_SUBSET:-1G}"

# Pas de forget/prune : le rest-server est en ajout seul. Le ménage se fait sur le PC (§18.6).
touch "$STATE_DIR/last-success"
hc_ping

# --- Extinction du PC -----------------------------------------------------------
# Seulement après un succès : après un échec, le PC reste allumé et le probe réessaie dans 1 h.
if [ "${OFFSITE_POWEROFF:-yes}" = yes ]; then
  ssh -i "${OFFSITE_SSH_KEY:-/root/.ssh/offsite_power}" -o BatchMode=yes -o ConnectTimeout=10 \
    "hlpower@$OFFSITE_HOST" \
    || echo "Extinction du PC impossible : éteins-le à la main (backup réussi quand même)." >&2
fi
echo "Backup hors site terminé."
