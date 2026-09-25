#!/usr/bin/env bash
# Print the FINAL (Cross App Access minted) access token for one agent: the token that comes out the
# far end of both legs.
#
# Usage:  bash helpers/xaa-final-token.sh priorauth|intake        (HOST must be set)
#
# Curls the agent's probe route with the reviewer's cached Okta ID token. The route runs both legs and
# attaches the minted token upstream to go-httpbin, which echoes it back. Tests use this so the token
# they present at /claims-tools is one the GATEWAY minted, never one the test forged.
set -euo pipefail

ROLE="${1:?usage: xaa-final-token.sh priorauth|intake}"
: "${HOST:?HOST must be set (exported by solomog test / apply)}"
case "$ROLE" in priorauth) L=a ;; intake) L=b ;; *) echo "✗ role must be priorauth or intake" >&2; exit 1 ;; esac

HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE=$(bash "$HELPER_DIR/xaa-token-path.sh" "$L") || {
  echo "✗ no cached ID token — run:  bash bundles/agent-audit-evidence/helpers/xaa-login.sh" >&2; exit 1; }
ID_TOKEN=$(jq -r '.id_token' "$CACHE")
[ -n "$ID_TOKEN" ] && [ "$ID_TOKEN" != "null" ] || { echo "✗ cached ID token unreadable — re-run xaa-login.sh" >&2; exit 1; }

BODY=$(curl -sS -w '\n%{http_code}' "https://${HOST}/probe/${ROLE}" -H "Authorization: Bearer ${ID_TOKEN}")
STATUS=$(printf '%s' "$BODY" | tail -n1)
BODY=$(printf '%s' "$BODY" | sed '$d')
if [ "$STATUS" -ge 400 ] 2>/dev/null; then
  {
    echo "✗ /probe/${ROLE} returned HTTP ${STATUS}. Both Cross App Access legs run on that route. Body:"
    printf '%s\n' "${BODY:-<empty>}"
    echo "  401 + ExpiredSignature: the ID token aged out — re-run helpers/xaa-login.sh."
    echo "  Otherwise tests/08 asks Okta directly, and the resource AS logs leg 2:"
    echo "    kubectl --context \"\$CONTEXT\" -n agent-evidence logs deploy/evidence-resource-as --tail=50"
  } >&2
  exit 1
fi

TOKEN=$(printf '%s' "$BODY" | jq -r '
  .headers.Authorization // .headers.authorization
  | if type == "array" then .[0] else . end
  | sub("^[Bb]earer +"; "")')
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || {
  echo "✗ /probe/${ROLE} echoed no Authorization header: the exchange did not complete. Body:" >&2
  printf '%s\n' "$BODY" >&2; exit 1; }
printf '%s\n' "$TOKEN"
