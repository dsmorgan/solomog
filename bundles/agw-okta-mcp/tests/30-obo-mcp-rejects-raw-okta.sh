#!/usr/bin/env bash
# /obo/mcp must reject a RAW Okta user token (only STS-issued OBO tokens are accepted there).
# This is the negative proof for the OBO leg — it's what makes the exchange meaningful: the
# tool route trusts the STS, not Okta directly. Uses the cached user token from the PKCE login.
set -euo pipefail
CACHE="$(cd "$(dirname "$0")/../../.." && pwd)/.solomog/okta-user-token.json"
[ -f "$CACHE" ] || { echo "✗ no cached user token — run: bash bundles/agw-okta-mcp/helpers/okta-pkce-login.sh" >&2; exit 1; }
USER_JWT=$(jq -r '.access_token' "$CACHE")
[ -n "$USER_JWT" ] && [ "$USER_JWT" != "null" ] || { echo "✗ cached token unreadable — re-run the login helper" >&2; exit 1; }

status=$(curl -sk -o /dev/null -w "%{http_code}" -X POST "https://${HOST}/obo/mcp" \
  -H "Authorization: Bearer ${USER_JWT}" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')
[ "$status" -eq 401 ] || { echo "expected 401 (raw Okta token on /obo/mcp), got $status"; exit 1; }
echo "✓ /obo/mcp rejects a raw Okta token (401) — only STS-issued tokens accepted"
