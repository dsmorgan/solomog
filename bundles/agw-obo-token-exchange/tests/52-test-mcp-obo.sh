#!/usr/bin/env bash
# End-to-end OBO-authenticated MCP: get a user JWT from Keycloak, exchange it at the STS for
# an OBO token, then run a real MCP handshake through the gateway's /obo/mcp route carrying
# that token. Proves the tool side of the OBO story — the same delegated token that unlocks
# /obo/openai also unlocks the MCP tools, and (via 12-obo-mcp-401.sh) nothing else does.
#
# Token exchange here is impersonation (subject=user JWT, no actor_token), matching
# 50-test-impersonation.sh — simpler than the pod-based delegation flow and enough to prove
# the JWT policy accepts an STS-issued token on the MCP route.
set -euo pipefail

KEYCLOAK_URL="http://localhost:8080"
STS_URL="http://localhost:7777"

# --- Port-forward Keycloak (:8080) and the STS (:7777), cleaned up on any exit ------------
pkill -f "port-forward.*keycloak.*8080" 2>/dev/null || true
kubectl --context "$CONTEXT" port-forward -n keycloak svc/keycloak 8080:8080 >/dev/null 2>&1 &
PF_PID=$!
pkill -f "port-forward.*7777" 2>/dev/null || true
kubectl --context "$CONTEXT" port-forward -n agentgateway-system svc/enterprise-agentgateway 7777:7777 >/dev/null 2>&1 &
PF2_PID=$!
trap 'kill "$PF_PID" "$PF2_PID" 2>/dev/null || true' EXIT

ready=0
for _ in $(seq 1 20); do
  curl -sf -o /dev/null "${KEYCLOAK_URL}/realms/master" && { ready=1; break; }
  sleep 1
done
[ "$ready" -eq 1 ] || { echo "✗ Keycloak not reachable on :8080 after 20s" >&2; exit 1; }
ready=0
for _ in $(seq 1 20); do
  curl -sf -o /dev/null "${STS_URL}/.well-known/jwks.json" && { ready=1; break; }
  sleep 1
done
[ "$ready" -eq 1 ] || { echo "✗ Agentgateway STS not reachable on :7777 after 20s" >&2; exit 1; }

# --- User JWT, then exchange for an OBO token --------------------------------------------
USER_JWT=$(curl -s -X POST "${KEYCLOAK_URL}/realms/obo-realm/protocol/openid-connect/token" \
  -d "username=testuser" -d "password=testuser" -d "grant_type=password" \
  -d "client_id=agw-client" -d "client_secret=agw-client-secret" | jq -r '.access_token')
[ -n "$USER_JWT" ] && [ "$USER_JWT" != "null" ] || { echo "✗ USER_JWT is empty — token fetch failed" >&2; exit 1; }

OBO_JWT=$(curl -s -X POST "${STS_URL}/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "Authorization: Bearer ${USER_JWT}" \
  -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
  -d "subject_token=${USER_JWT}" \
  -d "subject_token_type=urn:ietf:params:oauth:token-type:jwt" | jq -r '.access_token')
[ -n "$OBO_JWT" ] && [ "$OBO_JWT" != "null" ] || { echo "✗ OBO exchange failed — no access_token" >&2; exit 1; }
echo "✓ obtained OBO token from STS"

# --- MCP handshake through /obo/mcp carrying the OBO token -------------------------------
# Same uv-run + truststore approach as bundles/mcp-in-cluster (see that test for the why),
# but with an Authorization header so the route's JWT policy admits us. Reaching the tool
# list at all means the OBO token was accepted — a raw/absent token would 401 (see 12-).
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
                print(f"✓ OBO-authenticated MCP — {len(tools.tools)} tool(s) found")
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
