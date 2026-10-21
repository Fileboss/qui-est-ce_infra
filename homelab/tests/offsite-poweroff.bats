#!/usr/bin/env bats
# Tests de la commande d'extinction du PC hors site avec de faux loginctl/sudo.

SCRIPT=/repo/homelab/offsite/offsite-poweroff

setup() {
  T=$(mktemp -d)
  export LOG=$T/calls.log ME
  ME=$(id -un)
  : >"$LOG"
  mkdir -p "$T/bin"
  # Sessions au format id:utilisateur:classe dans FAKE_SESSIONS.
  cat >"$T/bin/loginctl" <<'R'
#!/usr/bin/env bash
if [ "$1" = list-sessions ]; then
  for s in $FAKE_SESSIONS; do echo "${s%%:*} 1000 x - -"; done
  exit 0
fi
id=$2 prop=$4
for s in $FAKE_SESSIONS; do
  [ "${s%%:*}" = "$id" ] || continue
  IFS=: read -r _ user class <<<"$s"
  if [ "$prop" = Name ]; then echo "$user"; else echo "$class"; fi
done
R
  cat >"$T/bin/sudo" <<'R'
#!/usr/bin/env bash
echo "sudo $*" >>"$LOG"
R
  chmod +x "$T/bin/"*
  export PATH="$T/bin:$PATH"
}

teardown() { rm -rf "$T"; }

@test "seule la session SSH du HP : extinction" {
  FAKE_SESSIONS="3:$ME:user 4:$ME:manager" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'sudo -n /usr/bin/systemctl poweroff' "$LOG"
}

@test "écran de connexion graphique seul : extinction" {
  FAKE_SESSIONS="c1:lightdm:greeter 3:$ME:user" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q poweroff "$LOG"
}

@test "quelqu'un connecté (bureau ou SSH) : pas d'extinction" {
  FAKE_SESSIONS="2:pgu:user 3:$ME:user" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PC utilisé (pgu)"* ]]
  ! grep -q poweroff "$LOG"
}
