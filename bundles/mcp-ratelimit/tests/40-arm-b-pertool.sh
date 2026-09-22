#!/usr/bin/env bash
# ARM B: per-tool budgets on /mcp-pertool.
#
# The assertion that actually proves per-tool bucketing is the SECOND one: after get-sum (3/min)
# is exhausted, echo (10/min) must still succeed. A test that only showed get-sum being blocked
# would pass just as happily against a plain route-wide ceiling.
set -uo pipefail
. "$(dirname "$0")/../helpers/lib-mcp.sh"
mcp_require_host || exit 1
EXPENSIVE_LIMIT=3

exhaust_expensive() {
  local sid="$1" i code allowed=0
  for i in $(seq 1 6); do
    code=$(mcp_call /mcp-pertool "$sid" $((100+i)) get-sum '{"a":1,"b":2}')
    if mcp_is_limited "$code"; then
      [ -z "$DENIAL" ] && DENIAL="$code"
      LIMITED=$((LIMITED+1))
    else
      allowed=$((allowed+1))
    fi
  done
  ALLOWED=$allowed
}

sid=$(mcp_init /mcp-pertool) || { echo "FAIL arm B: MCP handshake failed"; exit 1; }
DENIAL=""; ALLOWED=0; LIMITED=0
exhaust_expensive "$sid"
if [ $ALLOWED -eq 0 ]; then
  # Already spent from a previous run in this window; take a fresh one and repeat.
  mcp_wait_next_window
  sid=$(mcp_init /mcp-pertool) || { echo "FAIL arm B: MCP handshake failed"; exit 1; }
  DENIAL=""; ALLOWED=0; LIMITED=0
  exhaust_expensive "$sid"
fi

echo "== arm B: per-tool budgets on /mcp-pertool =="
echo "   get-sum (limit ${EXPENSIVE_LIMIT}/min): allowed ${ALLOWED}, blocked ${LIMITED}"
echo "   denial shape: $(mcp_denial_shape "$DENIAL")"

fail=0
if [ $LIMITED -lt 1 ]; then
  echo "   ✗ get-sum was never blocked -- the CEL descriptor is not matching."
  echo "     This is the classic silent failure: an unmatched descriptor is NOT counted, so the"
  echo "     route looks unlimited while the policy reports Accepted=True."
  echo "     check: kubectl logs -n agentgateway-system deploy/mcp-ratelimit | grep -i 'tool_name'"
  echo "     and confirm the ConfigMap value matches the tool name exactly ('get-sum')."
  fail=1
elif [ $ALLOWED -ne $EXPENSIVE_LIMIT ]; then
  echo "   ! blocked, but after ${ALLOWED} calls rather than ${EXPENSIVE_LIMIT}"
  echo "     (a partly-spent window will do this; not treated as a failure)"
  echo "   ✓ get-sum is limited"
else
  echo "   ✓ get-sum limited at exactly ${EXPENSIVE_LIMIT}/min"
fi

# The discriminating assertion.
echo "   -- echo (limit 10/min) while get-sum is exhausted:"
ok_echo=0
for i in 1 2; do
  code=$(mcp_call /mcp-pertool "$sid" $((200+i)) echo "{\"message\":\"pertool-canary-${i}\"}")
  if [ "$code" = "200" ] && grep -q "pertool-canary-${i}" "$MCP_BODY"; then
    ok_echo=$((ok_echo+1))
  fi
done
if [ $ok_echo -eq 2 ]; then
  echo "   ✓ echo still succeeds -- the two tools hold SEPARATE buckets"
else
  echo "   ✗ echo was blocked too (${ok_echo}/2 succeeded)."
  echo "     Either the descriptor collapsed both tools into one bucket, or echo's own 10/min"
  echo "     budget is spent from repeated runs inside one window -- re-run after 60s to tell"
  echo "     the two apart."
  fail=1
fi

[ $fail -eq 0 ] && echo "PASS arm B" || echo "FAIL arm B"
exit $fail
