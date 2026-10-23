#!/usr/bin/env bash
# Scan de vulnérabilités des images déployées (VPS + homelab). Utilisé par la CI
# (.github/workflows/vulns.yml), lançable aussi en local (Docker requis) :
#   security/scan-images.sh list          # images des stacks, versions des .env.example
#   security/scan-images.sh scan IMAGE    # Grype + versions minimales de Node/Bun
#   security/scan-images.sh all           # list puis scan de chaque image
# Les versions scannées sont celles des .env.example : les garder alignées sur les .env réels.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
GRYPE_IMAGE=anchore/grype:v0.121.0@sha256:621d56d1d68106b787022c81546f7e0a36202a25d1239f0c20195fab8c16f7ea
PLATFORM=linux/amd64 # le VPS et le HP sont en amd64
# Grype : seules comptent les vulnérabilités qui ont un correctif. Échec si l'une d'elles
# est exploitée (catalogue KEV de la CISA) ou probablement exploitée (EPSS dans le top
# EPSS_FAIL, 10 % par défaut). Les Critical/High « ordinaires » des images de base
# (souvent en attente d'une reconstruction en amont) sont listées sans faire échouer.
EPSS_FAIL=${EPSS_FAIL:-0.90}

# Versions minimales des runtimes JS. Les scanners ne repèrent pas toujours le binaire
# (Grype ne voit pas Bun, et les CVE récentes arrivent avec du retard dans leur base) :
# ce contrôle couvre les failles critiques connues comme Node2Shell (CVE-2026-111497).
# Une branche Node absente de la liste est en fin de vie : refusée.
NODE_MIN="22:22.23.4 24:24.22.1 26:26.12.1"
BUN_MIN=1.4.4

summary() { if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then cat >>"$GITHUB_STEP_SUMMARY"; else cat >/dev/null; fi; }

list_images() {
  local tmp stack
  tmp=$(mktemp -d)
  # La stack homelab/ lit .env via env_file : on valide sur une copie de .env.example.
  cp "$ROOT/homelab/docker-compose.yml" "$tmp/"; cp "$ROOT/homelab/.env.example" "$tmp/.env"
  {
    docker compose -f "$ROOT/docker-compose.yml" --env-file "$ROOT/.env.example" config --images
    docker compose -f "$tmp/docker-compose.yml" --env-file "$tmp/.env" config --images
    for stack in monitoring simple-finance memos vps/beszel-agent; do
      docker compose -f "$ROOT/homelab/$stack/docker-compose.yml" --env-file "$ROOT/homelab/$stack/.env.example" config --images
    done
  } | sort -u
  rm -rf "$tmp"
}

# version_ge A B : vrai si A >= B
version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }

check_runtimes() {
  local img=$1 out kind ver major min entry
  # `node` peut être Bun (lien node -> bun) : on demande au runtime ce qu'il est.
  for bin in node bun; do
    out=$(docker run --rm --platform "$PLATFORM" --network none --pull never --entrypoint "$bin" "$img" \
      -e 'console.log(process.versions.bun ? "bun "+process.versions.bun : "node "+process.versions.node)' 2>/dev/null) || continue
    read -r kind ver <<<"$out"
    if [ "$kind" = bun ]; then
      min=$BUN_MIN
    else
      major=${ver%%.*}; min=""
      for entry in $NODE_MIN; do [ "${entry%%:*}" = "$major" ] && min=${entry#*:}; done
      if [ -z "$min" ]; then
        echo "FAIL $img : Node $ver, branche $major en fin de vie"; continue
      fi
    fi
    if version_ge "$ver" "$min"; then
      echo "ok   $img : $kind $ver (>= $min)"
    else
      echo "FAIL $img : $kind $ver < $min"
    fi
  done | sort -u | tee "$TMPDIR_SCAN/runtimes"
  ! grep -q '^FAIL' "$TMPDIR_SCAN/runtimes"
}

scan() {
  local img=$1 rc=0
  TMPDIR_SCAN=$(mktemp -d)
  echo "== $img"
  docker pull -q --platform "$PLATFORM" "$img" >/dev/null || { echo "pull impossible : $img"; return 2; }

  echo "-- Runtimes JS"
  check_runtimes "$img" || rc=1

  echo "-- Grype (correctifs disponibles ; échec si KEV ou EPSS >= $EPSS_FAIL)"
  docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "$TMPDIR_SCAN:/out" "$GRYPE_IMAGE" \
    "docker:$img" --platform "$PLATFORM" --only-fixed -q -o table -o json=/out/grype.json \
    >"$TMPDIR_SCAN/grype" 2>&1 || { echo "grype a échoué" >>"$TMPDIR_SCAN/grype"; rc=1; }
  if [ -f "$TMPDIR_SCAN/grype.json" ]; then
    python3 - "$TMPDIR_SCAN/grype.json" "$EPSS_FAIL" >>"$TMPDIR_SCAN/grype" <<'PY' || rc=1
import json, sys
matches = json.load(open(sys.argv[1]))["matches"]
seuil = float(sys.argv[2])
bloquants = set()
for m in matches:
    v, a = m["vulnerability"], m["artifact"]
    epss = max((e.get("percentile", 0) for e in v.get("epss") or []), default=0)
    if v.get("knownExploited") or epss >= seuil:
        raison = "KEV" if v.get("knownExploited") else f"EPSS top {100 - epss * 100:.0f} %"
        bloquants.add(f"FAIL {v['id']} ({v['severity']}, {raison}) : {a['name']} {a['version']}")
graves = {m["vulnerability"]["id"] for m in matches if m["vulnerability"]["severity"] in ("Critical", "High")}
print(f"Critical/High avec correctif : {len(graves)}")
print("\n".join(sorted(bloquants)) or "Aucune vulnérabilité exploitée connue.")
sys.exit(1 if bloquants else 0)
PY
  fi
  cat "$TMPDIR_SCAN/grype"

  {
    echo "### \`$img\` : $([ $rc -eq 0 ] && echo OK || echo '**ÉCHEC**')"
    echo; echo '```'; cat "$TMPDIR_SCAN/runtimes" "$TMPDIR_SCAN/grype"; echo '```'
  } | summary
  rm -rf "$TMPDIR_SCAN"
  return $rc
}

case ${1:-} in
  list) list_images ;;
  scan) [ -n "${2:-}" ] || { echo "usage: $0 scan IMAGE" >&2; exit 2; }; scan "$2" ;;
  all)
    fail=0
    while read -r img; do scan "$img" || fail=1; echo; done < <(list_images)
    exit $fail ;;
  *) echo "usage: $0 list | scan IMAGE | all" >&2; exit 2 ;;
esac
