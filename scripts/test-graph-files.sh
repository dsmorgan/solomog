#!/usr/bin/env bash
# Hermetic tests for `solomog graph INPUT=` (no cluster).
# Run: bash scripts/test-graph-files.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRAPH="$REPO_DIR/scripts/graph.sh"
FIX="$REPO_DIR/scripts/testdata/graph"
GHOSTS="$REPO_DIR/scripts/lib/graph/ghosts.jq"

FAIL=0
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; FAIL=$((FAIL + 1)); }

assert_eq() {
  local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then pass "$label"; else fail "$label (got=$(printf '%q' "$got") want=$(printf '%q' "$want"))"; fi
}

assert_contains() {
  local label="$1" hay="$2" needle="$3"
  case "$hay" in
    *"$needle"*) pass "$label" ;;
    *) fail "$label (missing $(printf '%q' "$needle"))" ;;
  esac
}

assert_not_contains() {
  local label="$1" hay="$2" needle="$3"
  case "$hay" in
    *"$needle"*) fail "$label (unexpected $(printf '%q' "$needle"))" ;;
    *) pass "$label" ;;
  esac
}

# Render INPUT and leave the HTML path in $OUT_HTML. Stderr+stdout in $OUT_LOG.
render() {
  local outdir
  outdir="$(mktemp -d)"
  OUT_HTML="$outdir/graph.html"
  set +e
  OUT_LOG="$(env OPEN=false OUT="$OUT_HTML" "$@" bash "$GRAPH" 2>&1)"
  OUT_RC=$?
  set -e
}

data_json() {
  python3 -c '
import sys
t = open(sys.argv[1]).read()
key = "window.SOLOMOG_DATA="
i = t.index(key)
rest = t[i + len(key):]
j = rest.index(";\nwindow.SOLOMOG_YAML")
sys.stdout.write(rest[:j])
' "$OUT_HTML"
}

node_field() {
  # $1 jq filter that prints one string
  data_json | jq -r "$1"
}

echo "==> stacked file"
render INPUT="$FIX/stacked.yaml"
assert_eq "stacked exit 0" "$OUT_RC" "0"
[ -f "$OUT_HTML" ] && pass "html written" || fail "html written"
D="$(data_json)"
assert_eq "file mode" "$(printf '%s' "$D" | jq -r '.fileMode')" "true"
assert_eq "chat status ignored" "$(printf '%s' "$D" | jq -r '.elements[]|select(.data.id=="httproute:app/chat")|.data.status')" "na"
assert_eq "ghost gateway agw" "$(printf '%s' "$D" | jq -r '.elements[]|select(.data.id=="gateway:app/agw")|.data.ghost')" "true"
assert_eq "ghost gateway kind" "$(printf '%s' "$D" | jq -r '.elements[]|select(.data.id=="gateway:app/agw")|.data.kind')" "Gateway"
assert_eq "no istio gateway node" "$(printf '%s' "$D" | jq '[.elements[]|select(.data.id=="gateway:app/istio")]|length')" "0"
assert_eq "chat parents ghost agw" "$(printf '%s' "$D" | jq '[.elements[]|select(.data.source=="httproute:app/chat" and .data.target=="gateway:app/agw")]|length')" "1"
assert_eq "ghost missing backend" "$(printf '%s' "$D" | jq -r '.elements[]|select(.data.name=="llm" and .data.kind=="Backend")|.data.ghost')" "true"
assert_eq "real backend not ghost" "$(printf '%s' "$D" | jq -r '.elements[]|select(.data.name=="with-secret")|.data.ghost // false')" "false"
assert_eq "ghost missing route" "$(printf '%s' "$D" | jq -r '.elements[]|select(.data.id=="httproute:app/missing-route")|.data.ghost')" "true"
assert_eq "ghost service" "$(printf '%s' "$D" | jq -r '.elements[]|select(.data.kind=="Service" and .data.name=="httpbin")|.data.ghost')" "true"
assert_eq "ghost model" "$(printf '%s' "$D" | jq -r '.elements[]|select(.data.kind=="ModelConfig" and .data.name=="missing-model")|.data.ghost')" "true"
assert_eq "chat source file" "$(printf '%s' "$D" | jq -r '.elements[]|select(.data.id=="httproute:app/chat")|.data.origin')" "stacked.yaml"
assert_contains "skipped secret" "$OUT_LOG" "Secret"
assert_not_contains "no inline key" "$(cat "$OUT_HTML")" "AKIAINLINE"
assert_not_contains "no secret key" "$(cat "$OUT_HTML")" "AKIASECRET"
assert_contains "redacted marker" "$(cat "$OUT_HTML")" "<redacted>"
assert_contains "secretRef name kept" "$(cat "$OUT_HTML")" "bedrock-secret"
assert_contains "subtitle" "$(cat "$OUT_HTML")" "status not evaluated"

echo "==> STATUS=exported"
render INPUT="$FIX/stacked.yaml" STATUS=exported
assert_eq "exported exit 0" "$OUT_RC" "0"
assert_eq "chat status from file" "$(data_json | jq -r '.elements[]|select(.data.id=="httproute:app/chat")|.data.status')" "ok"
assert_contains "exported subtitle" "$(cat "$OUT_HTML")" "exported status"

echo "==> directory"
render INPUT="$FIX/dir"
assert_eq "dir exit 0" "$OUT_RC" "0"
assert_eq "dir ghost gateway" "$(data_json | jq -r '.elements[]|select(.data.id=="gateway:app/agw")|.data.ghost')" "true"
assert_eq "dir source path" "$(data_json | jq -r '.elements[]|select(.data.id=="httproute:app/chat")|.data.origin')" "10-chat.yaml"

echo "==> JSON list"
render INPUT="$FIX/list.json"
assert_eq "list exit 0" "$OUT_RC" "0"
assert_eq "list route" "$(data_json | jq -r '.elements[]|select(.data.id=="httproute:app/from-list")|.data.kind')" "HTTPRoute"
assert_eq "list ghost gateway" "$(data_json | jq -r '.elements[]|select(.data.id=="gateway:app/agw")|.data.ghost')" "true"

echo "==> duplicates"
DUP="$(mktemp -d)"
printf '%s\n' 'apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: chat, namespace: app}' > "$DUP/a.yaml"
cp "$DUP/a.yaml" "$DUP/b.yaml"
render INPUT="$DUP"
assert_eq "dup exit 1" "$OUT_RC" "1"
assert_contains "dup names both files" "$OUT_LOG" "a.yaml"
assert_contains "dup names b" "$OUT_LOG" "b.yaml"
rm -rf "$DUP"

echo "==> nothing to graph"
EMPTY="$(mktemp)"
printf '%s\n' 'apiVersion: v1
kind: Namespace
metadata: {name: app}' > "$EMPTY"
render INPUT="$EMPTY"
assert_eq "empty exit 1" "$OUT_RC" "1"
assert_contains "empty message" "$OUT_LOG" "nothing to graph"
rm -f "$EMPTY"

echo "==> missing path"
render INPUT="$FIX/no-such-dir"
assert_eq "missing exit 1" "$OUT_RC" "1"

echo "==> INPUT and CLUSTER together"
set +e
BOTH="$(OPEN=false INPUT="$FIX/stacked.yaml" bash "$GRAPH" foo 2>&1)"
BOTH_RC=$?
set -e
assert_eq "both exit 1" "$BOTH_RC" "1"
assert_contains "both message" "$BOTH" "not both"

echo "==> live service is not a ghost; a missing backend CR is"
LIVE="$(jq -n -f "$GHOSTS" \
  --arg fileMode false \
  --slurpfile data <(printf '%s' '{"elements":[
    {"data":{"id":"backend:service:app/httpbin","kind":"Service","ns":"app","name":"httpbin","status":"na","detail":{"declared":"route/policy ref"}}},
    {"data":{"id":"backend:enterpriseagentgatewaybackends.enterpriseagentgateway.solo.io:app/llm","kind":"Backend","ns":"app","name":"llm","status":"na","detail":{"declared":"route/policy ref"}}},
    {"data":{"id":"e:target:app:p:Gateway:istio","source":"policy:app/p","target":"gateway:app/istio","rel":"targetRef"}}
  ]}') \
  --slurpfile gw <(printf '%s' '[{"metadata":{"namespace":"app","name":"istio"},"spec":{"gatewayClassName":"istio"}}]') \
  --slurpfile rt <(printf '%s' '[]') \
  --slurpfile svcs <(printf '%s' '[]'))"
assert_eq "live service solid" "$(printf '%s' "$LIVE" | jq -r '.elements[]|select(.data.name=="httpbin")|.data.ghost // false')" "false"
assert_eq "live missing backend ghost" "$(printf '%s' "$LIVE" | jq -r '.elements[]|select(.data.name=="llm")|.data.ghost')" "true"
assert_eq "live istio not ghosted" "$(printf '%s' "$LIVE" | jq '[.elements[]|select(.data.id=="gateway:app/istio")]|length')" "0"

FILEG="$(jq -n -f "$GHOSTS" \
  --arg fileMode true \
  --slurpfile data <(printf '%s' '{"elements":[
    {"data":{"id":"backend:service:app/httpbin","kind":"Service","ns":"app","name":"httpbin","status":"na","detail":{"declared":"route/policy ref"}}}
  ]}') \
  --slurpfile gw <(printf '%s' '[]') \
  --slurpfile rt <(printf '%s' '[]') \
  --slurpfile svcs <(printf '%s' '[]'))"
assert_eq "file service ghost" "$(printf '%s' "$FILEG" | jq -r '.elements[]|select(.data.name=="httpbin")|.data.ghost')" "true"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "ok"
else
  echo "$FAIL failed"
  exit 1
fi
