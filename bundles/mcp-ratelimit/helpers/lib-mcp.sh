#!/usr/bin/env bash
# Shared MCP-over-HTTP helpers for the mcp-ratelimit tests.
#
# Sourced, never executed. Lives in helpers/ rather than tests/ because solomog runs every
# tests/*.sh as a test case -- a library there would be reported as a passing test.
#
# Deliberately curl and not the Python MCP SDK: these tests assert on HTTP status codes and on
# the exact denial shape, and an SDK turns a denial into an exception or a result object and
# hides the status entirely.

MCP_PROTO="2025-06-18"

# Wait out a full window.
#
# Sleeping only to the next wall-clock minute is NOT enough: the buckets are not aligned to the
# clock. A run that saw 23s left in the minute still came back rate limited because the limiter
# reported 46s to reset. One full window is the only duration that is correct for both the
# in-process bucket and the Redis-backed one, whatever their phase.
mcp_wait_next_window() {
  echo "    (waiting 62s for a fresh rate-limit window)"
  sleep 62
}

# mcp_init <path> -> prints the session id on stdout, empty on failure.
mcp_init() {
  local path="$1" hdr body code
  hdr=$(mktemp); body=$(mktemp)
  code=$(curl -sS -D "$hdr" -o "$body" -w '%{http_code}' "https://${HOST}${path}" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"${MCP_PROTO}\",\"capabilities\":{},\"clientInfo\":{\"name\":\"solomog\",\"version\":\"1.0\"}}}" 2>/dev/null)
  if [ "$code" != "200" ]; then
    echo "    initialize on ${path} returned HTTP ${code}" >&2
    head -c 300 "$body" >&2; echo >&2
    rm -f "$hdr" "$body"; return 1
  fi
  tr -d '\r' < "$hdr" | awk '/^[Mm]cp-[Ss]ession-[Ii]d:/{print $2}'
  rm -f "$hdr" "$body"
}

# mcp_raw <path> <session> <json-body> -> prints "<http_code>", body left in $MCP_BODY.
#
# MCP_BODY is a FIXED path chosen here, in the sourcing shell, and never reassigned inside the
# function. Callers invoke this as `code=$(mcp_raw ...)`, which runs it in a SUBSHELL: a variable
# assigned in there is gone by the time the caller reads it, so the body has to travel through a
# path both shells already agree on. Getting this wrong makes every body assertion grep an empty
# filename and silently fail -- loudly enough to look like a product bug.
MCP_BODY="${TMPDIR:-/tmp}/solomog-mcp-body.$$"
mcp_raw() {
  local path="$1" sid="$2" payload="$3" code
  : > "$MCP_BODY"
  code=$(curl -sS -o "$MCP_BODY" -w '%{http_code}' "https://${HOST}${path}" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H "Mcp-Session-Id: ${sid}" \
    -H "MCP-Protocol-Version: ${MCP_PROTO}" \
    -d "$payload" 2>/dev/null)
  echo "$code"
}

# mcp_call <path> <session> <id> <tool> <args-json> -> prints the HTTP status code.
mcp_call() {
  local path="$1" sid="$2" id="$3" tool="$4" args="$5"
  mcp_raw "$path" "$sid" "{\"jsonrpc\":\"2.0\",\"id\":${id},\"method\":\"tools/call\",\"params\":{\"name\":\"${tool}\",\"arguments\":${args}}}"
}

# A response counts as rate limited if it is an HTTP 429, OR -- on releases that carry upstream
# agentgateway #3146, which landed AFTER the 2026.7.1 LTS cut -- an HTTP 200 whose JSON-RPC body
# reports the limit instead. Checking both keeps the tests honest across that change rather than
# asserting a status code that silently became right or wrong on upgrade.
mcp_is_limited() {
  local code="$1"
  [ "$code" = "429" ] && return 0
  if [ "$code" = "200" ] && [ -n "$MCP_BODY" ] && [ -f "$MCP_BODY" ]; then
    grep -qiE 'rate limit|RESOURCE_EXHAUSTED|retryAfterSeconds' "$MCP_BODY" && return 0
  fi
  return 1
}

# Describe the denial shape actually observed, for the run capture.
mcp_denial_shape() {
  local code="$1"
  if [ "$code" = "429" ]; then
    echo "HTTP 429 (pre-#3146 shape, expected on the 2026.7.x LTS line)"
  else
    echo "HTTP ${code} + JSON-RPC in body (post-#3146 shape)"
  fi
}

mcp_require_host() {
  if [ -z "${HOST:-}" ]; then
    echo "✗ HOST is not set. Run through: solomog test BUNDLE=mcp-ratelimit CLUSTER=<c>" >&2
    return 1
  fi
}
