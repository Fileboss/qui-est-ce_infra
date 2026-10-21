#!/usr/bin/env bash
# Vérifications statiques, exécutées DANS le conteneur de test (repo monté en /repo).
set -uo pipefail
cd /repo/homelab
fail=0
check() { local name=$1; shift; if out=$("$@" 2>&1); then echo "  ok   $name"; else echo "  FAIL $name"; echo "$out" | sed 's/^/       /'; fail=1; fi; }

check "bash -n vaultwarden-backup.sh" bash -n backup/vaultwarden-backup.sh
check "shellcheck vaultwarden-backup.sh" shellcheck backup/vaultwarden-backup.sh
check "bash -n finance-backup.sh" bash -n backup/finance-backup.sh
check "shellcheck finance-backup.sh" shellcheck backup/finance-backup.sh
check "bash -n memos-backup.sh" bash -n backup/memos-backup.sh
check "shellcheck memos-backup.sh" shellcheck backup/memos-backup.sh
check "bash -n hdd-backup.sh" bash -n backup/hdd-backup.sh
check "shellcheck hdd-backup.sh" shellcheck backup/hdd-backup.sh
check "bash -n hlbackup" bash -n backup/hlbackup
check "shellcheck hlbackup" shellcheck backup/hlbackup

# systemd : l'ExecStart doit exister pour que verify ne se plaigne pas.
install -m 755 backup/*.sh /usr/local/sbin/
cp backup/*.service backup/*.timer /etc/systemd/system/
check "systemd-analyze verify (services + timers)" \
  systemd-analyze verify /etc/systemd/system/vaultwarden-backup.{service,timer} /etc/systemd/system/finance-backup.{service,timer} \
    /etc/systemd/system/memos-backup.{service,timer} /etc/systemd/system/hdd-backup.service

# sshd : la conf du compte de backup, testée avec un utilisateur vwbackup.
ssh-keygen -A >/dev/null 2>&1
adduser --system --group --no-create-home --home /srv/backups/vwbackup vwbackup >/dev/null 2>&1
install -d -m 755 /srv/backups/vwbackup /etc/ssh/authorized_keys
printf 'Include /repo/homelab/vps/sshd-vwbackup.conf\n' >/tmp/sshd_test_config
sshd_effective() {
  local cfg
  cfg=$(sshd -T -f /tmp/sshd_test_config -C user=vwbackup,host=x,addr=100.64.0.2) || return 1
  for want in 'chrootdirectory /srv/backups/vwbackup' 'forcecommand internal-sftp' 'passwordauthentication no' \
              'permittty no' 'allowtcpforwarding no'; do
    grep -qix "$want" <<<"$cfg" || { echo "valeur effective absente : $want"; return 1; }
  done
}
check "sshd : syntaxe et valeurs effectives pour vwbackup" sshd_effective

# ACL Tailscale : hujson (commentaires // et virgules finales) -> JSON.
check "ACL tailscale (syntaxe hujson)" python3 - <<'PY'
import json, re, sys
t = re.sub(r'(?m)^\s*//.*$', '', open('tailscale/acl.hujson').read())
t = re.sub(r',(\s*[}\]])', r'\1', t)
json.loads(t)
PY

exit "$fail"
