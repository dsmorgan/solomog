#!/usr/bin/env bash
set -euo pipefail

KEYCLOAK_URL="http://localhost:8080"
NAMESPACE=agentgateway-system

# --- Port-forward Keycloak ---------------------------------------------------------------
pkill -f "port-forward.*keycloak.*8080" 2>/dev/null || true
kubectl --context "$CONTEXT" port-forward -n keycloak svc/keycloak 8080:8080 >/dev/null 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT

ready=0
for _ in $(seq 1 20); do
  curl -sf -o /dev/null "${KEYCLOAK_URL}/realms/master" && { ready=1; break; }
  sleep 1
done
[ "$ready" -eq 1 ] || { echo "✗ Keycloak not reachable on :8080 after 20s" >&2; exit 1; }

# --- Get fresh user JWT (must include may_act from 84-del-configure-keycloak-mayact.sh) --
USER_JWT=$(curl -s -X POST "${KEYCLOAK_URL}/realms/obo-realm/protocol/openid-connect/token" \
  -d "username=testuser" -d "password=testuser" -d "grant_type=password" \
  -d "client_id=agw-client" -d "client_secret=agw-client-secret" | jq -r '.access_token')
[ -n "$USER_JWT" ] || { echo "✗ USER_JWT is empty — token fetch failed" >&2; exit 1; }

_seg=$(echo "$USER_JWT" | cut -d. -f2 | tr '_-' '/+')
while [ $(( ${#_seg} % 4 )) -ne 0 ]; do _seg="${_seg}="; done
MAY_ACT=$(echo "$_seg" | base64 -d 2>/dev/null | jq -r '.may_act // empty')
[ -n "$MAY_ACT" ] || { echo "✗ may_act claim missing from user JWT — apply 84-del-configure-keycloak-mayact.sh first" >&2; exit 1; }
echo "✓ may_act present in user JWT: $MAY_ACT"

# --- Delegation token exchange from inside the agent pod ---------------------------------
# The pod's mounted service account token is the actor_token. No port-forward to the STS
# is needed — the pod reaches it directly via in-cluster DNS.
STS_RESPONSE=$(kubectl --context "$CONTEXT" exec obo-agent-test -n "$NAMESPACE" -- /bin/sh -c "
  K8S_SA_TOKEN=\$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
  curl -s -X POST http://enterprise-agentgateway.agentgateway-system.svc.cluster.local:7777/token \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d 'grant_type=urn:ietf:params:oauth:grant-type:token-exchange' \
    -d 'subject_token=$USER_JWT' \
    -d 'subject_token_type=urn:ietf:params:oauth:token-type:jwt' \
    -d \"actor_token=\$K8S_SA_TOKEN\" \
    -d 'actor_token_type=urn:ietf:params:oauth:token-type:jwt'
")
echo "$STS_RESPONSE" | jq '.'

DELEGATED_JWT=$(echo "$STS_RESPONSE" | jq -r '.access_token')
[ -n "$DELEGATED_JWT" ] || { echo "✗ DELEGATED_JWT is empty — token exchange failed" >&2; exit 1; }

# Verify both sub (user) and act (agent) are present in the delegated token
_seg=$(echo "$DELEGATED_JWT" | cut -d. -f2 | tr '_-' '/+')
while [ $(( ${#_seg} % 4 )) -ne 0 ]; do _seg="${_seg}="; done
echo "$_seg" | base64 -d 2>/dev/null | jq '{iss, sub, act}'

ACT=$(echo "$_seg" | base64 -d 2>/dev/null | jq -r '.act // empty')
[ -n "$ACT" ] || { echo "✗ act claim missing from delegated JWT" >&2; exit 1; }
echo "✓ delegated JWT has act claim — delegation confirmed"


echo
echo "Now the end-to-end test to use an OBO JWT (Delegation)..."
# --- Call the protected route with the delegated token -----------------------------------
curl -is --fail-with-body "https://${HOST}/obo/openai" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $DELEGATED_JWT" \
  -d '{"model": "mock-gpt-4o", "messages": [{"role": "user", "content": "Hello"}]}'
