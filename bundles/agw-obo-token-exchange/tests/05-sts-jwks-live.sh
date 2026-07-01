#!/usr/bin/env bash
# Live functional check: the STS is actually SERVING, not just started. 03's log line
# proves the server booted once — it says nothing about whether it's still up (or ever
# answered a real request). :7777 isn't exposed via a gateway route, so we reach it the
# same way 13-configure-keycloak.sh reaches Keycloak: a short-lived port-forward with
# trap-based cleanup and a readiness poll (no sleep-guessing).
set -uo pipefail   # no set -e — a failed probe during the poll loop must not abort early
NAMESPACE=agentgateway-system
SVC=enterprise-agentgateway
LOCAL_PORT=17777   # arbitrary local port unlikely to collide with anything real

pkill -f "port-forward.*${SVC}.*${LOCAL_PORT}" 2>/dev/null || true
kubectl --context "$CONTEXT" port-forward -n "$NAMESPACE" "svc/${SVC}" "${LOCAL_PORT}:7777" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT

echo "  waiting for STS on :${LOCAL_PORT} ..."
ready=0
for _ in $(seq 1 20); do
  curl -sf -o /dev/null "http://localhost:${LOCAL_PORT}/.well-known/jwks.json" && { ready=1; break; }
  sleep 1
done
if [ "$ready" -ne 1 ]; then
  echo "✗ STS not reachable on :7777 after 20s (port-forward or server not up)" >&2
  exit 1
fi

JWKS="$(curl -s "http://localhost:${LOCAL_PORT}/.well-known/jwks.json")"
KEY_COUNT="$(printf '%s' "$JWKS" | jq '.keys | length' 2>/dev/null)"
if ! [ "$KEY_COUNT" -ge 1 ] 2>/dev/null; then
  echo "✗ JWKS endpoint responded but has no valid keys:" >&2
  echo "$JWKS" >&2
  exit 1
fi
echo "✓ STS JWKS endpoint live — ${KEY_COUNT} signing key(s) published"
