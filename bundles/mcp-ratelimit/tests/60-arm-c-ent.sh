#!/usr/bin/env bash
# ARM C: the enterprise entRateLimit ceiling on /mcp-ent.
#
# Two claims: it DOES enforce (so it is a real option for a distributed ceiling), and it is
# TOOL-BLIND -- different tools share one budget. The second is the reason per-tool limiting
# cannot be built on this path, and is the thing most likely to be assumed otherwise.
set -uo pipefail
. "$(dirname "$0")/../helpers/lib-mcp.sh"
mcp_require_host || exit 1
LIMIT=5

drain() {
  local sid="$1" i code
  ALLOWED=0; LIMITED=0; DENIAL=""
  for i in $(seq 1 7); do
    code=$(mcp_call /mcp-ent "$sid" $((400+i)) echo '{"message":"e"}')
    if mcp_is_limited "$code"; then
      LIMITED=$((LIMITED+1)); [ -z "$DENIAL" ] && DENIAL="$code"
    else
      ALLOWED=$((ALLOWED+1))
    fi
  done
}

sid=$(mcp_init /mcp-ent) || { echo "FAIL arm C: MCP handshake failed"; exit 1; }
drain "$sid"
if [ $ALLOWED -eq 0 ]; then
  mcp_wait_next_window
  sid=$(mcp_init /mcp-ent) || { echo "FAIL arm C: MCP handshake failed"; exit 1; }
  drain "$sid"
fi

echo "== arm C: entRateLimit ceiling on /mcp-ent (limit ${LIMIT}/min) =="
echo "   echo: allowed ${ALLOWED}, blocked ${LIMITED}"
echo "   denial shape: $(mcp_denial_shape "$DENIAL")"

fail=0
if [ $LIMITED -lt 1 ]; then
  echo "   ✗ nothing was blocked. Check the RateLimitConfig resolved:"
  echo "     kubectl get ratelimitconfig -n agentgateway-system mcp-ent-ceiling -o yaml"
  fail=1
else
  echo "   ✓ the ceiling is enforced"
fi

# Tool-blindness: a DIFFERENT tool, on the budget echo just exhausted.
code=$(mcp_call /mcp-ent "$sid" 499 get-sum '{"a":1,"b":2}')
if mcp_is_limited "$code"; then
  echo "   ✓ get-sum is blocked too -- one budget for the whole route, no tool awareness"
else
  echo "   ✗ get-sum succeeded on an exhausted budget. That would mean entRateLimit is"
  echo "     discriminating by tool, which this path has no mechanism to do -- re-check"
  echo "     whether some other policy is attached to the mcp-ent route."
  fail=1
fi

[ $fail -eq 0 ] && echo "PASS arm C" || echo "FAIL arm C"
exit $fail
