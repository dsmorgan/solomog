#!/usr/bin/env bash
set -euo pipefail

KEYCLOAK_URL="http://localhost:8080"
NAMESPACE=agentgateway-system

# --- Port-forward Keycloak ---------------------------------------------------------------
pkill -f "port-forward.*keycloak.*8080" 2>/dev/null || true
kubectl --context "$CONTEXT" port-forward -n keycloak svc/keycloak 8080:8080 >/dev/null 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT

ready=0
for _ in $(seq 1 20); do
  curl -sf -o /dev/null "${KEYCLOAK_URL}/realms/master" && { ready=1; break; }
  sleep 1
done
[ "$ready" -eq 1 ] || { echo "✗ Keycloak not reachable on :8080 after 20s" >&2; exit 1; }

# --- Get fresh user JWT (must include may_act from 84-del-configure-keycloak-mayact.sh) --
USER_JWT=$(curl -s -X POST "${KEYCLOAK_URL}/realms/obo-realm/protocol/openid-connect/token" \
  -d "username=testuser" -d "password=testuser" -d "grant_type=password" \
  -d "client_id=agw-client" -d "client_secret=agw-client-secret" | jq -r '.access_token')
[ -n "$USER_JWT" ] || { echo "✗ USER_JWT is empty — token fetch failed" >&2; exit 1; }

_seg=$(echo "$USER_JWT" | cut -d. -f2 | tr '_-' '/+')
while [ $(( ${#_seg} % 4 )) -ne 0 ]; do _seg="${_seg}="; done
MAY_ACT=$(echo "$_seg" | base64 -d 2>/dev/null | jq -r '.may_act // empty')
[ -n "$MAY_ACT" ] || { echo "✗ may_act claim missing from user JWT — apply 84-del-configure-keycloak-mayact.sh first" >&2; exit 1; }
echo "✓ may_act present in user JWT: $MAY_ACT"

# --- Delegation token exchange from inside the agent pod ---------------------------------
# The pod's mounted service account token is the actor_token. No port-forward to the STS
# is needed — the pod reaches it directly via in-cluster DNS.
#STS_RESPONSE=$(kubectl --context "$CONTEXT" exec obo-agent-test -n "$NAMESPACE" -- /bin/sh -c "
STS_RESPONSE=$(kubectl --context "$CONTEXT" exec deploy/obo-agent-test -n "$NAMESPACE" -- /bin/sh -c "
  K8S_SA_TOKEN=\$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
  curl -s -X POST http://enterprise-agentgateway.agentgateway-system.svc.cluster.local:7777/token \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d 'grant_type=urn:ietf:params:oauth:grant-type:token-exchange' \
    -d 'subject_token=$USER_JWT' \
    -d 'subject_token_type=urn:ietf:params:oauth:token-type:jwt' \
    -d \"actor_token=\$K8S_SA_TOKEN\" \
    -d 'actor_token_type=urn:ietf:params:oauth:token-type:jwt'
")
echo "$STS_RESPONSE" | jq '.'

DELEGATED_JWT=$(echo "$STS_RESPONSE" | jq -r '.access_token')
[ -n "$DELEGATED_JWT" ] || { echo "✗ DELEGATED_JWT is empty — token exchange failed" >&2; exit 1; }

# Verify both sub (user) and act (agent) are present in the delegated token
_seg=$(echo "$DELEGATED_JWT" | cut -d. -f2 | tr '_-' '/+')
while [ $(( ${#_seg} % 4 )) -ne 0 ]; do _seg="${_seg}="; done
echo "$_seg" | base64 -d 2>/dev/null | jq '{iss, sub, act}'

ACT=$(echo "$_seg" | base64 -d 2>/dev/null | jq -r '.act // empty')
[ -n "$ACT" ] || { echo "✗ act claim missing from delegated JWT" >&2; exit 1; }
echo "✓ delegated JWT has act claim — delegation confirmed"


echo
echo "Now the end-to-end test to use an OBO JWT (Delegation)..."
# --- Call the protected LLM route with the delegated token -------------------------------
curl -is --fail-with-body "https://${HOST}/obo/openai" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $DELEGATED_JWT" \
  -d '{"model": "mock-gpt-4o", "messages": [{"role": "user", "content": "Hello"}]}'

# --- Call the protected MCP route with the SAME delegated token --------------------------
# This is the workshop's core claim (obo-crewai-agent-with-mcp): one act-carrying delegated
# token unlocks BOTH the LLM route and the MCP tools. Reaching the tool list proves the MCP
# JWT policy accepts the delegated (sub=user, act=agent) token — not just any STS token.
# Same uv-run + truststore approach as bundles/mcp-in-cluster (see that test for the why).
echo
echo "...and the SAME delegated token against the MCP route (/obo/mcp)..."
if ! command -v uv >/dev/null 2>&1; then
  echo "✗ uv not found — install it:  brew install uv   (or re-run: solomog setup)" >&2
  exit 1
fi

OBO_JWT="$DELEGATED_JWT" uv run --with mcp --with truststore --python 3.12 - <<'PY'
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
                print(f"✓ delegated token accepted on MCP route — {len(tools.tools)} tool(s) found")
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
