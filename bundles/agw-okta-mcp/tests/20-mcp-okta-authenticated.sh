#!/usr/bin/env bash
# End-to-end: fetch a REAL Okta access token via the client-credentials grant, then run an
# MCP handshake through the gateway's /mcp route carrying it. Reaching the tool list proves
# the Okta JWT was validated at the edge (iss/aud/signature against Okta's JWKS) — a raw or
# absent token 401s (see 10-). No STS/exchange here: the token comes straight from Okta.
#
# .env knobs (see .env.example):
#   OKTA_DOMAIN         required   Okta org host, no scheme (e.g. dev-1234567.okta.com)
#   OKTA_CLIENT_ID      required   the API Services (m2m) app's client id
#   OKTA_CLIENT_SECRET  required   that app's client secret
#   OKTA_SCOPE          required   a scope the app is granted on the default AS (e.g. mcp.access)
set -euo pipefail

: "${OKTA_DOMAIN:?set OKTA_DOMAIN in .env}"
: "${OKTA_CLIENT_ID:?set OKTA_CLIENT_ID in .env (your Okta API Services app)}"
: "${OKTA_CLIENT_SECRET:?set OKTA_CLIENT_SECRET in .env}"
: "${OKTA_SCOPE:?set OKTA_SCOPE in .env (a scope your app is granted on /oauth2/default, e.g. mcp.access)}"

TOKEN_URL="https://${OKTA_DOMAIN}/oauth2/default/v1/token"

# --- Client-credentials token from Okta's custom "default" authorization server ----------
# HTTP Basic auth (client_id:client_secret) is Okta's default token_endpoint_auth_method for
# an API Services app. The token's aud is api://default and iss is https://<domain>/oauth2/default
# — matching the policy from 50-okta-jwt.sh.
OKTA_JWT=$(curl -s -X POST "$TOKEN_URL" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -u "${OKTA_CLIENT_ID}:${OKTA_CLIENT_SECRET}" \
  -d "grant_type=client_credentials" \
  -d "scope=${OKTA_SCOPE}" | jq -r '.access_token')
[ -n "$OKTA_JWT" ] && [ "$OKTA_JWT" != "null" ] || {
  echo "✗ Okta token fetch failed — check OKTA_CLIENT_ID/SECRET/SCOPE and that the app is granted OKTA_SCOPE on the default AS" >&2
  exit 1; }
echo "✓ obtained client-credentials access token from Okta"

# --- MCP handshake through /mcp carrying the Okta token ----------------------------------
# Same uv-run + truststore approach as bundles/mcp-in-cluster (see that test for the why),
# plus an Authorization header so the JWT policy admits us.
if ! command -v uv >/dev/null 2>&1; then
  echo "✗ uv not found — install it:  brew install uv   (or re-run: solomog setup)" >&2
  exit 1
fi

OKTA_JWT="$OKTA_JWT" uv run --with mcp --with truststore --python 3.12 - <<'PY'
import truststore; truststore.inject_into_ssl()   # trust the OS keychain (mkcert CA) for TLS
import os, sys, asyncio
from mcp.client.streamable_http import streamablehttp_client
from mcp import ClientSession

host = os.environ["HOST"]
headers = {"Authorization": "Bearer " + os.environ["OKTA_JWT"]}

async def main():
    try:
        async with streamablehttp_client("https://" + host + "/mcp", headers=headers) as (read, write, _):
            async with ClientSession(read, write) as session:
                await session.initialize()
                tools = await session.list_tools()
                print(f"✓ Okta-authenticated MCP — {len(tools.tools)} tool(s) found")
                for tool in tools.tools:
                    desc = (tool.description or "").strip().splitlines()
                    desc = desc[0] if desc else ""
                    print(f"  - {tool.name}: {desc}" if desc else f"  - {tool.name}")
                return 0
    except BaseException as e:
        # The SDK runs I/O in an asyncio TaskGroup that re-raises as an ExceptionGroup hiding
        # the real cause — unwrap nested .exceptions so the actual error (401, TLS, protocol)
        # is visible.
        def unwrap(exc, depth=0):
            print(f"✗ FAIL: {'  ' * depth}{type(exc).__name__}: {exc}", file=sys.stderr)
            for sub in getattr(exc, "exceptions", []):
                unwrap(sub, depth + 1)
        unwrap(e)
        return 1

sys.exit(asyncio.run(main()))
PY
