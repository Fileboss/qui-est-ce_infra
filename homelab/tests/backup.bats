#!/usr/bin/env bats
# Tests du script de backup avec de faux restic/curl/date. Exécutés dans Linux (voir run.sh).

SCRIPT=/repo/homelab/backup/vaultwarden-backup.sh

setup() {
  T=$(mktemp -d); chmod 755 "$T"   # traversable par l'uid 1000
  export LOG=$T/calls.log STAGE_SEEN=$T/stage.txt
  : >"$LOG"
  mkdir -p "$T/bin" "$T/data"

  # Vaultwarden : fichiers appartenant à l'uid 1000
  sqlite3 "$T/data/db.sqlite3" "PRAGMA journal_mode=WAL; CREATE TABLE users(id); INSERT INTO users VALUES (1),(2);"
  echo key >"$T/data/rsa_key.pem"; echo '{}' >"$T/data/config.json"
  mkdir "$T/data/attachments"; echo a >"$T/data/attachments/f"
  chown -R 1000:1000 "$T/data"

  cat >"$T/bin/restic" <<'R'
#!/usr/bin/env bash
echo "restic $*" >>"$LOG"
if [ "$1" = backup ]; then
  { ls -A /var/backups/vaultwarden-stage; stat -c 'owner=%u' /var/backups/vaultwarden-stage; } >"$STAGE_SEEN"
  [ -z "${FAKE_RESTIC_FAIL:-}" ] || exit 1
fi
R
  cat >"$T/bin/curl" <<'R'
#!/usr/bin/env bash
echo "curl ${*: -1}" >>"$LOG"
R
  cat >"$T/bin/date" <<'R'
#!/usr/bin/env bash
[ "$1" = "+%u" ] && echo "${FAKE_DOW:-3}" || /bin/date "$@"
R
  chmod +x "$T/bin/"*
  export PATH="$T/bin:$PATH"

  cat >"$T/env" <<E
VW_DATA_DIR=$T/data
RESTIC_REPOSITORY=sftp:test:/repo
RESTIC_PASSWORD_FILE=$T/pw
HC_PING_URL=https://hc.example/ping
E
  export ENV_FILE=$T/env
}

teardown() { rm -rf "$T" /var/backups/vaultwarden-stage; }

@test "nominal : backup puis forget puis ping de succès, sans check hors dimanche" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  run cat "$LOG"
  [[ "${lines[0]}" == "curl https://hc.example/ping/start" ]]
  [[ "${lines[1]}" == restic\ backup* ]]
  [[ "${lines[2]}" == restic\ forget* ]]
  [[ "${lines[3]}" == "curl https://hc.example/ping" ]]
  [ "${#lines[@]}" -eq 4 ]
}

@test "le dossier de travail contient base, clés, config et pièces jointes ; appartient à l'uid de Vaultwarden" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  for f in db.sqlite3 rsa_key.pem config.json attachments; do grep -qx "$f" "$STAGE_SEEN"; done
  ! grep -qx sends "$STAGE_SEEN"
  grep -qx 'owner=1000' "$STAGE_SEEN"
}

@test "sans config.json (panneau /admin jamais utilisé), le backup réussit quand même" {
  rm "$T/data/config.json"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx db.sqlite3 "$STAGE_SEEN"
  ! grep -qx config.json "$STAGE_SEEN"
}

@test "le dossier de travail est supprimé après succès" {
  run bash "$SCRIPT"
  [ ! -e /var/backups/vaultwarden-stage ]
}

@test "dimanche : restic check est lancé" {
  FAKE_DOW=7 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q '^restic check' "$LOG"
}

@test "base corrompue : échec, /fail, pas de restic, nettoyage" {
  head -c 2000 /dev/urandom >"$T/data/db.sqlite3"
  chown 1000:1000 "$T/data/db.sqlite3"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  grep -q 'ping/fail' "$LOG"
  ! grep -q '^restic' "$LOG"
  [ ! -e /var/backups/vaultwarden-stage ]
}

@test "base absente : échec et /fail" {
  rm "$T/data/db.sqlite3"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  grep -q 'ping/fail' "$LOG"
  ! grep -q '^restic' "$LOG"
}

@test "restic backup en échec : échec, /fail, pas de forget, nettoyage" {
  FAKE_RESTIC_FAIL=1 run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  grep -q 'ping/fail' "$LOG"
  ! grep -q '^restic forget' "$LOG"
  [ ! -e /var/backups/vaultwarden-stage ]
}

@test "sans HC_PING_URL : aucun appel curl" {
  sed -i '/HC_PING_URL/d' "$ENV_FILE"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  ! grep -q '^curl' "$LOG"
}

@test "variable obligatoire manquante : échec" {
  sed -i '/RESTIC_REPOSITORY/d' "$ENV_FILE"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
}
