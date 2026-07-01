# Add a hardcoded may_act protocol mapper to the agw-client Keycloak client.
# This embeds a may_act claim in every user JWT, identifying the obo-agent service
# account as the authorized actor for the delegation flow (Part B).
#
# Idempotent: deletes and recreates the mapper so re-applying the bundle is safe
# (the obo-agent SA identity is stable, so the value is always the same).
# CONTEXT is exported by apply-bundle.sh.
set -euo pipefail

KEYCLOAK_URL="http://localhost:8080"
NAMESPACE=agentgateway-system
SA=obo-agent

pkill -f "port-forward.*keycloak.*8080" 2>/dev/null || true
kubectl --context "$CONTEXT" port-forward -n keycloak svc/keycloak 8080:8080 >/dev/null 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT

echo "==> Waiting for Keycloak on ${KEYCLOAK_URL} ..."
ready=0
for _ in $(seq 1 60); do
  if curl -sf -o /dev/null "${KEYCLOAK_URL}/realms/master/.well-known/openid-configuration"; then
    ready=1; break
  fi
  sleep 1
done
[ "$ready" = 1 ] || { echo "Error: Keycloak not reachable on :8080 after 60s" >&2; exit 1; }

# Get the obo-agent service account identity from a short-lived token
ACTOR_TOKEN=$(kubectl --context "$CONTEXT" create token "$SA" -n "$NAMESPACE" --duration=600s)
_pl=$(echo "$ACTOR_TOKEN" | cut -d. -f2 | tr '_-' '/+')
while [ $(( ${#_pl} % 4 )) -ne 0 ]; do _pl="${_pl}="; done
_pl=$(echo "$_pl" | base64 -d 2>/dev/null)
MAY_ACT_SUB=$(echo "$_pl" | jq -r '.sub')
MAY_ACT_ISS=$(echo "$_pl" | jq -r '.iss')
echo "==> obo-agent identity: sub=${MAY_ACT_SUB}"

ADMIN_TOKEN=$(curl -s -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
  -d "username=admin" -d "password=admin" -d "grant_type=password" -d "client_id=admin-cli" \
  | jq -r '.access_token')
[ -n "$ADMIN_TOKEN" ] && [ "$ADMIN_TOKEN" != "null" ] \
  || { echo "Error: could not obtain Keycloak admin token" >&2; exit 1; }

CLIENT_UUID=$(curl -s "${KEYCLOAK_URL}/admin/realms/obo-realm/clients?clientId=agw-client" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" | jq -r '.[0].id')
[ -n "$CLIENT_UUID" ] && [ "$CLIENT_UUID" != "null" ] \
  || { echo "Error: agw-client not found — run 13-configure-keycloak.sh first" >&2; exit 1; }

# Delete existing may-act mapper if present (idempotent replace)
MAPPER_ID=$(curl -s "${KEYCLOAK_URL}/admin/realms/obo-realm/clients/${CLIENT_UUID}/protocol-mappers/models" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" | jq -r '.[] | select(.name == "may-act") | .id // empty')
if [ -n "$MAPPER_ID" ]; then
  curl -s -X DELETE \
    "${KEYCLOAK_URL}/admin/realms/obo-realm/clients/${CLIENT_UUID}/protocol-mappers/models/${MAPPER_ID}" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}"
  echo "    ~ removed existing may-act mapper"
fi

MAY_ACT_JSON=$(jq -nc --arg sub "$MAY_ACT_SUB" --arg iss "$MAY_ACT_ISS" '{sub: $sub, iss: $iss}')
MAPPER_JSON=$(jq -n \
  --arg claim_name "may_act" \
  --arg claim_value "$MAY_ACT_JSON" \
  '{
    name: "may-act",
    protocol: "openid-connect",
    protocolMapper: "oidc-hardcoded-claim-mapper",
    config: {
      "claim.name": $claim_name,
      "claim.value": $claim_value,
      "jsonType.label": "JSON",
      "access.token.claim": "true",
      "id.token.claim": "false"
    }
  }')

curl -s -X POST \
  "${KEYCLOAK_URL}/admin/realms/obo-realm/clients/${CLIENT_UUID}/protocol-mappers/models" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$MAPPER_JSON"

echo "✓ may_act mapper added (actor=${MAY_ACT_SUB})"
