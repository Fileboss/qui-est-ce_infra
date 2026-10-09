#!/usr/bin/env bash
# Sauvegarde quotidienne du vault Vaultwarden vers le VPS.
# 1. snapshot cohérent de la base SQLite (sqlite3 .backup, safe à chaud)
# 2. chiffrement + déduplication côté HP par restic
# 3. dépôt du dépôt restic (déjà chiffré) sur le VPS via SFTP sur le tailnet
# Le VPS ne voit jamais que des blocs chiffrés ; la clé reste sur le HP (+ copie hors-ligne).
set -euo pipefail

ENV_FILE=${ENV_FILE:-/etc/vaultwarden-backup.env}
# shellcheck disable=SC1090
source "$ENV_FILE"
: "${VW_DATA_DIR:?}" "${RESTIC_REPOSITORY:?}" "${RESTIC_PASSWORD_FILE:?}"
export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE

STAGE=/var/backups/vaultwarden-stage

# Ping optionnel (healthchecks.io ou instance self-hosted) pour être alerté
# si la sauvegarde échoue OU ne tourne plus.
hc_ping() {
  [ -n "${HC_PING_URL:-}" ] || return 0
  curl -fsS -m 10 --retry 3 -o /dev/null "${HC_PING_URL}${1:-}" || true
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
install -d -m 700 "$STAGE"

sqlite3 "$VW_DATA_DIR/db.sqlite3" ".timeout 30000" ".backup '$STAGE/db.sqlite3'"
[ "$(sqlite3 "$STAGE/db.sqlite3" 'PRAGMA integrity_check;')" = "ok" ]

# Clés RSA (sinon toutes les sessions sont invalidées à la restauration),
# config, pièces jointes et Sends.
shopt -s nullglob
for f in "$VW_DATA_DIR"/rsa_key* "$VW_DATA_DIR"/config.json; do
  cp -a "$f" "$STAGE/"
done
for d in attachments sends; do
  [ -d "$VW_DATA_DIR/$d" ] && cp -a "$VW_DATA_DIR/$d" "$STAGE/"
done

restic backup --host vaultwarden --tag vaultwarden --one-file-system "$STAGE"

restic forget --host vaultwarden --tag vaultwarden \
  --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --prune

# Vérification d'intégrité du dépôt distant (5 % des données relues) chaque dimanche.
if [ "$(date +%u)" = 7 ]; then
  restic check --read-data-subset=5%
fi

hc_ping
