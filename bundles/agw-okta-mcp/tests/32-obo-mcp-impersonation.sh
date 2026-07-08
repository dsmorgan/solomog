#!/usr/bin/env bash
# The OBO identity-propagation proof: take the cached Okta USER token, exchange it at the
# agentgateway STS for an OBO token (impersonation — subject only, no actor), then run a real
# MCP handshake through /obo/mcp carrying that token. Reaching the tool list proves:
#   1. the STS validated the user's Okta identity (against Okta's JWKS), and
#   2. the re-minted STS token is what the tool route trusts (a raw Okta token 401s — see 30).
# Mirrors agw-obo-token-exchange/tests/52 but the subject token is a real Okta user token
# (from Auth Code + PKCE), not a Keycloak password-grant token.
#
# Prereqs: STS enabled (controller installed TOKEN_EXCHANGE=true, JWKS→Okta) and a cached
# user token (run helpers/okta-pkce-login.sh first).
set -euo pipefail
STS_URL="http://localhost:7777"
CACHE="$(cd "$(dirname "$0")/../../.." && pwd)/.solomog/okta-user-token.json"
[ -f "$CACHE" ] || { echo "✗ no cached user token — run: bash bundles/agw-okta-mcp/helpers/okta-pkce-login.sh" >&2; exit 1; }
USER_JWT=$(jq -r '.access_token' "$CACHE")
[ -n "$USER_JWT" ] && [ "$USER_JWT" != "null" ] || { echo "✗ cached token unreadable — re-run the login helper" >&2; exit 1; }

# --- Port-forward the STS (:7777), cleaned up on any exit --------------------------------
pkill -f "port-forward.*7777" 2>/dev/null || true
kubectl --context "$CONTEXT" port-forward -n agentgateway-system svc/enterprise-agentgateway 7777:7777 >/dev/null 2>&1 &
PF=$!
trap 'kill "$PF" 2>/dev/null || true' EXIT
ready=0
for _ in $(seq 1 20); do
  curl -sf -o /dev/null "${STS_URL}/.well-known/jwks.json" && { ready=1; break; }
  sleep 1
done
[ "$ready" -eq 1 ] || { echo "✗ STS not reachable on :7777 — is the controller installed with TOKEN_EXCHANGE=true?" >&2; exit 1; }

# --- Exchange the Okta user token for an OBO token (RFC 8693 token-exchange) --------------
OBO_JWT=$(curl -s -X POST "${STS_URL}/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "Authorization: Bearer ${USER_JWT}" \
  -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
  -d "subject_token=${USER_JWT}" \
  -d "subject_token_type=urn:ietf:params:oauth:token-type:jwt" | jq -r '.access_token')
[ -n "$OBO_JWT" ] && [ "$OBO_JWT" != "null" ] || {
  echo "✗ STS exchange failed — no access_token (check the subject token isn't expired: re-run the login helper)" >&2
  exit 1; }
echo "✓ exchanged Okta user token → OBO token at the STS"

# --- MCP handshake through /obo/mcp carrying the OBO token -------------------------------
if ! command -v uv >/dev/null 2>&1; then
  echo "✗ uv not found — install it:  brew install uv   (or re-run: solomog setup)" >&2
  exit 1
fi
OBO_JWT="$OBO_JWT" uv run --with mcp --with truststore --python 3.12 - <<'PY'
import truststore; truststore.inject_into_ssl()   # trust the OS keychain (mkcert CA) for TLS
import os, sys, asyncio
from mcp.client.streamable_http import streamablehttp_client
from mcp import ClientSession

host = os.environ["HOST"]
headers = {"Authorization": "Bearer " + os.environ["OBO_JWT"]}

async def main():
    try:
        async with streamablehttp_client("https://" + host + "/obo/mcp", headers=headers) as (read, write, _):
            async with ClientSession(read, write) as session:
                await session.initialize()
                tools = await session.list_tools()
                print(f"✓ OBO-authenticated MCP (as the Okta user) — {len(tools.tools)} tool(s) found")
                for tool in tools.tools:
                    desc = (tool.description or "").strip().splitlines()
                    desc = desc[0] if desc else ""
                    print(f"  - {tool.name}: {desc}" if desc else f"  - {tool.name}")
                return 0
    except BaseException as e:
        def unwrap(exc, depth=0):
            print(f"✗ FAIL: {'  ' * depth}{type(exc).__name__}: {exc}", file=sys.stderr)
            for sub in getattr(exc, "exceptions", []):
                unwrap(sub, depth + 1)
        unwrap(e)
        return 1

sys.exit(asyncio.run(main()))
PY
