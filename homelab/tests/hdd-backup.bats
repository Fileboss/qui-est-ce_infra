#!/usr/bin/env bats
# Tests du backup sur disque USB avec de faux docker/restic/mount/curl. Exécutés dans Linux (voir run.sh).

SCRIPT=/repo/homelab/backup/hdd-backup.sh

setup() {
  T=$(mktemp -d)
  export LOG=$T/calls.log MOUNTED=$T/mounted UUID=1111-2222
  : >"$LOG"; : >"$MOUNTED"
  mkdir -p "$T/bin" "$T/mnt/homelab-restic"
  touch "$T/dev" "$T/mnt/homelab-restic/config"
  export FAKE_RUNNING="c1 c2"

  # Faux montages : la liste des points montés est dans $MOUNTED.
  cat >"$T/bin/mountpoint" <<'R'
#!/usr/bin/env bash
grep -qxF "${*: -1}" "$MOUNTED"
R
  cat >"$T/bin/mount" <<'R'
#!/usr/bin/env bash
echo "mount $*" >>"$LOG"; echo "${*: -1}" >>"$MOUNTED"
R
  cat >"$T/bin/umount" <<'R'
#!/usr/bin/env bash
echo "umount $*" >>"$LOG"; sed -i "\|^$1\$|d" "$MOUNTED"
R
  cat >"$T/bin/findmnt" <<'R'
#!/usr/bin/env bash
echo "${FAKE_UUID:-$UUID}"
R
  cat >"$T/bin/docker" <<'R'
#!/usr/bin/env bash
if [ "$1" = ps ]; then
  [ -z "${FAKE_DOCKER_FAIL:-}" ] || exit 1
  for c in $FAKE_RUNNING; do echo "$c"; done
  exit 0
fi
echo "docker $*" >>"$LOG"
R
  cat >"$T/bin/restic" <<'R'
#!/usr/bin/env bash
echo "restic $*" >>"$LOG"
case "$1" in
  init) touch "$RESTIC_REPOSITORY/config" ;;
  backup) [ -z "${FAKE_RESTIC_FAIL:-}" ] || exit 1 ;;
  check) [ -z "${FAKE_CHECK_FAIL:-}" ] || exit 1 ;;
esac
R
  cat >"$T/bin/curl" <<'R'
#!/usr/bin/env bash
echo "curl ${*: -1}" >>"$LOG"
R
  chmod +x "$T/bin/"*
  export PATH="$T/bin:$PATH"

  cat >"$T/env" <<E
HDD_UUID=$UUID
HDD_MOUNT=$T/mnt
HDD_DEV=$T/dev
RESTIC_PASSWORD_FILE=$T/pw
HDD_HC_PING_URL=https://hc.example/hdd
E
  export ENV_FILE=$T/env
}

teardown() { rm -rf "$T"; }

@test "nominal : arrêt, backup, redémarrage avant forget/check, démontage, ping" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  run cat "$LOG"
  [[ "${lines[0]}" == "curl https://hc.example/hdd/start" ]]
  [[ "${lines[1]}" == "mount $T/dev $T/mnt" ]]
  [[ "${lines[2]}" == "docker stop -t 60 c1 c2" ]]
  [[ "${lines[3]}" == "restic backup --one-file-system "*" /" ]]
  [[ "${lines[4]}" == "docker start c1 c2" ]]
  [[ "${lines[5]}" == restic\ forget\ --tag\ hdd-full*--prune ]]
  [[ "${lines[6]}" == "restic check --read-data-subset 5%" ]]
  [[ "${lines[7]}" == "umount $T/mnt" ]]
  [[ "${lines[8]}" == "curl https://hc.example/hdd" ]]
  [ "${#lines[@]}" -eq 9 ]
}

@test "le backup exclut Docker et le disque USB lui-même" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q -- "--exclude /var/lib/docker " "$LOG"
  grep -q -- "--exclude $T/mnt " "$LOG"
}

@test "/mnt/data et /boot/efi montés à part : sauvegardés aussi" {
  printf '/mnt/data\n/boot/efi\n' >"$MOUNTED"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q '^restic backup .* / /boot/efi /mnt/data$' "$LOG"
}

@test "restic backup en échec : conteneurs redémarrés, démonté, /fail, pas de forget" {
  FAKE_RESTIC_FAIL=1 run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  grep -qx 'docker start c1 c2' "$LOG"
  grep -qx "umount $T/mnt" "$LOG"
  grep -q 'hdd/fail' "$LOG"
  ! grep -q '^restic forget' "$LOG"
}

@test "restic check en échec : échec et /fail" {
  FAKE_CHECK_FAIL=1 run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  grep -q 'hdd/fail' "$LOG"
  [ "$(grep -c '^docker start' "$LOG")" -eq 1 ]
}

@test "disque absent : échec avant d'arrêter quoi que ce soit" {
  rm "$T/dev"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"branché"* ]]
  ! grep -q '^docker\|^restic\|^mount' "$LOG"
  grep -q 'hdd/fail' "$LOG"
}

@test "mauvais disque monté : échec, rien n'est arrêté ni sauvegardé" {
  FAKE_UUID=9999 run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  ! grep -q '^docker\|^restic' "$LOG"
  grep -qx "umount $T/mnt" "$LOG"
}

@test "pas de dépôt sur le disque : échec qui indique --init" {
  rm "$T/mnt/homelab-restic/config"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--init"* ]]
  ! grep -q '^docker\|^restic' "$LOG"
}

@test "docker ne répond pas : échec, pas de backup à chaud" {
  FAKE_DOCKER_FAIL=1 run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  ! grep -q '^restic' "$LOG"
}

@test "aucun conteneur actif : ni stop ni start" {
  FAKE_RUNNING="" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  ! grep -q '^docker' "$LOG"
}

@test "HDD_FSTYPE défini : passé à mount" {
  echo HDD_FSTYPE=ntfs-3g >>"$ENV_FILE"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx "mount -t ntfs-3g $T/dev $T/mnt" "$LOG"
}

@test "disque déjà monté : laissé monté à la fin" {
  echo "$T/mnt" >"$MOUNTED"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  ! grep -q '^mount\|^umount' "$LOG"
}

@test "--init : crée le dépôt, ne touche pas aux conteneurs, démonte, pas de ping" {
  rm "$T/mnt/homelab-restic/config"
  run bash "$SCRIPT" --init
  [ "$status" -eq 0 ]
  run cat "$LOG"
  [[ "${lines[0]}" == "mount $T/dev $T/mnt" ]]
  [[ "${lines[1]}" == "restic init" ]]
  [[ "${lines[2]}" == "umount $T/mnt" ]]
  [ "${#lines[@]}" -eq 3 ]
}

@test "--init sur un dépôt existant : refusé" {
  run bash "$SCRIPT" --init
  [ "$status" -ne 0 ]
  ! grep -q '^restic' "$LOG"
}

@test "argument inconnu : erreur d'usage" {
  run bash "$SCRIPT" --foo
  [ "$status" -eq 2 ]
  ! grep -q '^mount' "$LOG"
}

@test "variable obligatoire manquante : échec" {
  sed -i '/HDD_UUID/d' "$ENV_FILE"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  ! grep -q '^mount' "$LOG"
}
