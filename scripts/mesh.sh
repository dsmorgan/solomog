#!/usr/bin/env bash
set -euo pipefail
#
# Stands up a multi-cluster Istio mesh by installing the istio product module
# (Gloo Operator + ServiceMeshController in enterprise; upstream charts in
# community) onto each cluster, with a shared root CA across all of them.
#
# Topology controls the Istio `network` assignment:
#   flat     → every cluster shares one network name ("solomog"); pod-to-pod
#              routing is wired by networking.sh. Simplest cross-cluster setup.
#   gateway  → each cluster gets its own network (multi-network); cross-cluster
#              traffic is meant to traverse east-west gateways.
#              NOTE: east-west gateway + endpoint-discovery wiring is not yet
#              automated here — see the multi-network steps in
#              https://docs.solo.io/istio/1.30.x/quickstart/multi/  (TODO).
#
# Environment:
#   EDITION      enterprise (default) | community
#   ISTIO_MODE   ambient (default) | sidecar
#
# Usage: mesh.sh <topology> <cluster> <cluster> [<cluster> ...]
#   e.g. mesh.sh flat cluster-one cluster-two

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EDITION="${EDITION:-enterprise}"
ISTIO_MODE="${ISTIO_MODE:-ambient}"

if [[ $# -lt 3 ]]; then
  echo "Usage: mesh.sh <flat|gateway> <cluster> <cluster> [<cluster> ...]" >&2
  exit 1
fi

TOPOLOGY="$1"; shift
CLUSTERS=("$@")

echo "==> Mesh: topology=${TOPOLOGY} edition=${EDITION} mode=${ISTIO_MODE} clusters=[${CLUSTERS[*]}]"

# 1. Create all clusters
bash "$REPO_DIR/scripts/vind-create.sh" "${CLUSTERS[@]}"

# 2. Flat topology needs host-level pod routing between cluster bridges
if [[ "$TOPOLOGY" == "flat" ]]; then
  bash "$REPO_DIR/scripts/networking.sh" flat "${CLUSTERS[@]}"
fi

# 3. Shared root CA + per-cluster cacerts (one root CA reused across all clusters)
bash "$REPO_DIR/scripts/gen-certs.sh" "${CLUSTERS[@]}"

# 4. Install Istio onto each cluster via the istio product module.
# Per-cluster Istio version overrides (ISTIO_VERSION_CLUSTER_TWO, _THREE, ...)
# enable mixed-version meshes; otherwise the shared ISTIO_VERSION is used.
for cluster in "${CLUSTERS[@]}"; do
  ctx="vcluster.${cluster}"
  if [[ "$TOPOLOGY" == "flat" ]]; then
    network="solomog"          # shared network → flat
  else
    network="$cluster"         # per-cluster network → multi-network
  fi

  # cluster-two → ISTIO_VERSION_CLUSTER_TWO, etc. Falls back to ISTIO_VERSION.
  suffix="$(echo "$cluster" | tr '[:lower:]-' '[:upper:]_')"
  override_var="ISTIO_VERSION_${suffix}"
  cluster_version="${!override_var:-${ISTIO_VERSION:-}}"

  echo ""
  echo "==> Installing Istio onto ${cluster} (network=${network}, version=${cluster_version:-default})"
  SOLO_CONTEXT="$ctx" SOLO_CLUSTER="$cluster" SOLO_NETWORK="$network" ISTIO_MODE="$ISTIO_MODE" \
  ${cluster_version:+ISTIO_VERSION="$cluster_version"} \
    helmfile sync \
      -f "$REPO_DIR/helmfiles/products/istio.yaml" \
      -e "$EDITION" \
      --kube-context "$ctx"
done

echo ""
echo "==> Mesh ready across: ${CLUSTERS[*]}"
if [[ "$TOPOLOGY" == "gateway" ]]; then
  echo "    NOTE: multi-network east-west gateway wiring is not yet automated (TODO)."
fi
