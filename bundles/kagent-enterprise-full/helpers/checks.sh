#!/usr/bin/env bash
# Sourced by tests/: pass/fail bookkeeping and the probes more than one test needs.
HELPERS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HELPERS/env.sh"
CTX="${CONTEXT:?CONTEXT not set — solomog sets this for tests}"
k() { kubectl --context "$CTX" "$@"; }
fail=0
ok()  { printf '  ✓ %s\n' "$*"; }
no()  { printf '  ✗ %s\n' "$*"; fail=1; }
say() { printf '    %s\n' "$*"; }

# pf NAMESPACE TARGET PORT... → one port-forward, local port = a random base + i for each remote
# port in order. Sets PF_PID and PF_BASE and waits for the first port. Pair with pf_stop.
pf() {
  local ns="$1" target="$2" i=0 maps="" p; shift 2
  PF_BASE=$(( 20000 + RANDOM % 20000 ))
  for p in "$@"; do maps="$maps $((PF_BASE + i)):${p}"; i=$((i + 1)); done
  # shellcheck disable=SC2086  # one argument per mapping
  k -n "$ns" port-forward "$target" $maps >/dev/null 2>&1 & PF_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do nc -z 127.0.0.1 "$PF_BASE" 2>/dev/null && return 0; sleep 1; done
  return 1
}
pf_stop() { kill "${PF_PID:-}" 2>/dev/null; wait "${PF_PID:-}" 2>/dev/null; PF_PID=""; }

# admin_token PORT → an admin token from the bundled IdP behind a forwarded controller :8085. It
# issues one to any caller; that's the posture of an install with no enterprise.oidc.issuer.
admin_token() {
  curl -s --max-time 10 -X POST -H 'Content-Type: application/json' -d '{"user_type":"admin"}' \
    "http://127.0.0.1:$1/autoauth/token" | jq -r '.access_token // empty'
}

# leader_pod → the controller pod holding the leader lease. With one replica it's the only pod,
# but right after a rollout the lease can still name the old one, so callers retry.
leader_pod() {
  k -n "$KAGENT_NS" get lease 0e9f6799.kagent.dev -o jsonpath='{.spec.holderIdentity}' 2>/dev/null | sed 's/_.*//'
}

# api_open → port-forwards the leader controller's :8083 (gRPC and HTTP API) and :8085 (bundled
# IdP), gets an admin token, and sets API, TOKEN and PF_PID. Pair with pf_stop.
api_open() {
  local pod i
  for i in 1 2 3 4 5 6; do
    pod="$(leader_pod)"
    pf "$KAGENT_NS" "pod/${pod:-missing}" 8083 8085 && break
    pf_stop
    [ "$i" = 6 ] && { echo "  ✗ no port-forward to leader '${pod}' after 6 tries"; return 1; }
    sleep 10
  done
  API="127.0.0.1:${PF_BASE}"
  TOKEN="$(admin_token $((PF_BASE + 1)))"
  [ -n "$TOKEN" ] || { pf_stop; echo "  ✗ no admin token from :8085/autoauth/token (is enterprise.oidc.issuer set?)"; return 1; }
}

# ent METHOD [JSON] → one call to an enterprise API on the controller's :8085 (gRPC-Web, protobuf
# only) through helpers/grpcweb, which reads the message types from reflection on :8083. Needs
# api_open. Prints each response message as one JSON line.
ent() { TOKEN="$TOKEN" "$(grpcweb_bin)" -reflect "$API" -url "http://127.0.0.1:$((PF_BASE + 1))/api" "$@"; }

# turn AGENT TEXT → one turn on a fresh Session of AGENT, with TEXT as the user message. Sets
# TURN_OUT to the reply and returns helpers/a2a-turn's exit code.
#
# The enterprise controller authenticates every API call and the community kagent CLI can't send a
# bearer token, so helpers/a2a-turn (a small gRPC client) does it.
turn() {
  local bin rc
  bin="$(a2a_turn_bin)" || { TURN_OUT="could not build helpers/a2a-turn (needs Go)"; return 1; }
  api_open || { TURN_OUT="no API connection"; return 1; }
  TURN_OUT="$(TOKEN="$TOKEN" "$bin" -addr "$API" -namespace "$KAGENT_NS" -agent "$1" -text "$2" 2>&1)"; rc=$?
  pf_stop
  return "$rc"
}

# a2a_turn_bin, grpcweb_bin → path to a built helper, rebuilt when its source changes, cached under
# .solomog/bin so later runs make no network call.
a2a_turn_bin() { go_bin a2a-turn; }
grpcweb_bin() { go_bin grpcweb; }
go_bin() {
  local src="$HELPERS/$1" repo hash bin
  repo="$(cd "$HELPERS/../../.." && pwd)"
  hash="$(cat "$src/main.go" "$src/go.mod" | shasum | cut -c1-12)"
  bin="$repo/.solomog/bin/$1-${hash}"
  if [ ! -x "$bin" ]; then
    command -v go >/dev/null || return 1
    mkdir -p "$repo/.solomog/bin"
    (cd "$src" && go build -o "$bin" .) >&2 || return 1
  fi
  echo "$bin"
}

# agent_ready AGENT → 0 when the Agent's current generation reports Ready=True, which is when its
# golden snapshot is built.
agent_ready() {
  k get agent.api.kagent.dev "$1" -n "$KAGENT_NS" -o json 2>/dev/null | jq -e '.metadata.generation as $g
    | [.status.conditions[]? | select(.type == "Ready" and .status == "True" and .observedGeneration == $g)] | length > 0' >/dev/null
}
# wait_agent AGENT [SECONDS] → waits for agent_ready, printing the conditions on timeout.
wait_agent() {
  local deadline=$(( $(date +%s) + ${2:-600} ))
  while ! agent_ready "$1"; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      k get agent.api.kagent.dev "$1" -n "$KAGENT_NS" -o jsonpath='{range .status.conditions[*]}      {.type}={.status} {.reason}: {.message}{"\n"}{end}' 2>/dev/null
      return 1
    fi
    sleep 10
  done
}

# mock_log NAMESPACE DEPLOY [MATCH] → a mock's request log as JSON lines, only those containing
# MATCH when given. Read inside the pod, so no port-forward.
mock_log() {
  k -n "$1" exec "deploy/$2" -- python3 -c \
    'import urllib.request; print(urllib.request.urlopen("http://127.0.0.1:8080/requests").read().decode())' 2>/dev/null \
    | jq -c --arg m "${3:-}" 'select($m == "" or (tostring | contains($m)))' 2>/dev/null
}

# ch SQL → runs SQL in the bundled ClickHouse as the chart's default user; TabSeparated output.
ch() {
  k -n "$KAGENT_NS" exec kagent-clickhouse-shard0-0 -c clickhouse -- \
    clickhouse-client --user default --password password --database kagent -q "$1" 2>&1
}
