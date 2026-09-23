#!/usr/bin/env bash
# Agent Substrate platform into ate-system.
#
# Pin rationale (full evidence in docs/findings.md): 0.0.9 is what kagent 0.10.x's go.mod
# replaces github.com/agent-substrate/substrate with, so it is the client/server pairing
# kagent actually tests. It is also the newest line that installs with helm ALONE —
# 0.0.13+ dropped the jwt bootstrap, made the podcert path unconditional, and mount CA-pool
# Secrets that no chart template creates.
set -euo pipefail

CTX="${CONTEXT:?CONTEXT not set — solomog sets this for bundle hooks}"
SUBSTRATE_VERSION="${SUBSTRATE_VERSION:-0.0.9}"

# Docker Desktop's credential helper wedges on ghcr.io for minutes at a time, and helm
# blocks shelling out to it before it makes a single request. These charts are public, so
# pull anonymously through an empty docker config. Unset SOLOMOG_HELM_ANON to opt out.
if [ "${SOLOMOG_HELM_ANON:-true}" = "true" ]; then
  _ANON_CFG="$(mktemp -d)"
  echo '{}' > "$_ANON_CFG/config.json"
  export DOCKER_CONFIG="$_ANON_CFG"
  trap 'rm -rf "$_ANON_CFG"' EXIT
fi

echo "==> Agent Substrate ${SUBSTRATE_VERSION} → ate-system"

helm --kube-context "$CTX" upgrade --install substrate-crds \
  "oci://ghcr.io/kagent-dev/substrate/helm/substrate-crds" \
  --version "$SUBSTRATE_VERSION" \
  --namespace ate-system --create-namespace --wait

SET_ARGS=""
if [ -n "${SUBSTRATE_SA_ISSUER:-}" ]; then
  echo "    service-account issuer override: ${SUBSTRATE_SA_ISSUER}"
  SET_ARGS="--set auth.jwt.issuer=${SUBSTRATE_SA_ISSUER}"
fi

# 10m, not the 5m default: the install pulls ~570MB of third-party images (postgres,
# valkey, rustfs, agentgateway, coredns) and whatever lands at the back of the pull queue
# misses a shorter deadline on a single-node cluster.
# shellcheck disable=SC2086
helm --kube-context "$CTX" upgrade --install substrate \
  "oci://ghcr.io/kagent-dev/substrate/helm/substrate" \
  --version "$SUBSTRATE_VERSION" \
  --namespace ate-system --wait --timeout 10m $SET_ARGS

# ── valkey topology gate ─────────────────────────────────────────────────────
# substrate 0.0.9 keeps actor records in a 6-node valkey cluster. If it comes up with a
# bad topology, ate-api-server never finishes its connect retries and CrashLoopBackOffs
# indefinitely — hundreds of restarts later it still looks like a substrate bug. Catch it
# here, where the cause is still legible.
echo "    checking valkey cluster state"
i=0
while [ "$i" -lt 30 ]; do
  STATE="$(kubectl --context "$CTX" exec -n ate-system valkey-cluster-0 -- \
    redis-cli -p 6379 cluster info 2>/dev/null | tr -d '\r' \
    | awk -F: '/^cluster_state:/{print $2}')"
  if [ "$STATE" = "ok" ]; then
    echo "    ✓ valkey cluster_state:ok"
    break
  fi
  i=$((i + 1))
  if [ "$i" -ge 30 ]; then
    echo "    ✗ valkey cluster_state='${STATE:-unknown}' after 150s — stop here." >&2
    echo "      A wedged valkey cannot be repaired in place; delete the cluster and rebuild." >&2
    exit 1
  fi
  sleep 5
done

kubectl --context "$CTX" get pods -n ate-system
