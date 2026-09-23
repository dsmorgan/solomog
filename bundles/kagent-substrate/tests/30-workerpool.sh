#!/usr/bin/env bash
# The WorkerPool: pre-warmed gVisor sandboxes waiting for actors.
#
# This is the resource substrate-scope renders as the bays across the top of the board,
# and the one the UI's worker +/- buttons scale. Assert the label too: a pool without
# kagent.dev/worker-pool is invisible to the ActorTemplates kagent generates, and the
# symptom is agents that never leave Pending with nothing wrong in either log.
set -euo pipefail

CTX="${CONTEXT:?CONTEXT not set}"
POOL="${SUBSTRATE_WORKER_POOL:-kagent-default}"
rc=0

echo "── WorkerPool ${POOL}"

if ! kubectl --context "$CTX" get workerpool.ate.dev "$POOL" -n kagent >/dev/null 2>&1; then
  echo "  ✗ WorkerPool ${POOL} not found in namespace kagent"
  echo "    The kagent chart creates it when substrateWorkerPool.create=true."
  exit 1
fi

CLASS="$(kubectl --context "$CTX" get workerpool.ate.dev "$POOL" -n kagent \
  -o jsonpath='{.spec.sandboxClass}' 2>/dev/null)"
if [ "$CLASS" = "gvisor" ]; then
  echo "  ✓ sandboxClass gvisor"
else
  echo "  ✗ sandboxClass='${CLASS:-unset}' — kagent-generated ActorTemplates hardcode gvisor"
  rc=1
fi

LABEL="$(kubectl --context "$CTX" get workerpool.ate.dev "$POOL" -n kagent \
  -o jsonpath='{.metadata.labels.kagent\.dev/worker-pool}' 2>/dev/null)"
if [ "$LABEL" = "$POOL" ]; then
  echo "  ✓ carries kagent.dev/worker-pool=${POOL}"
else
  echo "  ✗ label kagent.dev/worker-pool='${LABEL:-unset}', expected '${POOL}'"
  echo "    Generated ActorTemplates select the pool by this label. Without it no actor"
  echo "    is ever placed, and neither controller logs an error."
  rc=1
fi

WANT="$(kubectl --context "$CTX" get workerpool.ate.dev "$POOL" -n kagent \
  -o jsonpath='{.spec.replicas}' 2>/dev/null)"
GOT="$(kubectl --context "$CTX" get pods -n kagent --no-headers 2>/dev/null \
  | grep "^${POOL}-" | grep -c ' Running ' || true)"
if [ "${GOT:-0}" -ge 1 ] && [ "${GOT:-0}" = "${WANT:-x}" ]; then
  echo "  ✓ ${GOT}/${WANT} workers Running"
elif [ "${GOT:-0}" -ge 1 ]; then
  # Not a failure on its own: substrate-scope's AUTOSCALE takes field ownership of
  # spec.replicas, so a scaled pool legitimately disagrees with the applied value.
  echo "  ✓ ${GOT} workers Running (spec says ${WANT:-?} — scope's autoscaler may own this field)"
else
  echo "  ✗ no Running workers for pool ${POOL}"
  echo "    kubectl --context $CTX get pods -n kagent | grep ${POOL}"
  rc=1
fi

exit $rc
