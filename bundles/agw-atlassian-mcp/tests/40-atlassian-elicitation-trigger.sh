#!/usr/bin/env bash
# With a VALID Okta JWT (auth passes) but no Atlassian token elicited yet, the MCP initialize call
# should return the documented elicitation-trigger shape from Solo's validated reference
# (agentgateway-enterprise/dev-docs/tokenexchange/elicitation/test-elicitation-guide-mcp.md Step 1):
# a JSON-RPC error whose message embeds a TokenExchangeInfo with a "url" field — NOT a 401, NOT a
# direct provider authorize URL (that shape is the eager-auth agent-flow, which this bundle
# deliberately does not use — see 50-atlassian.sh). Proves the frontend/backend split is correct;
# it does NOT complete the elicitation (that needs the Solo UI — see ATLASSIAN-SETUP.md).
#
# Prereq: a cached Okta user token (bash ../agw-okta-mcp/helpers/okta-pkce-login.sh).
set -euo pipefail
CACHE="$(cd "$(dirname "$0")/../../.." && pwd)/.solomog/okta-user-token.json"
[ -f "$CACHE" ] || { echo "✗ no cached user token — run: bash bundles/agw-okta-mcp/helpers/okta-pkce-login.sh" >&2; exit 1; }
USER_JWT=$(jq -r '.access_token' "$CACHE")
[ -n "$USER_JWT" ] && [ "$USER_JWT" != "null" ] || { echo "✗ cached token unreadable — re-run the login helper" >&2; exit 1; }

resp=$(curl -sk -X POST "https://${HOST}/atlassian/mcp" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${USER_JWT}" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"solomog-test","version":"1.0"}}}')
echo "$resp"
case "$resp" in
  *"token not available in STS"*"TokenExchangeInfo"*) echo "✓ elicitation triggered (auth passed, upstream token exchange required)";;
  *"401"*|*"unauthorized"*) echo "got 401/unauthorized — check the cached token isn't expired (re-run the login helper)"; exit 1;;
  *) echo "unexpected response shape — see above"; exit 1;;
esac
