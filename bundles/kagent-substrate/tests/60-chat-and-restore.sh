#!/usr/bin/env bash
# One real turn: restore an actor, run it, get an answer back.
#
# The A2A reply shape matters here and is easy to get wrong. kagent 0.10.1 returns a `task`
# whose outcome is `.result.status.state` and whose text — success OR failure — is in
# `.result.status.message.parts[].text`. There is no `.result.artifacts` key at all. Reading
# artifacts (as substrate-scope's stimulate.mjs does) turns a failed turn into a silent
# "no text" and throws away the only sentence that says what went wrong: the first run of
# this test reported "completed with no artifact text" for a turn that had actually failed
# with an OpenAI TLS handshake timeout.
set -euo pipefail

CTX="${CONTEXT:?CONTEXT not set}"
AGENT="${SUBSTRATE_TEST_AGENT:-explainer}"
PORT="${SUBSTRATE_STATUS_PORT:-18084}"
PROVIDER="${KAGENT_PROVIDER:-openAI}"

# Self-skip rather than fail: an absent model credential is an environment gap, not a
# substrate defect, and it should not mask the platform tests that already passed.
case "$PROVIDER" in
  anthropic) [ -n "${CLAUDE_API_KEY:-}" ] || {
    echo "SKIP: CLAUDE_API_KEY is empty in .env — no model to answer with."
    echo "      Set it, or re-run with KAGENT_PROVIDER=ollama."; exit 0; } ;;
  openai|openAI) [ -n "${OPENAI_API_KEY:-}" ] || {
    echo "SKIP: OPENAI_API_KEY is empty in .env."; exit 0; } ;;
esac

echo "── one real turn against ${AGENT}"

kubectl --context "$CTX" port-forward -n kagent svc/kagent-controller "${PORT}:8083" \
  >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null || true' EXIT
sleep 4

ID="solomog-$(date +%s)-$$"
REQ="$(jq -n --arg id "$ID" \
  '{jsonrpc:"2.0", id:$id, method:"message/send",
    params:{message:{kind:"message", messageId:$id, contextId:$id, role:"user",
      parts:[{kind:"text", text:"In one sentence: where are you running?"}]}}}')"

# 180s, not a default timeout: a cold actor has to be restored from a snapshot before the
# model is even called, and the first turn after an install is the slowest one you will see.
RESP="$(curl -sS --max-time 180 -X POST \
  -H 'Content-Type: application/json' -d "$REQ" \
  "http://127.0.0.1:${PORT}/api/a2a-sandboxes/kagent/${AGENT}/" 2>/dev/null || true)"

if [ -z "$RESP" ]; then
  echo "  ✗ no response from the A2A endpoint"
  exit 1
fi

ERR="$(printf '%s' "$RESP" | jq -r '.error.message // ""' 2>/dev/null || true)"
if [ -n "$ERR" ]; then
  echo "  ✗ JSON-RPC error: ${ERR}"
  case "$ERR" in
    *"no free workers"*|*"worker pool"*)
      echo "    The pool is full — substrate rejects rather than queues. Scale up:"
      echo "      kubectl --context $CTX scale workerpools.ate.dev kagent-default -n kagent --replicas=4" ;;
    *)
      echo "    kubectl --context $CTX logs -n kagent deploy/kagent-controller --tail=50" ;;
  esac
  exit 1
fi

STATE="$(printf '%s' "$RESP" | jq -r '.result.status.state // "unknown"' 2>/dev/null)"
# Text can be in status.message (both outcomes), history (the turn transcript) or artifacts
# (older/other shapes). Take the first that yields anything so this keeps working if the
# reply shape moves again.
TEXT="$(printf '%s' "$RESP" | jq -r '
  [ (.result.status.message.parts[]? | select(.kind=="text") | .text),
    (.result.history[]? | select(.role=="agent") | .parts[]? | select(.kind=="text") | .text),
    (.result.artifacts[]?.parts[]? | select(.kind=="text") | .text) ]
  | map(select(. != null and . != "")) | .[0] // ""' 2>/dev/null || true)"

case "$STATE" in
  completed)
    if [ -n "$TEXT" ]; then
      echo "  ✓ state=completed: $(printf '%s' "$TEXT" | tr '\n' ' ' | head -c 140)"
    else
      echo "  ✓ state=completed (no text in the reply — shape may have changed)"
    fi ;;
  failed)
    echo "  ✗ state=failed: $(printf '%s' "$TEXT" | tr '\n' ' ' | head -c 300)"
    case "$TEXT" in
      *"TLS handshake timeout"*|*"context deadline exceeded"*)
        cat <<EOF
    The actor reached DNS and completed a TCP connect, then stalled on the first large
    exchange. That is an MTU blackhole, not a credential problem: pods on this cluster use
    MTU $(kubectl --context "$CTX" exec -n ate-system valkey-cluster-0 -- cat /sys/class/net/eth0/mtu 2>/dev/null || echo '?') and the gVisor actor's netstack does not inherit it.
    See docs/findings.md, "Actor egress blackholes on an overlay CNI".
EOF
        ;;
      *401*|*invalid_api_key*|*Unauthorized*)
        echo "    The model rejected the credential — check the Secret matches KAGENT_PROVIDER." ;;
    esac
    exit 1 ;;
  *)
    echo "  ✗ unexpected task state '${STATE}'"
    printf '%s\n' "$RESP" | head -c 400 | sed 's/^/    /'
    exit 1 ;;
esac

# Substrate's own view: the actor for this agent is placed on a worker. This is what makes
# the reply evidence of a restore rather than of any other code path.
S="$(curl -sS --max-time 20 "http://127.0.0.1:${PORT}/api/substrate/status?namespace=kagent" 2>/dev/null \
  | jq -c 'if has("data") then .data else . end' 2>/dev/null || true)"
PLACED="$(printf '%s' "$S" | jq -r --arg a "$AGENT" \
  '[.workers[]? | select(.actorTemplate == $a)] | length' 2>/dev/null || echo 0)"
if [ "${PLACED:-0}" -ge 1 ]; then
  echo "  ✓ substrate reports ${AGENT} placed on a worker"
else
  # Not fatal: substrate checkpoints and evicts an idle actor quickly, so a fast turn can
  # be fully suspended again before this call lands.
  echo "  · ${AGENT} not currently on a worker — likely already checkpointed back to storage"
  printf '%s' "$S" | jq -r '.actors[]? | "    actor \(.actorTemplateName) status=\(.status)"' 2>/dev/null || true
fi
