#!/usr/bin/env bats
# Tests du backup simple-finance avec de faux restic/curl. Exécutés dans Linux (voir run.sh).

SCRIPT=/repo/homelab/backup/finance-backup.sh

setup() {
  T=$(mktemp -d); chmod 755 "$T"   # traversable par l'uid 1000
  export LOG=$T/calls.log STAGE_SEEN=$T/stage.txt FINANCE_STAGE=$T/stage
  : >"$LOG"
  mkdir -p "$T/bin" "$T/data"

  # Base de l'app : appartient à l'uid 1000, en WAL comme en prod
  sqlite3 "$T/data/finance.sqlite" "PRAGMA journal_mode=WAL; CREATE TABLE accounts(id); INSERT INTO accounts VALUES (1),(2);"
  chown -R 1000:1000 "$T/data"

  cat >"$T/bin/restic" <<'R'
#!/usr/bin/env bash
echo "restic $*" >>"$LOG"
if [ "$1" = backup ]; then
  { ls -A "$FINANCE_STAGE"; stat -c 'owner=%u' "$FINANCE_STAGE"; sqlite3 "$FINANCE_STAGE/finance.sqlite" 'SELECT count(*) FROM accounts;'; } >"$STAGE_SEEN"
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
FINANCE_HC_PING_URL=https://hc.example/finance
E
  export ENV_FILE=$T/env FINANCE_DATA_DIR=$T/data
}

teardown() { rm -rf "$T"; }

@test "nominal : backup, forget, ping de succès" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  run cat "$LOG"
  [[ "${lines[0]}" == "curl https://hc.example/finance/start" ]]
  [[ "${lines[1]}" == "restic backup --retry-lock 30m --host simple-finance --tag simple-finance $T/stage" ]]
  [[ "${lines[2]}" == restic\ forget*--prune ]]
  [[ "${lines[3]}" == "curl https://hc.example/finance" ]]
  [ "${#lines[@]}" -eq 4 ]
}

@test "le dossier de travail contient une copie lisible de la base ; appartient à l'uid de l'app" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx finance.sqlite "$STAGE_SEEN"
  grep -qx 'owner=1000' "$STAGE_SEEN"
  grep -qx 2 "$STAGE_SEEN"
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
  rm "$T/data/finance.sqlite"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  grep -q 'finance/fail' "$LOG"
  ! grep -q '^restic' "$LOG"
  [ ! -e "$T/data/finance.sqlite" ]
}

@test "restic backup en échec : échec, /fail, pas de forget" {
  FAKE_RESTIC_FAIL=1 run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  grep -q 'finance/fail' "$LOG"
  ! grep -q '^restic forget' "$LOG"
}

@test "sans FINANCE_HC_PING_URL : aucun appel curl" {
  sed -i '/FINANCE_HC_PING_URL/d' "$ENV_FILE"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  ! grep -q '^curl' "$LOG"
}

@test "variable obligatoire manquante : échec" {
  sed -i '/RESTIC_PASSWORD_FILE/d' "$ENV_FILE"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
}
