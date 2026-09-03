#!/usr/bin/env bash
# Capture a debug trace while one request is driven through the gateway, then show every body
# snapshot in it -- decoded, and flagged when it contains an OAuth token response.
#
# This is the tool for the question the bundle exists to answer: when the gateway exchanges a
# token, the authorization server's reply is an ordinary backend response, so a trace records
# it as a `bodySnapshot` event. Per RFC 6749 that body carries `access_token`, which means the
# exchanged token is readable from a trace even though the header carrying it is redacted.
#
#   CLUSTER=<c> bash bundles/agw-trace-exchanged-token/helpers/capture-trace.sh http
#   CLUSTER=<c> bash bundles/agw-trace-exchanged-token/helpers/capture-trace.sh mcp
#   CLUSTER=<c> KEEP=true bash .../capture-trace.sh http    # keep the raw .jsonl capture
#
# Env: CLUSTER (required, or CONTEXT), GATEWAY (default agw), NS (default agentgateway-system).
#
# WARNING: a capture that includes a token-endpoint response contains a live bearer token in
# clear text. Trace bodies are NOT redacted, unlike headers. Treat the .jsonl as a credential:
# do not attach it to a ticket, and delete it when done. KEEP=true opts in deliberately.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=/dev/null
. "$REPO_DIR/scripts/lib/target.sh"

MODE="${1:-http}"
GATEWAY="${GATEWAY:-agw}"
NS="${NS:-agentgateway-system}"
CTX="${CONTEXT:-$(solomog_context "${CLUSTER:?set CLUSTER=<name>}")}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$MODE" in http|mcp) ;; *) echo "usage: capture-trace.sh [http|mcp]" >&2; exit 2 ;; esac

command -v jq >/dev/null || { echo "✗ jq is required" >&2; exit 1; }
if ! command -v agctl >/dev/null; then
  echo "✗ agctl not found. Install it, then re-run:" >&2
  echo "  curl -sL https://github.com/agentgateway/agentgateway/releases/latest/download/agctl-darwin-arm64 -o agctl" >&2
  echo "  chmod +x agctl && sudo install agctl /usr/local/bin/agctl && rm agctl" >&2
  exit 1
fi

HOST="$(kubectl --context "$CTX" get gateways.gateway.networking.k8s.io "$GATEWAY" -n "$NS" \
  -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
[ -n "$HOST" ] || { echo "✗ no address for gateway '$GATEWAY' in $NS. Has 'solomog expose' run?" >&2; exit 1; }

# FORCE a fresh subject token. The exchange result is cached in the proxy (in-memory, 300s by
# default), and a cache hit makes NO call to the authorization server -- so there is no token
# response to snapshot and the technique looks broken when it is merely warm. A new subject
# token is a new cache key, which guarantees a real exchange.
TOKEN="$(CLUSTER="${CLUSTER:-}" CONTEXT="$CTX" FORCE=true bash "$HERE/get-token.sh")"
CAP="$(mktemp "${TMPDIR:-/tmp}/agw-trace-${MODE}.XXXXXX.jsonl")"
chmod 600 "$CAP"

echo "==> tracing gateway/${GATEWAY} while driving one ${MODE} request"

# Watch mode: agctl waits for the next request through the proxy. Start it first, give it a
# moment to attach, then drive traffic.
agctl proxy trace "gateway/${GATEWAY}" -n "$NS" --raw >"$CAP" 2>/dev/null &
AG_PID=$!
disown "$AG_PID" 2>/dev/null || true
cleanup() { kill "$AG_PID" 2>/dev/null || true; [ "${KEEP:-false}" = true ] || rm -f "$CAP"; }
trap cleanup EXIT
sleep 4

if [ "$MODE" = http ]; then
  curl -sk --max-time 20 -o /dev/null "https://${HOST}/exchange-http" -H "Authorization: Bearer ${TOKEN}" || true
else
  curl -sk --max-time 25 -o /dev/null -X POST "https://${HOST}/exchange-mcp" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"trace-probe","version":"0"}}}' || true
fi

sleep 4
kill "$AG_PID" 2>/dev/null || true
sleep 1

[ -s "$CAP" ] || { echo "✗ trace captured nothing. Is the proxy reachable, and did the request route?" >&2; exit 1; }

# Events are nested under .message in --raw output; tolerate a flat shape too.
echo
echo "── body snapshots in this trace ──"
jq -rc 'if .message then .message else . end
        | select(.type == "bodySnapshot")
        | {stage, body}' "$CAP" 2>/dev/null | while IFS= read -r ev; do
  stage="$(printf '%s' "$ev" | jq -r '.stage')"
  decoded="$(printf '%s' "$ev" | jq -r '.body' | base64 --decode 2>/dev/null || true)"
  if printf '%s' "$decoded" | jq -e 'has("access_token")' >/dev/null 2>&1; then
    echo
    echo "  stage=${stage}  ← OAuth token response (this is the exchanged token)"
    printf '%s' "$decoded" | jq '{token_type, expires_in, scope,
                                  access_token_claims: (.access_token | split(".")[1]
                                    | (. + ("=" * ((4 - (length % 4)) % 4)))
                                    | @base64d | fromjson
                                    | {sub, azp, aud, scope, jti, exp})}' 2>/dev/null \
      || printf '%s\n' "$decoded"
  else
    echo "  stage=${stage}  (${#decoded} bytes, not a token response)"
  fi
done

echo
if [ "${KEEP:-false}" = true ]; then
  echo "raw capture: $CAP"
  echo "  contains a live bearer token — delete it when you are done."
else
  echo "raw capture discarded. KEEP=true retains it (it holds a live token)."
fi
