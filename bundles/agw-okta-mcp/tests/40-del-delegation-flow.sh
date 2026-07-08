#!/usr/bin/env bash
# Full DELEGATION flow (sub=user AND act=agent), the close-out of the OBO story:
#   1. cached Okta user token must carry may_act authorizing the obo-agent SA
#      (added as an Okta claim — see README "Delegation"; re-login after adding it);
#   2. from inside the agent pod, use its mounted SA token as actor_token and exchange
#      user-token + actor-token at the STS for a DELEGATED token;
#   3. that token has both sub (the user) and act (the agent);
#   4. it's accepted on /obo/mcp — the tool now sees the full delegation chain.
# Mirrors agw-obo-token-exchange/tests/85 but the subject is a real Okta user token and the
# may_act is emitted by Okta (object-literal claim), not a Keycloak protocol mapper.
set -euo pipefail
NS=agentgateway-system
CACHE="$(cd "$(dirname "$0")/../../.." && pwd)/.solomog/okta-user-token.json"
dec() { local p; p=$(echo "$1" | cut -d. -f2 | tr '_-' '/+'); while [ $(( ${#p} % 4 )) -ne 0 ]; do p="${p}="; done; echo "$p" | base64 -d 2>/dev/null; }

[ -f "$CACHE" ] || { echo "✗ no cached user token — run: bash bundles/agw-okta-mcp/helpers/okta-pkce-login.sh" >&2; exit 1; }
USER_JWT=$(jq -r '.access_token' "$CACHE")
[ -n "$USER_JWT" ] && [ "$USER_JWT" != "null" ] || { echo "✗ cached token unreadable — re-run the login helper" >&2; exit 1; }

# --- may_act must be present (else the STS rejects delegation) ---------------------------
# KNOWN OKTA LIMITATION (see README "Delegation"): Okta RESERVES may_act for its own native
# token-exchange, so it can't be emitted as a custom claim — native Okta delegation isn't
# possible. Impersonation (test 32) is the working Okta OBO mode. So if may_act is absent we
# SKIP (exit 0) rather than fail; the full delegation proof below runs only if may_act was
# injected another way (Token Inline Hook / ext-auth shim).
MAY_ACT=$(dec "$USER_JWT" | jq -c '.may_act // empty')
if [ -z "$MAY_ACT" ]; then
  echo "⊘ SKIP: user token has no may_act claim — Okta reserves it, so native delegation is"
  echo "  blocked (documented limitation; impersonation/test 32 is the working Okta OBO mode)."
  echo "  This test validates delegation end-to-end only when may_act is present (inline hook / ext-auth)."
  exit 0
fi
echo "✓ may_act present in user token: $MAY_ACT"

# --- agent pod must be ready (its SA token is the actor) ---------------------------------
kubectl --context "$CONTEXT" rollout status deploy/obo-agent-test -n "$NS" --timeout=60s >/dev/null 2>&1 \
  || { echo "✗ obo-agent-test not ready — apply the bundle first" >&2; exit 1; }

# --- Delegation exchange from INSIDE the agent pod (in-cluster, no port-forward) ---------
STS_RESPONSE=$(kubectl --context "$CONTEXT" exec deploy/obo-agent-test -n "$NS" -- /bin/sh -c "
  ACTOR=\$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
  curl -s -X POST http://enterprise-agentgateway.agentgateway-system.svc.cluster.local:7777/token \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d 'grant_type=urn:ietf:params:oauth:grant-type:token-exchange' \
    -d 'subject_token=$USER_JWT' \
    -d 'subject_token_type=urn:ietf:params:oauth:token-type:jwt' \
    -d \"actor_token=\$ACTOR\" \
    -d 'actor_token_type=urn:ietf:params:oauth:token-type:jwt'
")
DEL_JWT=$(echo "$STS_RESPONSE" | jq -r '.access_token // empty')
[ -n "$DEL_JWT" ] || { echo "✗ delegation exchange failed:"; echo "$STS_RESPONSE" | jq . 2>/dev/null || echo "$STS_RESPONSE"; exit 1; }

# --- Both identities present: sub (user) + act (agent) -----------------------------------
echo "delegated token identity:"; dec "$DEL_JWT" | jq '{iss, sub, act}'
ACT=$(dec "$DEL_JWT" | jq -r '.act.sub // .act // empty')
SUB=$(dec "$DEL_JWT" | jq -r '.sub // empty')
[ -n "$ACT" ] || { echo "✗ act claim missing from delegated token" >&2; exit 1; }
echo "✓ delegation confirmed — sub=${SUB} (user), act=${ACT} (agent)"

# --- The delegated token is accepted on /obo/mcp -----------------------------------------
if ! command -v uv >/dev/null 2>&1; then
  echo "✗ uv not found — install it:  brew install uv   (or re-run: solomog setup)" >&2
  exit 1
fi
OBO_JWT="$DEL_JWT" uv run --with mcp --with truststore --python 3.12 - <<'PY'
import truststore; truststore.inject_into_ssl()
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
                print(f"✓ delegated (sub=user, act=agent) token accepted on /obo/mcp — {len(tools.tools)} tool(s)")
                for tool in tools.tools:
                    desc = (tool.description or "").strip().splitlines()
                    print(f"  - {tool.name}: {desc[0]}" if desc else f"  - {tool.name}")
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
