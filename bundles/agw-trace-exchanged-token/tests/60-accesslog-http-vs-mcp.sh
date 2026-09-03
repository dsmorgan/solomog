#!/usr/bin/env bash
# Reproduce agentgateway-enterprise#7844 in one run: identical access-log attributes populate
# on an HTTP-backend route and stay empty on an MCP relay route.
#
# exchanged_fingerprint is the tell. On the MCP route it is the SHA-256 of the empty string,
# which proves no Authorization header was on the logged request at all -- as opposed to one
# that was present but failed to parse.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
EMPTY_SHA=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
NS=agentgateway-system
GW="${GATEWAY:-agw}"
TOKEN="$(bash "$HERE/../helpers/get-token.sh")"

since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
curl -sk --max-time 20 -o /dev/null "https://${HOST}/exchange-http" -H "Authorization: Bearer ${TOKEN}" || true
curl -sk --max-time 25 -o /dev/null -X POST "https://${HOST}/exchange-mcp" \
  -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}' || true
sleep 3

logs="$(kubectl --context "$CONTEXT" logs -l "gateway.networking.k8s.io/gateway-name=${GW}" -n "$NS" \
  --since-time="$since" --tail=-1 2>/dev/null | grep 'xtoken' || true)"
[ -n "$logs" ] || { echo "✗ no probe access-log lines; is the exchange-access-log policy attached?" >&2; exit 1; }

field() { printf '%s\n' "$logs" | grep -- "$1" | tail -1 | sed -n "s/.*$2=\"\{0,1\}\([^\" ]*\).*/\1/p"; }

http_azp="$(field '/headers' exchanged_azp)"     # the HTTP route rewrites /exchange-http -> /headers
mcp_fp="$(field '/exchange-mcp' exchanged_fingerprint)"

echo "  HTTP route  exchanged_azp=${http_azp:-<none>}"
echo "  MCP route   exchanged_fingerprint=${mcp_fp:-<none>}"

[ "$http_azp" = "exchange-client" ] || {
  echo "✗ HTTP route access log did not carry the exchanged token (azp=${http_azp:-<none>})" >&2; exit 1; }
[ "$mcp_fp" = "$EMPTY_SHA" ] || {
  echo "! MCP route fingerprint is not the empty-string hash (${mcp_fp:-<none>})." >&2
  echo "  If it is a real hash, the MCP relay route DOES carry the exchanged token and #7844" >&2
  echo "  needs revisiting on this version." >&2; exit 1; }

echo "✓ #7844 reproduced: access log carries the exchanged token on HTTP, nothing on the MCP relay"
