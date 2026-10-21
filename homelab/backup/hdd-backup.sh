#!/usr/bin/env bash
# Sauvegarde mensuelle complète du HP sur le disque USB externe, lancée à la main (§17).
# 1. monte le disque (par UUID) et vérifie que c'est bien lui
# 2. arrête tous les conteneurs : Postgres et SQLite sont copiés à froid, donc cohérents
# 3. restic sauvegarde tout le système (hors Docker et caches) dans un dépôt chiffré sur le disque
# 4. redémarre les conteneurs, applique la rétention, relit un échantillon du dépôt, démonte
#   hdd-backup.sh          sauvegarde (normalement via : systemctl start --no-block hdd-backup)
#   hdd-backup.sh --init   crée le dépôt sur un disque neuf, puis s'arrête
set -euo pipefail

ENV_FILE=${ENV_FILE:-/etc/hdd-backup.env}
# shellcheck disable=SC1090
source "$ENV_FILE"
: "${HDD_UUID:?}" "${RESTIC_PASSWORD_FILE:?}"

MNT=${HDD_MOUNT:-/mnt/backup-hdd}
DEV=${HDD_DEV:-/dev/disk/by-uuid/$HDD_UUID}
RESTIC_REPOSITORY="$MNT/${HDD_REPO_DIR:-homelab-restic}"
export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE

INIT=0
case "${1:-}" in
  "") ;;
  --init) INIT=1 ;;
  *) echo "Usage : $0 [--init]" >&2; exit 2 ;;
esac

die() { echo "$*" >&2; exit 1; }

hc_ping() {
  [ -n "${HDD_HC_PING_URL:-}" ] || return 0
  curl -fsS -m 10 --retry 3 -o /dev/null "${HDD_HC_PING_URL}${1:-}" || true
}

MOUNTED_BY_US=0
STOPPED=()

start_containers() {
  [ "${#STOPPED[@]}" -gt 0 ] || return 0
  echo "Redémarrage de ${#STOPPED[@]} conteneur(s)"
  docker start "${STOPPED[@]}" >/dev/null
  STOPPED=()
}

cleanup() {
  rc=$?
  # En premier : quoi qu'il arrive, les services repartent.
  start_containers || rc=1
  if [ "$MOUNTED_BY_US" -eq 1 ]; then
    sync
    umount "$MNT" || { echo "Démontage impossible : $MNT" >&2; rc=1; }
  fi
  if [ "$rc" -ne 0 ] && [ "$INIT" -eq 0 ]; then hc_ping /fail; fi
  exit "$rc"
}
trap cleanup EXIT

[ "$INIT" -eq 1 ] || hc_ping /start

# --- Disque -------------------------------------------------------------------
[ -e "$DEV" ] || die "Disque introuvable ($DEV) : est-il branché ?"
install -d -m 700 "$MNT"
if ! mountpoint -q "$MNT"; then
  # HDD_FSTYPE vide : type détecté par mount. Disque NTFS : ntfs-3g (voir hdd-backup.env.example).
  mount ${HDD_FSTYPE:+-t "$HDD_FSTYPE"} "$DEV" "$MNT"
  MOUNTED_BY_US=1
fi
# Garde-fou : sans ça, un montage raté ferait écrire le dépôt sur le SSD système.
[ "$(findmnt -n -o UUID --mountpoint "$MNT")" = "$HDD_UUID" ] \
  || die "$MNT n'est pas le disque de backup (UUID attendu : $HDD_UUID)"

if [ "$INIT" -eq 1 ]; then
  [ ! -e "$RESTIC_REPOSITORY/config" ] || die "Un dépôt existe déjà : $RESTIC_REPOSITORY"
  restic init
  echo "Dépôt créé : $RESTIC_REPOSITORY"
  exit 0
fi
[ -e "$RESTIC_REPOSITORY/config" ] \
  || die "Pas de dépôt restic dans $RESTIC_REPOSITORY. Disque neuf : lance d'abord '$0 --init'."

# --- Sauvegarde à froid -------------------------------------------------------
# Pas de process substitution : si docker ne répond pas, on échoue au lieu de sauvegarder à chaud.
ids=$(docker ps -q)
RUNNING=()
[ -z "$ids" ] || mapfile -t RUNNING <<<"$ids"
if [ "${#RUNNING[@]}" -gt 0 ]; then
  echo "Arrêt de ${#RUNNING[@]} conteneur(s)"
  STOPPED=("${RUNNING[@]}")
  docker stop -t 60 "${RUNNING[@]}" >/dev/null
fi

# Chaque système de fichiers réel : / et, s'ils sont montés à part, /boot, l'ESP et
# le futur SSD des photos. --one-file-system écarte /proc, /sys, /dev, /run et le disque USB.
TARGETS=(/)
for p in /boot /boot/efi /mnt/data; do
  if mountpoint -q "$p"; then TARGETS+=("$p"); fi
done

# Exclus : images et couches Docker (re-téléchargeables, l'état des apps est dans des
# dossiers montés, sauvegardés), caches, fichiers temporaires, dossiers de travail des autres backups.
restic backup --one-file-system --exclude-caches --tag hdd-full \
  --exclude /var/lib/docker --exclude /var/lib/containerd \
  --exclude /var/cache --exclude /var/tmp --exclude /tmp --exclude /swapfile \
  --exclude '/var/backups/*-stage' --exclude '/home/*/.cache' --exclude /root/.cache \
  --exclude "$MNT" \
  "${TARGETS[@]}"

start_containers

# --- Rétention et vérification (services de nouveau en ligne) -----------------
restic forget --tag hdd-full --keep-monthly 24 --keep-yearly 10 --prune
# Relit et déchiffre 5 % des données : détecte un disque qui commence à corrompre.
restic check --read-data-subset 5%

if [ "$MOUNTED_BY_US" -eq 1 ]; then
  sync
  umount "$MNT"
  MOUNTED_BY_US=0
  echo "Sauvegarde terminée, disque démonté : tu peux le débrancher."
else
  echo "Sauvegarde terminée. $MNT était déjà monté avant le backup : il reste monté."
fi
hc_ping
