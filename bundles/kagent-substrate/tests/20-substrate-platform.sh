#!/usr/bin/env bash
# The substrate platform itself: every ate-system component up, valkey healthy.
#
# valkey gets its own assertion because its failure is the one that costs a day. A bad
# cluster topology leaves ate-api-server retrying its connection forever, and what you see
# is hundreds of CrashLoopBackOff restarts with no mention of valkey anywhere in the
# obvious logs.
set -euo pipefail

CTX="${CONTEXT:?CONTEXT not set}"
rc=0

echo "── substrate platform (ate-system)"

for crd in workerpools.ate.dev actortemplates.ate.dev sandboxconfigs.ate.dev; do
  if kubectl --context "$CTX" get crd "$crd" >/dev/null 2>&1; then
    echo "  ✓ CRD $crd"
  else
    echo "  ✗ CRD $crd missing — substrate-crds did not install"
    rc=1
  fi
done

# Count pods that are neither Running nor Completed. Init jobs legitimately end Completed,
# so a bare "not Running" check reports a healthy install as broken.
BAD="$(kubectl --context "$CTX" get pods -n ate-system --no-headers 2>/dev/null \
  | awk '$3 != "Running" && $3 != "Completed" {print "    " $1 " " $3}')"
if [ -z "$BAD" ]; then
  echo "  ✓ all ate-system pods Running or Completed"
else
  echo "  ✗ ate-system pods not settled:"
  printf '%s\n' "$BAD"
  rc=1
fi

# Each named component, so a missing Deployment is not hidden by an all-green pod list.
for app in ate-api-server ate-controller atenet-router; do
  N="$(kubectl --context "$CTX" get pods -n ate-system --no-headers 2>/dev/null \
    | grep -c "^${app}" || true)"
  if [ "${N:-0}" -ge 1 ]; then
    echo "  ✓ ${app} present"
  else
    echo "  ✗ ${app} has no pods"
    rc=1
  fi
done

# atelet is the DaemonSet that fetches the gVisor release and runs sandboxes on the node.
# If gVisor cannot run in this environment at all, this is the first place it shows.
DS="$(kubectl --context "$CTX" get ds -n ate-system --no-headers 2>/dev/null | grep '^atelet' || true)"
if [ -n "$DS" ]; then
  DESIRED="$(printf '%s' "$DS" | awk '{print $2}')"
  READY="$(printf '%s' "$DS" | awk '{print $4}')"
  if [ "${READY:-0}" = "${DESIRED:-x}" ] && [ "${READY:-0}" != "0" ]; then
    echo "  ✓ atelet ${READY}/${DESIRED} ready"
  else
    echo "  ✗ atelet ${READY:-0}/${DESIRED:-?} ready"
    echo "    atelet downloads the gVisor tarball and extracts runsc on the node."
    echo "    Read why:  kubectl --context $CTX logs -n ate-system ds/atelet --tail=50"
    rc=1
  fi
else
  echo "  ✗ no atelet DaemonSet"
  rc=1
fi

STATE="$(kubectl --context "$CTX" exec -n ate-system valkey-cluster-0 -- \
  redis-cli -p 6379 cluster info 2>/dev/null | tr -d '\r' \
  | awk -F: '/^cluster_state:/{print $2}')"
if [ "$STATE" = "ok" ]; then
  echo "  ✓ valkey cluster_state:ok"
else
  echo "  ✗ valkey cluster_state='${STATE:-unreadable}'"
  echo "    Not repairable in place — actor records are stored there. Rebuild the cluster."
  rc=1
fi

exit $rc
