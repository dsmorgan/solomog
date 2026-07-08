#!/usr/bin/env bash
# The JWT policy is Strict, so an unauthenticated request to /mcp must be rejected at the
# edge (401) before it ever reaches the MCP backend. This is the negative half of the proof;
# 20- is the positive half (a real Okta token gets in).
set -euo pipefail
status=$(curl -sk -o /dev/null -w "%{http_code}" -X POST "https://${HOST}/mcp" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')
[ "$status" -eq 401 ] || { echo "expected 401 (no token), got $status"; exit 1; }
echo "✓ /mcp rejects an unauthenticated request (401)"
