#!/usr/bin/env bash
# Eager-auth is Strict, so an unauthenticated request to /mcp must be rejected (401) before it
# reaches the backend. A 406 here instead means the mcp.authentication policy went PartiallyValid
# (usually a bad jwksPath — see the lab troubleshooting / 40-eager-auth.sh) and /mcp is bypassing auth.
set -euo pipefail
status=$(curl -sk -o /dev/null -w "%{http_code}" -X POST "https://${HOST}/mcp" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')
[ "$status" -eq 401 ] || { echo "expected 401 (no token), got $status (406 ⇒ policy PartiallyValid / jwksPath)"; exit 1; }
echo "✓ /mcp rejects an unauthenticated request (401)"
