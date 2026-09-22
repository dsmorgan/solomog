#!/usr/bin/env bash
# ARM A: the in-process token bucket on /mcp-local, 5 requests/minute.
#
# The claim under test is not merely "it blocks" but "it counts EVERY MCP request", which is the
# sizing trap: the handshake spends budget, so a 5/min limit does not mean five tool calls.
set -uo pipefail
. "$(dirname "$0")/../helpers/lib-mcp.sh"
mcp_require_host || exit 1
LIMIT=5

run_round() {
  local sid allowed=0 limited=0 code i first_code
  sid=$(mcp_init /mcp-local) || return 2      # the handshake is request 1 of LIMIT
  first_code=$(mcp_call /mcp-local "$sid" 10 echo '{"message":"a"}')
  if mcp_is_limited "$first_code"; then
    echo "   budget already spent this window"
    return 3
  fi
  allowed=1
  for i in $(seq 2 8); do
    code=$(mcp_call /mcp-local "$sid" $((10+i)) echo '{"message":"a"}')
    if mcp_is_limited "$code"; then
      limited=$((limited+1))
      [ $limited -eq 1 ] && DENIAL="$code"
    else
      allowed=$((allowed+1))
    fi
  done
  ALLOWED=$allowed; LIMITED=$limited
  return 0
}

DENIAL=""; ALLOWED=0; LIMITED=0
run_round; rc=$?
if [ $rc -eq 3 ]; then
  mcp_wait_next_window
  run_round; rc=$?
fi
[ $rc -eq 2 ] && { echo "FAIL arm A: MCP handshake failed"; exit 1; }
[ $rc -ne 0 ] && { echo "FAIL arm A: could not get a clean window"; exit 1; }

echo "== arm A: local bucket on /mcp-local (limit ${LIMIT}/min) =="
echo "   allowed ${ALLOWED} tool calls, blocked ${LIMITED}"
echo "   denial shape: $(mcp_denial_shape "$DENIAL")"

fail=0
if [ $LIMITED -lt 1 ]; then
  echo "   ✗ nothing was blocked -- the local limit is not being enforced"
  echo "     check: policy mcp-local-ratelimit targets HTTPRoute mcp-local, and the gateway"
  echo "     has a single replica (the bucket is per process, so N replicas give N x the limit)."
  fail=1
else
  echo "   ✓ the limit is enforced"
fi

# initialize consumed one slot, so the tool calls allowed must be strictly fewer than LIMIT.
if [ $ALLOWED -ge $LIMIT ]; then
  echo "   ✗ ${ALLOWED} tool calls got through on a ${LIMIT}/min limit -- the handshake was"
  echo "     apparently NOT counted, which contradicts how this arm is documented"
  fail=1
else
  echo "   ✓ handshake counted: ${ALLOWED} tool calls under a ${LIMIT}/min limit"
fi

[ $fail -eq 0 ] && echo "PASS arm A" || echo "FAIL arm A"
exit $fail
