# Configure Keycloak (realm, client, user) for the OBO token-exchange scenario via the
# Keycloak Admin API, reached through a short-lived `kubectl port-forward` (not a gateway
# route): this is one-time control-plane bootstrap, Keycloak is host-sensitive, and the real
# token flow uses in-cluster DNS — so a route would only ever serve this setup.
#
# Idempotent: realm/client/user are created only if absent, so re-applying the bundle is safe.
# CONTEXT is exported by apply-bundle.sh (the target cluster's kube context).
set -euo pipefail

LOCAL_PORT=8080
KEYCLOAK_URL="http://localhost:${LOCAL_PORT}"

# --- Wait for Keycloak, then port-forward with real checking -----------------------------
# History (two bugs, both were masked): (a) `kubectl port-forward` fails INSTANTLY against a
# not-yet-Running pod ("pod is not running. Current status=Pending") — on a cold cluster the
# pod isn't scheduled yet when this hook runs right after the StatefulSet is applied; and
# (b) its stderr was discarded, so we blind-polled a dead port for the full timeout. Fix:
# wait for the pod to be Ready BEFORE forwarding, keep :8080, and never swallow the output.

port_holder() { lsof -nP -iTCP:"${LOCAL_PORT}" -sTCP:LISTEN 2>/dev/null; }

# 1. Wait for the Keycloak pod to be created AND Ready before we port-forward. rollout status
#    covers both the "pod not scheduled yet" gap (the Pending failure above) and readiness —
#    Keycloak's readiness probe gates on a working DB + full Quarkus boot, so this also means
#    it's actually serving. Cold start (fresh Postgres + migrations) legitimately takes 1-2 min.
echo "==> Waiting for Keycloak pod to be Ready (cold start can take 1-2 min) ..."
if ! kubectl --context "$CONTEXT" rollout status statefulset/keycloak -n keycloak --timeout=240s; then
  echo "Error: Keycloak StatefulSet not Ready after 240s:" >&2
  kubectl --context "$CONTEXT" get pods -n keycloak >&2 || true
  exit 1
fi

# 2. Clean up a stale forward WE previously left on this port, then confirm :LOCAL_PORT is
#    free before binding. pkill's SIGTERM is async so the socket isn't released instantly
#    (hence the free-wait). If a FOREIGN process holds it, fail fast naming the holder rather
#    than bind-failing silently.
pkill -f "port-forward.*keycloak.*${LOCAL_PORT}" 2>/dev/null || true
freed=0
for _ in $(seq 1 10); do
  [ -z "$(port_holder)" ] && { freed=1; break; }
  sleep 1
done
if [ "$freed" != 1 ]; then
  echo "Error: local port ${LOCAL_PORT} is in use — cannot port-forward Keycloak. Holding process:" >&2
  port_holder >&2 || true
  echo "  Free that port (or stop the process above), then re-run." >&2
  exit 1
fi

# 3. Start the forward, CAPTURING its output (never discard it — that hid the bind failure).
#    Trap cleans up both the process and the log on any exit path.
PF_LOG="$(mktemp "${TMPDIR:-/tmp}/keycloak-pf.XXXXXX")"
kubectl --context "$CONTEXT" port-forward -n keycloak svc/keycloak "${LOCAL_PORT}:8080" >"$PF_LOG" 2>&1 &
PF_PID=$!
# disown so the shell stops job-tracking it — the trap still kills the PID, but bash won't
# print a "Terminated: 15" job notice when it does. PID stays valid for kill/kill -0.
disown "$PF_PID" 2>/dev/null || true
trap 'kill "$PF_PID" 2>/dev/null || true; rm -f "$PF_LOG"' EXIT

# 4. Confirm the tunnel reaches Keycloak's OIDC endpoint. The pod is already Ready (step 1),
#    so this only covers tunnel establishment — 30s is ample. Bail early with the captured
#    output if the forward process dies, rather than polling a dead port.
echo "==> Confirming Keycloak is reachable through the port-forward ..."
ready=0
for _ in $(seq 1 30); do
  if ! kill -0 "$PF_PID" 2>/dev/null; then
    echo "Error: kubectl port-forward exited before Keycloak was reachable. Its output:" >&2
    cat "$PF_LOG" >&2
    exit 1
  fi
  if curl -sf -o /dev/null "${KEYCLOAK_URL}/realms/master/.well-known/openid-configuration"; then
    ready=1; break
  fi
  sleep 1
done
if [ "$ready" != 1 ]; then
  echo "Error: Keycloak not reachable on :${LOCAL_PORT} after 30s. port-forward output:" >&2
  cat "$PF_LOG" >&2
  exit 1
fi

# --- Admin token -------------------------------------------------------------------------
ADMIN_TOKEN="$(curl -s -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
  -d "username=admin" -d "password=admin" -d "grant_type=password" -d "client_id=admin-cli" \
  | jq -r '.access_token')"
[ -n "$ADMIN_TOKEN" ] && [ "$ADMIN_TOKEN" != "null" ] \
  || { echo "Error: could not obtain Keycloak admin token" >&2; exit 1; }

# Number of objects an admin-API GET returns (0 on none/parse failure) — drives create-or-skip.
count() { curl -s -H "Authorization: Bearer $ADMIN_TOKEN" "${KEYCLOAK_URL}$1" | jq 'length' 2>/dev/null || echo 0; }

# --- Realm (obo-realm) -------------------------------------------------------------------
realm_code="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $ADMIN_TOKEN" \
  "${KEYCLOAK_URL}/admin/realms/obo-realm")"
if [ "$realm_code" = "200" ]; then
  echo "    ✓ realm obo-realm already exists"
else
  curl -s -X POST "${KEYCLOAK_URL}/admin/realms" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" -H "Content-Type: application/json" \
    -d '{"realm":"obo-realm","enabled":true}'
  echo "    + created realm obo-realm"
fi

# --- Client (agw-client) -----------------------------------------------------------------
if [ "$(count "/admin/realms/obo-realm/clients?clientId=agw-client")" -gt 0 ]; then
  echo "    ✓ client agw-client already exists"
else
  curl -s -X POST "${KEYCLOAK_URL}/admin/realms/obo-realm/clients" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" -H "Content-Type: application/json" \
    -d '{
      "clientId": "agw-client",
      "enabled": true,
      "clientAuthenticatorType": "client-secret",
      "secret": "agw-client-secret",
      "directAccessGrantsEnabled": true,
      "serviceAccountsEnabled": false
    }'
  echo "    + created client agw-client"
fi

# --- User (testuser) ---------------------------------------------------------------------
if [ "$(count "/admin/realms/obo-realm/users?username=testuser&exact=true")" -gt 0 ]; then
  echo "    ✓ user testuser already exists"
else
  curl -s -X POST "${KEYCLOAK_URL}/admin/realms/obo-realm/users" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" -H "Content-Type: application/json" \
    -d '{
      "username": "testuser",
      "email": "testuser@example.com",
      "emailVerified": true,
      "firstName": "Test",
      "lastName": "User",
      "enabled": true,
      "requiredActions": [],
      "credentials": [{"type": "password", "value": "testuser", "temporary": false}]
    }'
  echo "    + created user testuser"
fi

echo "✓ Keycloak configured (realm=obo-realm, client=agw-client, user=testuser)"
