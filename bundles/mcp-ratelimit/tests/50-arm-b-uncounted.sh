#!/usr/bin/env bash
# ARM B, second property: non-tool JSON-RPC methods are never counted.
#
# This is not a product exemption -- it falls out of the CEL mapping every non-tools/call method
# to mcp_method=other, which matches no rule in the descriptor tree. Worth its own test because
# it is the part that silently disappears if someone edits the expressions.
set -uo pipefail
. "$(dirname "$0")/../helpers/lib-mcp.sh"
mcp_require_host || exit 1

sid=$(mcp_init /mcp-pertool) || { echo "FAIL: MCP handshake failed"; exit 1; }

echo "== arm B: uncounted methods on /mcp-pertool =="
# Comfortably more than any limit in the tree (3/min and 10/min). If these were counted at all,
# 15 of them would trip something.
blocked=0
for i in $(seq 1 15); do
  code=$(mcp_raw /mcp-pertool "$sid" "{\"jsonrpc\":\"2.0\",\"id\":$((300+i)),\"method\":\"tools/list\"}")
  mcp_is_limited "$code" && blocked=$((blocked+1))
done
echo "   15 x tools/list -> blocked ${blocked}"

extra_init=0
for i in 1 2 3 4 5; do
  s=$(mcp_init /mcp-pertool) || extra_init=$((extra_init+1))
done
echo "   5 x initialize  -> failed ${extra_init}"

fail=0
if [ $blocked -ne 0 ]; then
  echo "   ✗ tools/list consumed budget -- the mcp_method CEL is not mapping it to 'other'"
  fail=1
else
  echo "   ✓ tools/list never counted"
fi
if [ $extra_init -ne 0 ]; then
  echo "   ✗ initialize was blocked or failed -- handshakes should pass freely on this arm"
  fail=1
else
  echo "   ✓ initialize never counted"
fi

[ $fail -eq 0 ] && echo "PASS arm B uncounted" || echo "FAIL arm B uncounted"
exit $fail
