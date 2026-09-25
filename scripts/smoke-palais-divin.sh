#!/usr/bin/env bash
# Smoke test for a deployed palais-divin stack. Read-only: it never writes data.
#
#   ./scripts/smoke-palais-divin.sh
#   ./scripts/smoke-palais-divin.sh https://palais-divin.lepgu.fr https://api.palais-divin.lepgu.fr
#
# Set SMOKE_BEARER_TOKEN to also exercise an authenticated endpoint. Get one from
# the browser after logging in (DevTools → the /api/* request's Authorization
# header), or via a client-credentials/password grant against the realm.
set -uo pipefail

FRONT_URL="${1:-https://palais-divin.lepgu.fr}"
API_URL="${2:-https://api.palais-divin.lepgu.fr}"

pass=0
fail=0

# check <label> <expected-status> <url> [curl args...]
check() {
  local label="$1" expected="$2" url="$3"
  shift 3
  local body status
  body=$(curl -sS -o /tmp/smoke-body.$$ -w '%{http_code}' --max-time 15 "$@" "$url" 2>/tmp/smoke-err.$$)
  status="$body"
  if [ "$status" = "$expected" ]; then
    printf '  ok    %-52s %s\n' "$label" "$status"
    pass=$((pass + 1))
  else
    printf '  FAIL  %-52s got %s, want %s\n' "$label" "${status:-<none>}" "$expected"
    sed 's/^/          /' /tmp/smoke-err.$$ 2>/dev/null | head -3
    head -c 300 /tmp/smoke-body.$$ 2>/dev/null | sed 's/^/          /'
    echo
    fail=$((fail + 1))
  fi
  rm -f /tmp/smoke-body.$$ /tmp/smoke-err.$$
}

# grep_body <label> <url> <pattern>
grep_body() {
  local label="$1" url="$2" pattern="$3"
  if curl -sS --max-time 15 "$url" | grep -q "$pattern"; then
    printf '  ok    %-52s matched %s\n' "$label" "$pattern"
    pass=$((pass + 1))
  else
    printf '  FAIL  %-52s no %s in body\n' "$label" "$pattern"
    fail=$((fail + 1))
  fi
}

echo "front: $FRONT_URL"
echo "api:   $API_URL"
echo

echo "backend"
check "GET /actuator/health" 200 "$API_URL/actuator/health"
grep_body "  health reports UP" "$API_URL/actuator/health" '"status":"UP"'
check "GET /api/v1/public/restaurants (anon)" 200 "$API_URL/api/v1/public/restaurants?size=1"
check "GET /api/v1/public/tags (anon)" 200 "$API_URL/api/v1/public/tags?size=1"
# The auth wall itself is part of the contract: unauthenticated /user/** must be
# a 401 ProblemDetail, not a 403 or an empty body (see CLAUDE.md, Boot 4 gotchas).
check "GET /api/v1/user/connections (anon → 401)" 401 "$API_URL/api/v1/user/connections"
check "GET /actuator/prometheus (anon → 401)" 401 "$API_URL/actuator/prometheus"

echo
echo "frontend"
check "GET /" 200 "$FRONT_URL/"
check "GET /api/v1/public/restaurants (via BFF proxy)" 200 "$FRONT_URL/api/v1/public/restaurants?size=1"
check "GET /auth/login (redirects to Keycloak)" 302 "$FRONT_URL/auth/login"

echo
echo "authenticated"
if [ -n "${SMOKE_BEARER_TOKEN:-}" ]; then
  check "GET /api/v1/user/connections (bearer)" 200 "$API_URL/api/v1/user/connections" \
    -H "Authorization: Bearer $SMOKE_BEARER_TOKEN"
  check "GET /api/v1/user/recommendations (bearer)" 200 "$API_URL/api/v1/user/recommendations?size=1" \
    -H "Authorization: Bearer $SMOKE_BEARER_TOKEN"
else
  echo "  skip  SMOKE_BEARER_TOKEN not set"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
