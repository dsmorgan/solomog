#!/usr/bin/env bash
# Golden snapshots: the proof that gVisor actually works here.
#
# Baking a golden means substrate started the agent container inside a runsc sandbox on a
# worker, let it reach its ready state, checkpointed the whole thing to object storage and
# zstd-compressed it. Nothing short of a working gVisor produces a Ready SandboxAgent, so
# this test is the honest answer to "can this cluster run substrate".
#
# Deliberately NOT `kubectl wait --for=condition=Ready` per agent: that prints nothing while
# it blocks, multiplies the timeout by the number of agents, and — worst — waits out the full
# budget on failures that are already terminal. This polls, reports progress every round, and
# bails early with the real cause when nothing is reconciling.
set -euo pipefail

CTX="${CONTEXT:?CONTEXT not set}"
BUDGET="${GOLDEN_TIMEOUT:-360}"        # seconds for ALL agents, not each
INTERVAL=15
STALL_AFTER="${GOLDEN_STALL_AFTER:-90}" # give up early if nothing has even started by now

echo "── golden snapshots (budget ${BUDGET}s for all agents)"

AGENTS="$(kubectl --context "$CTX" get sandboxagents.kagent.dev -n kagent \
  -l solomog.io/bundle=kagent-substrate \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)"
if [ -z "$AGENTS" ]; then
  echo "  ✗ no SandboxAgents labelled solomog.io/bundle=kagent-substrate"
  exit 1
fi
TOTAL="$(printf '%s\n' "$AGENTS" | grep -c .)"

# Print why substrate is not reconciling, then stop. The SandboxAgent condition only ever
# says "ActorTemplate golden snapshot is not ready", which is the symptom; the cause is an
# ate-controller reconcile error, and it is worth putting on screen rather than making the
# reader go find it.
explain_and_die() {
  echo
  echo "    Substrate is not baking goldens. Last ate-controller error:"
  kubectl --context "$CTX" logs -n ate-system deploy/ate-controller --tail=200 2>/dev/null \
    | grep -oE '"error": "[^"]*"' | tail -1 | sed 's/^/      /'
  cat <<EOF

    Common causes, most likely first:
      · jwks_uri unreachable — "invalid bearer token: while discovering keys from issuer"
        means the apiserver advertises a loopback jwks_uri. tests/10 and 00-preflight.sh
        both check for this; recreate with vind:create + the bundle's VCLUSTER_VALUES file.
      · gVisor cannot start a sandbox on this node — look for runsc errors in:
        kubectl --context $CTX logs -n ate-system ds/atelet --tail=100
      · no worker has capacity:
        kubectl --context $CTX get pods -n kagent | grep kagent-default
EOF
  exit 1
}

ELAPSED=0
while :; do
  READY=0
  for a in $AGENTS; do
    S="$(kubectl --context "$CTX" get "sandboxagent/$a" -n kagent \
      -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null)"
    [ "$S" = "True" ] && READY=$((READY + 1))
  done

  # How many ActorTemplates substrate has actually begun working on. Status stays completely
  # empty when the ate-controller cannot talk to ate-api at all, which is the signature of a
  # stuck install rather than a slow one.
  STARTED="$(kubectl --context "$CTX" get actortemplates.ate.dev -n kagent -o json 2>/dev/null \
    | python3 -c 'import json,sys; print(sum(1 for i in json.load(sys.stdin)["items"] if i.get("status")))' 2>/dev/null || echo 0)"

  echo "  [${ELAPSED}s] ready ${READY}/${TOTAL} · ActorTemplates with status: ${STARTED}/${TOTAL}"

  if [ "$READY" -eq "$TOTAL" ]; then
    echo "  ✓ all ${TOTAL} agents Ready — gVisor baked a golden snapshot for each"
    kubectl --context "$CTX" get actortemplates.ate.dev -n kagent \
      -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,SANDBOX:.spec.sandboxClass' \
      --no-headers 2>/dev/null | sed 's/^/    /'
    exit 0
  fi

  if [ "$ELAPSED" -ge "$STALL_AFTER" ] && [ "${STARTED:-0}" -eq 0 ]; then
    echo "  ✗ no ActorTemplate has any status after ${ELAPSED}s — nothing is reconciling them."
    explain_and_die
  fi

  if [ "$ELAPSED" -ge "$BUDGET" ]; then
    echo "  ✗ ${READY}/${TOTAL} Ready after ${BUDGET}s"
    explain_and_die
  fi

  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done
