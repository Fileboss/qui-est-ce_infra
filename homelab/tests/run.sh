#!/usr/bin/env bash
# Lance toutes les vérifications du homelab en local (Mac). Nécessite Docker.
#   homelab/tests/run.sh
# Code de sortie non nul si une vérification échoue.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
IMAGE=homelab-tests
fail=0

step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
# Sortie affichée seulement en cas d'échec (ou pour les étapes qui affichent leur propre détail).
run() {
  local out
  if out=$("$@" 2>&1); then
    [ -z "${SHOW:-}" ] || echo "$out"
    echo "OK"
  else
    echo "$out"; echo "ÉCHEC"; fail=1
  fi
}

if ! docker info >/dev/null 2>&1; then
  echo "Docker ne répond pas : lance Docker Desktop (ou OrbStack/Colima) puis réessaie." >&2
  exit 2
fi

step "Image de test"
docker build -q -t "$IMAGE" "$ROOT/homelab/tests" >/dev/null || { echo "build impossible" >&2; exit 2; }
echo "OK"

step "Scripts, unités systemd, sshd, ACL (dans Linux)"
SHOW=1 run docker run --rm -v "$ROOT:/repo:ro" "$IMAGE" bash /repo/homelab/tests/static.sh

step "Tests des scripts de backup (bats)"
run docker run --rm -v "$ROOT:/repo:ro" "$IMAGE" bats --print-output-on-failure /repo/homelab/tests/

step "docker compose config : homelab/"
# Le compose lit .env (env_file) : on valide sur une copie temporaire de .env.example.
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cp "$ROOT/homelab/docker-compose.yml" "$TMP/"; cp "$ROOT/homelab/.env.example" "$TMP/.env"
run docker compose -f "$TMP/docker-compose.yml" --env-file "$TMP/.env" config -q

for stack in monitoring simple-finance vps/beszel-agent; do
  step "docker compose config : homelab/$stack"
  run docker compose -f "$ROOT/homelab/$stack/docker-compose.yml" --env-file "$ROOT/homelab/$stack/.env.example" config -q
done

step "docker compose config : racine (VPS)"
run docker compose -f "$ROOT/docker-compose.yml" --env-file "$ROOT/.env.example" config -q

step "Caddyfile"
run docker run --rm -v "$ROOT/Caddyfile:/etc/caddy/Caddyfile:ro" \
  -e HOMELAB_TAILNET_IP=100.64.0.1 -e KC_ADMIN_BASIC_AUTH_HASH=x \
  caddy:2 caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

echo
if [ "$fail" -eq 0 ]; then echo "Tout est OK."; else echo "Des vérifications ont échoué (voir ci-dessus)." >&2; fi
exit "$fail"
