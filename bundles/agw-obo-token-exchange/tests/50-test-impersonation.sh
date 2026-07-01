set -euo pipefail

KEYCLOAK_URL="http://localhost:8080"

# --- Port-forward Keycloak, with guaranteed cleanup --------------------------------------
# Clear any stale forward holding :8080 from a previous crashed run, then start ours and
# capture its PID. The trap kills it on ANY exit path (success, error, or set -e abort), so
# we never leak the process — more reliable than a pkill at the end that a failure would skip.
pkill -f "port-forward.*keycloak.*8080" 2>/dev/null || true
kubectl --context "$CONTEXT" port-forward -n keycloak svc/keycloak 8080:8080 >/dev/null 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT

# Poll until the port-forward is accepting connections
ready=0
for _ in $(seq 1 20); do
  curl -sf -o /dev/null "${KEYCLOAK_URL}/realms/master" && { ready=1; break; }
  sleep 1
done
[ "$ready" -eq 1 ] || { echo "✗ Keycloak not reachable on :8080 after 20s" >&2; exit 1; }

###########################
# Get a User JWT (Step 7A)
###########################

USER_JWT=$(curl -s -X POST "${KEYCLOAK_URL}/realms/obo-realm/protocol/openid-connect/token" \
  -d "username=testuser" -d "password=testuser" -d "grant_type=password" \
  -d "client_id=agw-client" -d "client_secret=agw-client-secret" | jq -r '.access_token')

[ -n "$USER_JWT" ] || { echo "✗ USER_JWT is empty — token fetch failed" >&2; exit 1; }

echo "User JWT (first 40 chars): ${USER_JWT:0:40}..."

_seg=$(echo "$USER_JWT" | cut -d. -f2 | tr '_-' '/+')
while [ $(( ${#_seg} % 4 )) -ne 0 ]; do _seg="${_seg}="; done
echo "$_seg" | base64 -d 2>/dev/null | jq '{iss, sub, exp}'


STS_URL="http://localhost:7777"

# --- Port-forward Keycloak, with guaranteed cleanup --------------------------------------
# Clear any stale forward holding :8080 from a previous crashed run, then start ours and
# capture its PID. The trap kills it on ANY exit path (success, error, or set -e abort), so
# we never leak the process — more reliable than a pkill at the end that a failure would skip.
pkill -f "port-forward.*7777" 2>/dev/null || true
kubectl --context "$CONTEXT" port-forward -n agentgateway-system svc/enterprise-agentgateway 7777:7777  >/dev/null 2>&1 &
PF2_PID=$!
trap 'kill "$PF_PID" "$PF2_PID" 2>/dev/null || true' EXIT

# Poll until the port-forward is accepting connections (use JWKS endpoint — /token is POST-only)
ready=0
for _ in $(seq 1 20); do
  curl -sf -o /dev/null "${STS_URL}/.well-known/jwks.json" && { ready=1; break; }
  sleep 1
done
[ "$ready" -eq 1 ] || { echo "✗ Agentgateway STS not reachable on :7777 after 20s" >&2; exit 1; }

###########################################
# Exchange for an OBO Token (Impersonation) - Step 8A
###########################################

STS_RESPONSE=$(curl -s -X POST "${STS_URL}/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "Authorization: Bearer ${USER_JWT}" \
  -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
  -d "subject_token=${USER_JWT}" \
  -d "subject_token_type=urn:ietf:params:oauth:token-type:jwt")

echo "$STS_RESPONSE" | jq '.'

OBO_JWT=$(echo "$STS_RESPONSE" | jq -r '.access_token')

_seg=$(echo "$OBO_JWT" | cut -d. -f2 | tr '_-' '/+')
while [ $(( ${#_seg} % 4 )) -ne 0 ]; do _seg="${_seg}="; done
echo "$_seg" | base64 -d 2>/dev/null | jq '{iss, sub, act}'


###########################################
# Call the Protected Route with the plain user JWT - Step 9A
# Expect 401: the route requires an STS-issued OBO token, not a raw Keycloak JWT
###########################################

status=$(curl -s -o /dev/null -w "%{http_code}" "https://${HOST}/obo/openai" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${USER_JWT}" \
  -d '{"model": "mock-gpt-4o", "messages": [{"role": "user", "content": "Hello"}]}')
[ "$status" -eq 401 ] || { echo "✗ expected 401 with plain user JWT, got $status"; exit 1; }
echo "✓ plain user JWT rejected (401) — OBO token required"

###########################################
# Call the route with the OBO token via HTTP - Step 10A
# Expect 200: STS-issued OBO token should be accepted
###########################################
echo
echo "Now the end-to-end test to use an OBO JWT (Impersonation)..."

curl -is --fail-with-body "https://${HOST}/obo/openai" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $OBO_JWT" \
  -d '{"model": "mock-gpt-4o", "messages": [{"role": "user", "content": "Hello"}]}'
