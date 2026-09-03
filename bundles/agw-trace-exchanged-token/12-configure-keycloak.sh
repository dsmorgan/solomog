# Configure Keycloak as the external authorization server for this bundle: a realm, a public
# login client (the user's subject token), a confidential exchange client with RFC 8693
# Standard Token Exchange enabled (the client the gateway authenticates as), and a test user.
#
# Also mints the exchange client's secret and pushes it straight into a Kubernetes Secret. The
# value never touches .env or git: it is generated here, used here, and stored only in the
# cluster. Re-running rotates it and updates the Secret, which is harmless.
#
# Idempotent: realm/clients/user are created only when absent.
# CONTEXT is exported by apply-bundle.sh.
#
# Keycloak 26.2+ ships Standard Token Exchange (RFC 8693 "v2") as a supported feature, enabled
# per client by the `standard.token.exchange.enabled` attribute -- no server --features flag.
# If a future image drops it, test 20 fails first and says so, before any gateway is blamed.
set -euo pipefail

LOCAL_PORT=8081                       # not 8080: agw-obo-token-exchange's hook uses that
KC="http://localhost:${LOCAL_PORT}"
REALM=exchange-realm
LOGIN_CLIENT=login-client             # public, direct access grants -> the user's token
EXCHANGE_CLIENT=exchange-client       # confidential, does the RFC 8693 exchange
TEST_USER=testuser
TEST_PASS=password
NS=agentgateway-system
SECRET_NAME=exchange-client-secret

port_holder() { lsof -nP -iTCP:"${LOCAL_PORT}" -sTCP:LISTEN 2>/dev/null; }

echo "==> Waiting for Keycloak to be Ready (cold start can take 1-2 min) ..."
if ! kubectl --context "$CONTEXT" rollout status statefulset/keycloak -n keycloak --timeout=240s; then
  echo "Error: Keycloak StatefulSet not Ready after 240s:" >&2
  kubectl --context "$CONTEXT" get pods -n keycloak >&2 || true
  exit 1
fi

pkill -f "port-forward.*keycloak.*${LOCAL_PORT}" 2>/dev/null || true
freed=0
for _ in $(seq 1 10); do [ -z "$(port_holder)" ] && { freed=1; break; }; sleep 1; done
if [ "$freed" != 1 ]; then
  echo "Error: local port ${LOCAL_PORT} is in use; free it and re-run. Holder:" >&2
  port_holder >&2 || true
  exit 1
fi

PF_LOG="$(mktemp "${TMPDIR:-/tmp}/kc-exchange-pf.XXXXXX")"
kubectl --context "$CONTEXT" port-forward -n keycloak svc/keycloak "${LOCAL_PORT}:8080" >"$PF_LOG" 2>&1 &
PF_PID=$!
disown "$PF_PID" 2>/dev/null || true
trap 'kill "$PF_PID" 2>/dev/null || true; rm -f "$PF_LOG"' EXIT

up=0
for _ in $(seq 1 30); do
  if curl -sf -o /dev/null "${KC}/realms/master/.well-known/openid-configuration"; then up=1; break; fi
  if ! kill -0 "$PF_PID" 2>/dev/null; then
    echo "Error: port-forward died. Output:" >&2; cat "$PF_LOG" >&2; exit 1
  fi
  sleep 2
done
[ "$up" = 1 ] || { echo "Error: Keycloak not reachable on ${KC}:" >&2; cat "$PF_LOG" >&2; exit 1; }

ADMIN_TOKEN="$(curl -s -X POST "${KC}/realms/master/protocol/openid-connect/token" \
  -d "username=admin" -d "password=admin" -d "grant_type=password" -d "client_id=admin-cli" \
  | jq -r .access_token)"
[ -n "$ADMIN_TOKEN" ] && [ "$ADMIN_TOKEN" != null ] || { echo "Error: could not get Keycloak admin token" >&2; exit 1; }

api() { curl -s -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" "$@"; }
count() { api "${KC}$1" | jq 'length'; }

# --- Realm ------------------------------------------------------------------------------
# frontendUrl pins the realm's issuer to its in-cluster URL. Without it Keycloak derives the
# issuer from the request host, so a token fetched over a port-forward would carry
# iss=http://localhost:... and the gateway -- which validates against the in-cluster issuer --
# would reject it. Setting it per realm leaves the shared master realm and admin console alone.
ISSUER="http://keycloak.keycloak.svc.cluster.local:8080"
if [ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $ADMIN_TOKEN" "${KC}/admin/realms/${REALM}")" = "200" ]; then
  api -X PUT "${KC}/admin/realms/${REALM}" \
    -d "{\"realm\":\"${REALM}\",\"enabled\":true,\"attributes\":{\"frontendUrl\":\"${ISSUER}\"}}" >/dev/null
  echo "    ✓ realm ${REALM} exists (frontendUrl pinned)"
else
  api -X POST "${KC}/admin/realms" \
    -d "{\"realm\":\"${REALM}\",\"enabled\":true,\"attributes\":{\"frontendUrl\":\"${ISSUER}\"}}" >/dev/null
  echo "    + created realm ${REALM} (issuer ${ISSUER}/realms/${REALM})"
fi

# --- Login client (public): the user's subject token ------------------------------------
if [ "$(count "/admin/realms/${REALM}/clients?clientId=${LOGIN_CLIENT}")" -gt 0 ]; then
  echo "    ✓ client ${LOGIN_CLIENT} exists"
else
  api -X POST "${KC}/admin/realms/${REALM}/clients" -d "{
    \"clientId\": \"${LOGIN_CLIENT}\",
    \"enabled\": true,
    \"publicClient\": true,
    \"directAccessGrantsEnabled\": true,
    \"standardFlowEnabled\": false
  }" >/dev/null
  echo "    + created public client ${LOGIN_CLIENT}"
fi

# --- Exchange client (confidential): the gateway authenticates as this one ---------------
# `standard.token.exchange.enabled` is what permits RFC 8693 on this client. The exchanged
# token carries azp=exchange-client, which is how every test tells "exchanged" from "inbound".
EX_SECRET="$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 32)"
EX_ID="$(api "${KC}/admin/realms/${REALM}/clients?clientId=${EXCHANGE_CLIENT}" | jq -r '.[0].id // empty')"
if [ -n "$EX_ID" ]; then
  api -X PUT "${KC}/admin/realms/${REALM}/clients/${EX_ID}" -d "{
    \"clientId\": \"${EXCHANGE_CLIENT}\", \"enabled\": true, \"publicClient\": false,
    \"serviceAccountsEnabled\": true, \"standardFlowEnabled\": false,
    \"secret\": \"${EX_SECRET}\",
    \"attributes\": {\"standard.token.exchange.enabled\": \"true\"}
  }" >/dev/null
  echo "    ↻ updated client ${EXCHANGE_CLIENT} (secret rotated, token exchange enabled)"
else
  api -X POST "${KC}/admin/realms/${REALM}/clients" -d "{
    \"clientId\": \"${EXCHANGE_CLIENT}\", \"enabled\": true, \"publicClient\": false,
    \"serviceAccountsEnabled\": true, \"standardFlowEnabled\": false,
    \"secret\": \"${EX_SECRET}\",
    \"attributes\": {\"standard.token.exchange.enabled\": \"true\"}
  }" >/dev/null
  echo "    + created confidential client ${EXCHANGE_CLIENT} (token exchange enabled)"
fi

# --- Audience mapper on the login client ------------------------------------------------
# Keycloak's Standard Token Exchange refuses with "Client is not within the token audience"
# unless the exchanging client appears in the subject token's aud. The subject token is minted
# for login-client, so login-client needs a mapper adding exchange-client to the audience.
# This is a Keycloak authorization rule, not an agentgateway one -- Okta expresses the same
# constraint through its authorization-server access policies.
LOGIN_ID="$(api "${KC}/admin/realms/${REALM}/clients?clientId=${LOGIN_CLIENT}" | jq -r '.[0].id // empty')"
if [ -n "$LOGIN_ID" ]; then
  has_mapper="$(api "${KC}/admin/realms/${REALM}/clients/${LOGIN_ID}/protocol-mappers/models" \
    | jq -r --arg n "exchange-audience" '[.[] | select(.name == $n)] | length')"
  if [ "${has_mapper:-0}" -gt 0 ]; then
    echo "    ✓ audience mapper present on ${LOGIN_CLIENT}"
  else
    api -X POST "${KC}/admin/realms/${REALM}/clients/${LOGIN_ID}/protocol-mappers/models" -d "{
      \"name\": \"exchange-audience\",
      \"protocol\": \"openid-connect\",
      \"protocolMapper\": \"oidc-audience-mapper\",
      \"config\": {
        \"included.client.audience\": \"${EXCHANGE_CLIENT}\",
        \"access.token.claim\": \"true\",
        \"id.token.claim\": \"false\"
      }
    }" >/dev/null
    echo "    + added audience mapper (${LOGIN_CLIENT} -> aud includes ${EXCHANGE_CLIENT})"
  fi
fi

# --- Test user --------------------------------------------------------------------------
# email/firstName/lastName are not decoration: Keycloak's declarative user profile marks them
# required, and a user missing them fails the password grant with the memorably unhelpful
# "invalid_grant: Account is not fully set up". Existing users are updated, not skipped, so a
# re-apply repairs one created before this was understood.
USER_JSON="{
    \"username\": \"${TEST_USER}\", \"enabled\": true, \"emailVerified\": true,
    \"email\": \"${TEST_USER}@example.test\",
    \"firstName\": \"Test\", \"lastName\": \"User\",
    \"credentials\": [{\"type\":\"password\",\"value\":\"${TEST_PASS}\",\"temporary\":false}]
  }"
USER_ID="$(api "${KC}/admin/realms/${REALM}/users?username=${TEST_USER}&exact=true" | jq -r '.[0].id // empty')"
if [ -n "$USER_ID" ]; then
  api -X PUT "${KC}/admin/realms/${REALM}/users/${USER_ID}" -d "$USER_JSON" >/dev/null
  echo "    ↻ updated user ${TEST_USER} (profile fields + password)"
else
  api -X POST "${KC}/admin/realms/${REALM}/users" -d "$USER_JSON" >/dev/null
  echo "    + created user ${TEST_USER}"
fi

# --- Client secret -> Kubernetes Secret (never .env, never git) --------------------------
kubectl --context "$CONTEXT" create namespace "$NS" --dry-run=client -o yaml \
  | kubectl --context "$CONTEXT" apply -f - >/dev/null
kubectl --context "$CONTEXT" create secret generic "$SECRET_NAME" -n "$NS" \
  --from-literal=clientSecret="${EX_SECRET}" \
  --from-literal=client_secret="${EX_SECRET}" \
  --dry-run=client -o yaml | kubectl --context "$CONTEXT" apply -f - >/dev/null
echo "    + stored ${EXCHANGE_CLIENT} secret in ${NS}/${SECRET_NAME}"

echo "✓ Keycloak ready (realm=${REALM}, login=${LOGIN_CLIENT}, exchange=${EXCHANGE_CLIENT}, user=${TEST_USER}/${TEST_PASS})"
