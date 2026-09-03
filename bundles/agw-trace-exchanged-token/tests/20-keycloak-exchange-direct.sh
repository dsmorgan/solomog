#!/usr/bin/env bash
# Control: Keycloak itself performs the RFC 8693 exchange, with the gateway out of the picture.
# If this fails the authorization server is misconfigured and no gateway result below means
# anything -- so it runs before any gateway assertion.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LOCAL_PORT=8083
REALM=exchange-realm

SUBJECT="$(bash "$HERE/../helpers/get-token.sh")"
SECRET="$(kubectl --context "$CONTEXT" get secret exchange-client-secret -n agentgateway-system \
  -o jsonpath='{.data.clientSecret}' | base64 --decode)"

pkill -f "port-forward.*keycloak.*${LOCAL_PORT}" 2>/dev/null || true; sleep 1
kubectl --context "$CONTEXT" port-forward -n keycloak svc/keycloak "${LOCAL_PORT}:8080" >/dev/null 2>&1 &
PF=$!; disown "$PF" 2>/dev/null || true
trap 'kill "$PF" 2>/dev/null || true' EXIT
for _ in $(seq 1 20); do curl -sf -o /dev/null "http://localhost:${LOCAL_PORT}/realms/${REALM}/.well-known/openid-configuration" && break; sleep 1; done

resp="$(curl -s -X POST "http://localhost:${LOCAL_PORT}/realms/${REALM}/protocol/openid-connect/token" \
  -d 'grant_type=urn:ietf:params:oauth:grant-type:token-exchange' \
  -d 'subject_token_type=urn:ietf:params:oauth:token-type:access_token' \
  --data-urlencode "subject_token=${SUBJECT}" \
  -d 'client_id=exchange-client' --data-urlencode "client_secret=${SECRET}")"

tok="$(printf '%s' "$resp" | jq -r '.access_token // empty')"
if [ -z "$tok" ]; then
  echo "✗ Keycloak refused the exchange: $(printf '%s' "$resp" | head -c 300)" >&2
  echo "  'unsupported_grant_type' or 'not allowed' means Standard Token Exchange is off for" >&2
  echo "  exchange-client. Re-apply the bundle; the hook sets standard.token.exchange.enabled." >&2
  exit 1
fi

azp="$(printf '%s' "$tok" | cut -d. -f2 | { p=$(cat); printf '%s' "$p$(printf '%*s' $(( (4-${#p}%4)%4 )) '' | tr ' ' '=')"; } | tr '_-' '/+' | base64 --decode 2>/dev/null | jq -r '.azp // "-"')"
[ "$azp" = "exchange-client" ] || { echo "✗ exchanged token azp=$azp, expected exchange-client" >&2; exit 1; }
echo "✓ Keycloak performs RFC 8693 exchange (azp=$azp)"
