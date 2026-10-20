#!/usr/bin/env bash
# Sauvegarde quotidienne de Memos vers le VPS, dans le même dépôt restic que le vault.
# 1. snapshot cohérent de la base SQLite (sqlite3 .backup, safe à chaud) + pièces jointes
# 2. restic chiffre côté HP et envoie sur le VPS (SFTP, tailnet)
set -euo pipefail

ENV_FILE=${ENV_FILE:-/etc/vaultwarden-backup.env}
# shellcheck disable=SC1090
source "$ENV_FILE"
: "${RESTIC_REPOSITORY:?}" "${RESTIC_PASSWORD_FILE:?}"
export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE

MEMOS_DATA_DIR=${MEMOS_DATA_DIR:-/opt/homelab/memos/data}
STAGE=${MEMOS_STAGE:-/var/backups/memos-stage}

hc_ping() {
  [ -n "${MEMOS_HC_PING_URL:-}" ] || return 0
  curl -fsS -m 10 --retry 3 -o /dev/null "${MEMOS_HC_PING_URL}${1:-}" || true
}

cleanup() {
  rc=$?
  rm -rf "$STAGE"
  if [ "$rc" -ne 0 ]; then hc_ping /fail; fi
  exit "$rc"
}
trap cleanup EXIT

hc_ping /start
rm -rf "$STAGE"

# Pas de base = installation cassée ou mauvais chemin : on échoue plutôt que de
# laisser sqlite3 créer une base vide et la sauvegarder.
DB="$MEMOS_DATA_DIR/memos_prod.db"
[ -s "$DB" ] || { echo "Base introuvable ou vide : $DB" >&2; exit 1; }

# sqlite3 tourne avec l'uid propriétaire de la base (celui du conteneur) : comme
# pour le vault, un sqlite3 root créerait des -wal/-shm que l'app ne pourrait plus ouvrir.
OWNER=$(stat -c '%u:%g' "$DB")
as_owner() { setpriv --reuid="${OWNER%:*}" --regid="${OWNER#*:}" --clear-groups "$@"; }
install -d -m 700 -o "${OWNER%:*}" -g "${OWNER#*:}" "$STAGE"

as_owner sqlite3 "$DB" ".timeout 30000" ".backup '$STAGE/memos_prod.db'"
[ "$(as_owner sqlite3 "$STAGE/memos_prod.db" 'PRAGMA integrity_check;')" = "ok" ]

# Pièces jointes (stockage local par défaut : assets/). Absent tant que rien n'a été joint.
[ -d "$MEMOS_DATA_DIR/assets" ] && cp -a "$MEMOS_DATA_DIR/assets" "$STAGE/"

# --retry-lock : les autres backups partagent le dépôt et peuvent le verrouiller.
restic backup --retry-lock 30m --host memos --tag memos "$STAGE"

restic forget --retry-lock 30m --host memos --tag memos \
  --keep-daily 14 --keep-weekly 8 --keep-monthly 24 --prune

hc_ping
