#!/usr/bin/env bats
# Tests du backup hors site avec de faux docker/restic/ssh/curl/systemctl. Exécutés dans Linux (voir run.sh).

SCRIPT=/repo/homelab/backup/offsite-backup.sh

setup() {
  T=$(mktemp -d); chmod 755 "$T"   # traversable par l'uid 1000
  export LOG=$T/calls.log STAGE_SEEN=$T/stage.txt OFFSITE_STAGE=$T/stage OFFSITE_STATE_DIR=$T/state
  : >"$LOG"
  mkdir -p "$T/bin" "$T/vw" "$T/memos"

  # Bases des apps : uid 1000, en WAL comme en prod
  sqlite3 "$T/vw/db.sqlite3" "PRAGMA journal_mode=WAL; CREATE TABLE users(id); INSERT INTO users VALUES (1),(2);"
  sqlite3 "$T/memos/memos_prod.db" "PRAGMA journal_mode=WAL; CREATE TABLE memo(id); INSERT INTO memo VALUES (1),(2),(3);"
  chown -R 1000:1000 "$T/vw" "$T/memos"
  export OFFSITE_SQLITE_DBS="$T/vw/db.sqlite3 $T/memos/memos_prod.db"

  cat >"$T/bin/docker" <<'R'
#!/usr/bin/env bash
echo "docker $*" >>"$LOG"
[ -z "${FAKE_PG_FAIL:-}" ] || exit 1
[ -n "${FAKE_PG_EMPTY:-}" ] || echo "-- PostgreSQL database cluster dump"
R
  cat >"$T/bin/restic" <<'R'
#!/usr/bin/env bash
echo "restic $*" >>"$LOG"
if [ "$1" = backup ]; then
  echo "repo=$RESTIC_REPOSITORY user=$RESTIC_REST_USERNAME pass=$RESTIC_REST_PASSWORD" >"$STAGE_SEEN"
  find "$OFFSITE_STAGE" -type f | sed "s|^$OFFSITE_STAGE||" >>"$STAGE_SEEN"
  [ -z "${FAKE_RESTIC_FAIL:-}" ] || exit 1
fi
R
  # curl : ping healthchecks (dernier argument) ou sonde du rest-server.
  cat >"$T/bin/curl" <<'R'
#!/usr/bin/env bash
url=${*: -1}
echo "curl $url" >>"$LOG"
case "$url" in http://100.*) [ -z "${FAKE_OFFLINE:-}" ] ;; esac
R
  cat >"$T/bin/ssh" <<'R'
#!/usr/bin/env bash
echo "ssh ${*: -1}" >>"$LOG"
[ -z "${FAKE_SSH_FAIL:-}" ] || exit 255
R
  cat >"$T/bin/systemctl" <<'R'
#!/usr/bin/env bash
echo "systemctl $*" >>"$LOG"
R
  chmod +x "$T/bin/"*
  export PATH="$T/bin:$PATH"

  cat >"$T/env" <<E
OFFSITE_HOST=100.64.0.9
OFFSITE_REST_PASSWORD=s3cret
RESTIC_PASSWORD_FILE=$T/pw
OFFSITE_HC_PING_URL=https://hc.example/offsite
E
  export ENV_FILE=$T/env
}

teardown() { rm -rf "$T"; }

# --- probe --------------------------------------------------------------------

@test "probe, PC éteint : rien, succès silencieux" {
  FAKE_OFFLINE=1 run bash "$SCRIPT" --probe
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  ! grep -q '^systemctl' "$LOG"
}

@test "probe, PC en ligne, jamais sauvegardé : démarre le backup" {
  run bash "$SCRIPT" --probe
  [ "$status" -eq 0 ]
  grep -qx 'systemctl start --no-block offsite-backup.service' "$LOG"
}

@test "probe : succès il y a 1 h, rien ; il y a 2 jours, backup" {
  mkdir -p "$T/state"; touch -d '-1 hour' "$T/state/last-success"
  run bash "$SCRIPT" --probe
  ! grep -q '^systemctl' "$LOG"
  touch -d '-2 days' "$T/state/last-success"
  run bash "$SCRIPT" --probe
  grep -q '^systemctl start' "$LOG"
}

@test "probe : échec il y a 30 min, rien ; il y a 2 h, nouvel essai" {
  mkdir -p "$T/state"; touch -d '-30 min' "$T/state/last-attempt"
  run bash "$SCRIPT" --probe
  ! grep -q '^systemctl' "$LOG"
  touch -d '-2 hours' "$T/state/last-attempt"
  run bash "$SCRIPT" --probe
  grep -q '^systemctl start' "$LOG"
}

# --- backup -------------------------------------------------------------------

@test "nominal : dump, backup, check, ping, puis extinction du PC" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  run cat "$LOG"
  [[ "${lines[0]}" == "curl https://hc.example/offsite/start" ]]
  [[ "${lines[1]}" == "docker exec immich_postgres pg_dumpall --clean --if-exists -U postgres" ]]
  [[ "${lines[2]}" == "restic backup --host homelab --tag offsite "* ]]
  [[ "${lines[3]}" == "restic check --read-data-subset 1G" ]]
  [[ "${lines[4]}" == "curl https://hc.example/offsite" ]]
  [[ "${lines[5]}" == "ssh hlpower@100.64.0.9" ]]
  [ "${#lines[@]}" -eq 6 ]
  [ -e "$T/state/last-success" ]
  ! grep -q forget "$LOG"
}

@test "identifiants du rest-server hors de l'URL du dépôt" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'repo=rest:http://100.64.0.9:8000/homelab/ user=homelab pass=s3cret' "$STAGE_SEEN"
}

@test "le stage contient le dump Postgres et les copies SQLite sous leur chemin" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx /immich-db.sql "$STAGE_SEEN"
  grep -qx "/sqlite$T/vw/db.sqlite3" "$STAGE_SEEN"
  grep -qx "/sqlite$T/memos/memos_prod.db" "$STAGE_SEEN"
  [ ! -e "$T/stage" ]
}

@test "les bases vivantes et le dossier Postgres sont exclus, les copies non" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q -- "--exclude $T/vw/db.sqlite3 --exclude $T/vw/db.sqlite3-wal" "$LOG"
  grep -q -- "--exclude /opt/homelab/immich/postgres " "$LOG"
  grep -q -- "--exclude /mnt/data/immich/library/thumbs " "$LOG"
  grep -q " $T/stage" "$LOG"
}

@test "aucun fichier root dans les dossiers de données (-wal/-shm)" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$(find "$T/vw" "$T/memos" ! -uid 1000)" ]
}

@test "OFFSITE_LIMIT_UPLOAD : passé à restic" {
  echo OFFSITE_LIMIT_UPLOAD=5000 >>"$ENV_FILE"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q -- '--limit-upload 5000 ' "$LOG"
}

@test "restic backup en échec : /fail, PC laissé allumé, essai noté, stage supprimé" {
  FAKE_RESTIC_FAIL=1 run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  grep -q 'offsite/fail' "$LOG"
  ! grep -q '^ssh' "$LOG"
  [ -e "$T/state/last-attempt" ]
  [ ! -e "$T/state/last-success" ]
  [ ! -e "$T/stage" ]
}

@test "dump Postgres en échec ou vide : pas de backup" {
  FAKE_PG_FAIL=1 run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  ! grep -q '^restic' "$LOG"
  : >"$LOG"
  FAKE_PG_EMPTY=1 run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  ! grep -q '^restic' "$LOG"
}

@test "base SQLite absente : échec, pas de backup, aucune base créée" {
  rm "$T/memos/memos_prod.db"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  ! grep -q '^restic' "$LOG"
  [ ! -e "$T/memos/memos_prod.db" ]
}

@test "OFFSITE_POWEROFF=no : PC laissé allumé" {
  echo OFFSITE_POWEROFF=no >>"$ENV_FILE"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  ! grep -q '^ssh' "$LOG"
}

@test "extinction impossible : avertissement, backup quand même réussi" {
  FAKE_SSH_FAIL=1 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Extinction du PC impossible"* ]]
  [ -e "$T/state/last-success" ]
}

@test "argument inconnu : erreur d'usage" {
  run bash "$SCRIPT" --foo
  [ "$status" -eq 2 ]
  ! grep -q '^docker\|^restic' "$LOG"
}

@test "variable obligatoire manquante : échec" {
  sed -i '/OFFSITE_REST_PASSWORD/d' "$ENV_FILE"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  ! grep -q '^docker' "$LOG"
}
