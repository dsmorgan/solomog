#!/usr/bin/env bash
# OBO against the REAL Anthropic API on /obo/anthropic. Impersonation flow (subject = user
# JWT, no actor_token), same shape as 50-test-impersonation.sh but hitting Anthropic.
#
# Doubles as the proof that the OBO token is NOT forwarded to the LLM: Anthropic validates the
# credential, so if the gateway passed the OBO token through instead of injecting the real key
# (from anthropic-secret), Anthropic would return 401. A 200 with a real Claude reply means the
# OBO token was stripped at the gateway and the real key swapped in — it never reached Anthropic.
#
# NOTE: calls the real Anthropic API (costs tokens) — expected for a deliberate test run.
set -euo pipefail

KEYCLOAK_URL="http://localhost:8080"
STS_URL="http://localhost:7777"

# --- Port-forward Keycloak (:8080) and the STS (:7777), cleaned up on any exit ------------
pkill -f "port-forward.*keycloak.*8080" 2>/dev/null || true
kubectl --context "$CONTEXT" port-forward -n keycloak svc/keycloak 8080:8080 >/dev/null 2>&1 &
PF_PID=$!
pkill -f "port-forward.*7777" 2>/dev/null || true
kubectl --context "$CONTEXT" port-forward -n agentgateway-system svc/enterprise-agentgateway 7777:7777 >/dev/null 2>&1 &
PF2_PID=$!
trap 'kill "$PF_PID" "$PF2_PID" 2>/dev/null || true' EXIT

ready=0
for _ in $(seq 1 20); do
  curl -sf -o /dev/null "${KEYCLOAK_URL}/realms/master" && { ready=1; break; }
  sleep 1
done
[ "$ready" -eq 1 ] || { echo "✗ Keycloak not reachable on :8080 after 20s" >&2; exit 1; }
ready=0
for _ in $(seq 1 20); do
  curl -sf -o /dev/null "${STS_URL}/.well-known/jwks.json" && { ready=1; break; }
  sleep 1
done
[ "$ready" -eq 1 ] || { echo "✗ Agentgateway STS not reachable on :7777 after 20s" >&2; exit 1; }

# --- User JWT, then exchange for an OBO token (impersonation) -----------------------------
USER_JWT=$(curl -s -X POST "${KEYCLOAK_URL}/realms/obo-realm/protocol/openid-connect/token" \
  -d "username=testuser" -d "password=testuser" -d "grant_type=password" \
  -d "client_id=agw-client" -d "client_secret=agw-client-secret" | jq -r '.access_token')
[ -n "$USER_JWT" ] && [ "$USER_JWT" != "null" ] || { echo "✗ USER_JWT is empty — token fetch failed" >&2; exit 1; }

OBO_JWT=$(curl -s -X POST "${STS_URL}/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "Authorization: Bearer ${USER_JWT}" \
  -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
  -d "subject_token=${USER_JWT}" \
  -d "subject_token_type=urn:ietf:params:oauth:token-type:jwt" | jq -r '.access_token')
[ -n "$OBO_JWT" ] && [ "$OBO_JWT" != "null" ] || { echo "✗ OBO exchange failed — no access_token" >&2; exit 1; }
echo "✓ obtained OBO token from STS"

# --- The raw user JWT is rejected (proves the route requires an STS token) ----------------
status=$(curl -sk -o /dev/null -w "%{http_code}" "https://${HOST}/obo/anthropic" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${USER_JWT}" \
  -d '{"model":"claude","messages":[{"role":"user","content":"Reply with the single word: ok"}]}')
[ "$status" -eq 401 ] || { echo "✗ expected 401 with plain user JWT, got $status"; exit 1; }
echo "✓ plain user JWT rejected (401) — OBO token required"

# --- The OBO token is accepted AND swapped for the real key upstream ----------------------
# A 2xx here is the credential-swap proof: Anthropic would 401 if it had received the OBO token.
echo
echo "Now the end-to-end OBO call against the real Anthropic API (/obo/anthropic)..."
curl -is --fail-with-body "https://${HOST}/obo/anthropic" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $OBO_JWT" \
  -d '{"model":"claude","messages":[{"role":"user","content":"Reply with the single word: ok"}]}'
