#!/usr/bin/env bats
# Tests du backup Memos avec de faux restic/curl. Exécutés dans Linux (voir run.sh).

SCRIPT=/repo/homelab/backup/memos-backup.sh

setup() {
  T=$(mktemp -d); chmod 755 "$T"   # traversable par l'uid 1000
  export LOG=$T/calls.log STAGE_SEEN=$T/stage.txt MEMOS_STAGE=$T/stage
  : >"$LOG"
  mkdir -p "$T/bin" "$T/data/assets"

  # Données de l'app : appartiennent à l'uid 1000, base en WAL comme en prod
  sqlite3 "$T/data/memos_prod.db" "PRAGMA journal_mode=WAL; CREATE TABLE memo(id); INSERT INTO memo VALUES (1),(2),(3);"
  echo img >"$T/data/assets/1_photo.jpg"
  chown -R 1000:1000 "$T/data"

  cat >"$T/bin/restic" <<'R'
#!/usr/bin/env bash
echo "restic $*" >>"$LOG"
if [ "$1" = backup ]; then
  { ls -A "$MEMOS_STAGE"; ls "$MEMOS_STAGE/assets" 2>/dev/null; stat -c 'owner=%u' "$MEMOS_STAGE"
    sqlite3 "$MEMOS_STAGE/memos_prod.db" 'SELECT count(*) FROM memo;'; } >"$STAGE_SEEN"
  [ -z "${FAKE_RESTIC_FAIL:-}" ] || exit 1
fi
R
  cat >"$T/bin/curl" <<'R'
#!/usr/bin/env bash
echo "curl ${*: -1}" >>"$LOG"
R
  chmod +x "$T/bin/"*
  export PATH="$T/bin:$PATH"

  cat >"$T/env" <<E
RESTIC_REPOSITORY=sftp:test:/repo
RESTIC_PASSWORD_FILE=$T/pw
MEMOS_HC_PING_URL=https://hc.example/memos
E
  export ENV_FILE=$T/env MEMOS_DATA_DIR=$T/data
}

teardown() { rm -rf "$T"; }

@test "nominal : backup, forget, ping de succès" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  run cat "$LOG"
  [[ "${lines[0]}" == "curl https://hc.example/memos/start" ]]
  [[ "${lines[1]}" == "restic backup --retry-lock 30m --host memos --tag memos $T/stage" ]]
  [[ "${lines[2]}" == restic\ forget*--prune ]]
  [[ "${lines[3]}" == "curl https://hc.example/memos" ]]
  [ "${#lines[@]}" -eq 4 ]
}

@test "le dossier de travail contient la base, les pièces jointes ; appartient à l'uid de l'app" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx memos_prod.db "$STAGE_SEEN"
  grep -qx 1_photo.jpg "$STAGE_SEEN"
  grep -qx 'owner=1000' "$STAGE_SEEN"
  grep -qx 3 "$STAGE_SEEN"
}

@test "sans dossier assets (aucune pièce jointe) : succès" {
  rm -rf "$T/data/assets"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  ! grep -qx assets "$STAGE_SEEN"
  grep -q '^curl https://hc.example/memos$' "$LOG"
}

@test "le dossier de travail est supprimé après succès comme après échec" {
  run bash "$SCRIPT"
  [ ! -e "$T/stage" ]
  FAKE_RESTIC_FAIL=1 run bash "$SCRIPT"
  [ ! -e "$T/stage" ]
}

@test "aucun fichier root dans le dossier de données (-wal/-shm)" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$(find "$T/data" ! -uid 1000)" ]
}

@test "base absente : échec, /fail, pas de restic, aucune base créée" {
  rm "$T/data/memos_prod.db"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  grep -q 'memos/fail' "$LOG"
  ! grep -q '^restic' "$LOG"
  [ ! -e "$T/data/memos_prod.db" ]
}

@test "restic backup en échec : échec, /fail, pas de forget" {
  FAKE_RESTIC_FAIL=1 run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  grep -q 'memos/fail' "$LOG"
  ! grep -q '^restic forget' "$LOG"
}

@test "sans MEMOS_HC_PING_URL : aucun appel curl" {
  sed -i '/MEMOS_HC_PING_URL/d' "$ENV_FILE"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  ! grep -q '^curl' "$LOG"
}

@test "variable obligatoire manquante : échec" {
  sed -i '/RESTIC_PASSWORD_FILE/d' "$ENV_FILE"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
}
