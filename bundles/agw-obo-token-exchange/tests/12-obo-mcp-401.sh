#!/usr/bin/env bash
# The MCP route must reject an unauthenticated request BEFORE any MCP protocol negotiation —
# the JWT filter runs at the route level, so a plain request with no bearer token is 401'd
# regardless of the MCP transport. Mirrors 10-obo-openai-401.sh for the tool side.
set -euo pipefail
status=$(curl -sk -o /dev/null -w "%{http_code}" "https://${HOST}/obo/mcp" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}')
[ "$status" -eq 401 ] || { echo "expected 401, got $status"; exit 1; }
