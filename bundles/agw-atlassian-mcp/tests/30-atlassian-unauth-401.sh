#!/usr/bin/env bash
# Plain Strict Okta JWT frontend (matches Snowflake in agw-okta-mcp) — an unauthenticated request
# to /atlassian/mcp must be rejected (401) before it reaches the elicitation/backend logic.
set -euo pipefail
status=$(curl -sk -o /dev/null -w "%{http_code}" -X POST "https://${HOST}/atlassian/mcp" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize"}')
[ "$status" -eq 401 ] || { echo "expected 401 (no token), got $status"; exit 1; }
echo "✓ /atlassian/mcp rejects an unauthenticated request (401)"
