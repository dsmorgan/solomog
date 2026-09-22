#!/usr/bin/env bash
# The known-good path, before any assertion about limits. If a tool call does not work at all,
# a later "it was blocked" result would be indistinguishable from a broken backend.
set -uo pipefail
. "$(dirname "$0")/../helpers/lib-mcp.sh"
mcp_require_host || exit 1
fail=0

for path in /mcp-local /mcp-pertool /mcp-ent; do
  echo "== ${path} =="
  sid=$(mcp_init "$path") || { echo "   ✗ initialize failed"; fail=1; continue; }

  code=$(mcp_raw "$path" "$sid" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
  if [ "$code" = "200" ] && grep -q '"get-sum"' "$MCP_BODY" && grep -q '"echo"' "$MCP_BODY"; then
    echo "   ✓ tools/list exposes both echo and get-sum"
  else
    echo "   ✗ tools/list HTTP ${code}; expected both echo and get-sum in the catalogue"
    echo "     the per-tool descriptor matches the literal string 'get-sum' -- if the pinned"
    echo "     server-everything version moved, the tool may be named 'add' again."
    head -c 200 "$MCP_BODY"; echo
    fail=1
  fi

  # Assert the canary in the RESULT, not the status: HTTP 200 only proves the request was
  # accepted, and a rate-limited call on a post-#3146 release is also a 200.
  code=$(mcp_call "$path" "$sid" 3 echo '{"message":"solomog-canary"}')
  if [ "$code" = "200" ] && grep -q 'solomog-canary' "$MCP_BODY"; then
    echo "   ✓ echo round-trips the canary through the relay"
  else
    echo "   ✗ echo returned HTTP ${code} without the canary"
    head -c 200 "$MCP_BODY"; echo
    fail=1
  fi
done

[ $fail -eq 0 ] && echo "PASS baseline" || echo "FAIL baseline"
exit $fail
