#!/usr/bin/env bash
# Print a Keycloak user access token for this bundle's realm on stdout.
#
# Keycloak is cluster-internal, so this port-forwards to reach it. The token is cached in the
# temp dir for 3 minutes (Keycloak's default access-token lifespan is 5), which keeps a run of
# several tests to one port-forward instead of one each.
#
#   CLUSTER=<c> bash bundles/agw-trace-exchanged-token/helpers/get-token.sh
#   TOKEN=$(CLUSTER=<c> bash .../helpers/get-token.sh)     # the usual form
#
# Env: CLUSTER (required, or CONTEXT), FORCE=true to bypass the cache.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=/dev/null
. "$REPO_DIR/scripts/lib/target.sh"

REALM=exchange-realm
CLIENT=login-client
USER=testuser
PASS=password
LOCAL_PORT="${KC_LOCAL_PORT:-8082}"
CACHE="${TMPDIR:-/tmp}/agw-trace-exchanged-token.jwt"

CTX="${CONTEXT:-$(solomog_context "${CLUSTER:?set CLUSTER=<name>}")}"

if [ "${FORCE:-false}" != true ] && [ -f "$CACHE" ]; then
  # Cache hit only while comfortably inside the token lifespan.
  if [ -n "$(find "$CACHE" -mmin -3 2>/dev/null)" ]; then
    cat "$CACHE"; exit 0
  fi
fi

pkill -f "port-forward.*keycloak.*${LOCAL_PORT}" 2>/dev/null || true
sleep 1
kubectl --context "$CTX" port-forward -n keycloak svc/keycloak "${LOCAL_PORT}:8080" >/dev/null 2>&1 &
PF_PID=$!
disown "$PF_PID" 2>/dev/null || true
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT

for _ in $(seq 1 20); do
  curl -sf -o /dev/null "http://localhost:${LOCAL_PORT}/realms/${REALM}/.well-known/openid-configuration" && break
  sleep 1
done

TOKEN="$(curl -s -X POST "http://localhost:${LOCAL_PORT}/realms/${REALM}/protocol/openid-connect/token" \
  -d "client_id=${CLIENT}" -d "username=${USER}" -d "password=${PASS}" -d "grant_type=password" \
  | jq -r '.access_token // empty')"

if [ -z "$TOKEN" ]; then
  echo "✗ could not get a token from Keycloak realm ${REALM}." >&2
  echo "  Has the bundle been applied to this cluster? solomog apply BUNDLE=agw-trace-exchanged-token CLUSTER=<c>" >&2
  exit 1
fi

printf '%s' "$TOKEN" > "$CACHE"
chmod 600 "$CACHE"
printf '%s' "$TOKEN"
