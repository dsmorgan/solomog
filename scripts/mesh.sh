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
#              traffic traverses east-west gateways. mesh-eastwest.sh exposes + links
#              them declaratively (no Solo istioctl) and networking.sh routes to the
#              peer east-west gateway IPs. Ref (istioctl equivalent + concepts):
#              https://docs.solo.io/istio/1.30.x/quickstart/multi/
#
# Environment:
#   EDITION      enterprise (default) | community
#   ISTIO_MODE   ambient (default) | sidecar
#
# Usage: mesh.sh <topology> <cluster> <cluster> [<cluster> ...]
#   e.g. mesh.sh flat cluster-one cluster-two

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_DIR/scripts/lib/ui.sh"
EDITION="${EDITION:-enterprise}"
ISTIO_MODE="${ISTIO_MODE:-ambient}"

if [[ $# -lt 3 ]]; then
  echo "Usage: mesh.sh <flat|gateway> <cluster> <cluster> [<cluster> ...]" >&2
  exit 1
fi

TOPOLOGY="$1"; shift
CLUSTERS=("$@")

if [[ "$TOPOLOGY" != "flat" && "$TOPOLOGY" != "gateway" ]]; then
  echo "Error: unknown topology '$TOPOLOGY' (expected flat or gateway)." >&2
  echo "Usage: mesh.sh <flat|gateway> <cluster> <cluster> [<cluster> ...]" >&2
  exit 1
fi

solomog_clock_reset

# 1. Create all clusters
solomog_step "Create clusters: ${CLUSTERS[*]}  (topology=${TOPOLOGY}, edition=${EDITION}, mode=${ISTIO_MODE})"
bash "$REPO_DIR/scripts/vind-create.sh" "${CLUSTERS[@]}"

# 2. Flat topology needs host-level pod routing between cluster bridges
if [[ "$TOPOLOGY" == "flat" ]]; then
  solomog_step "Wire flat-network routing between: ${CLUSTERS[*]}"
  bash "$REPO_DIR/scripts/networking.sh" flat "${CLUSTERS[@]}"
fi

# 3. Shared root CA + per-cluster cacerts (one root CA reused across all clusters)
solomog_step "Generate one shared root CA + per-cluster cacerts"
bash "$REPO_DIR/scripts/gen-certs.sh" "${CLUSTERS[@]}"

# 4. Install Istio onto each cluster via the istio product module.
# Per-cluster Istio version overrides (ISTIO_VERSION_CLUSTER_TWO, _THREE, ...)
# enable mixed-version meshes; otherwise the shared ISTIO_VERSION is used.
SUMMARY_LINES=()
for cluster in "${CLUSTERS[@]}"; do
  ctx="vcluster-docker_${cluster}"
  if [[ "$TOPOLOGY" == "flat" ]]; then
    network="solomog"          # shared network → flat
  else
    network="$cluster"         # per-cluster network → multi-network
  fi

  # cluster-two → ISTIO_VERSION_CLUSTER_TWO, etc. Falls back to ISTIO_VERSION.
  suffix="$(echo "$cluster" | tr '[:lower:]-' '[:upper:]_')"
  override_var="ISTIO_VERSION_${suffix}"
  cluster_version="${!override_var:-${ISTIO_VERSION:-}}"

  solomog_step "Install Istio onto ${cluster}  (network=${network}, version=${cluster_version:-default}, mode=${ISTIO_MODE})"
  # `env` (not a bare prefix) so the conditional ISTIO_VERSION assignment works: an inline
  # env-prefix that comes from an expansion (${cluster_version:+VAR=val}) is NOT recognized as
  # an assignment by bash — it'd be run as a command ("ISTIO_VERSION=1.30.1: command not found").
  # env parses its NAME=VALUE args at runtime, and the word expands to nothing when unset.
  env SOLO_CONTEXT="$ctx" SOLO_CLUSTER="$cluster" SOLO_NETWORK="$network" ISTIO_MODE="$ISTIO_MODE" \
    ${cluster_version:+ISTIO_VERSION="$cluster_version"} \
    helmfile sync \
      -f "$REPO_DIR/helmfiles/products/istio.yaml.gotmpl" \
      -e "$EDITION" \
      --kube-context "$ctx"
  SUMMARY_LINES+=("${cluster}  →  context vcluster-docker_${cluster} (network ${network})")
done

# 5. Gateway topology: expose east-west gateways, wire routing to the peer gateway IPs, and link
#    the clusters (declarative — no Solo istioctl needed). Runs after the Istio install so the
#    istio-eastwest/istio-remote GatewayClasses exist. (flat wired its pod routing back in step 2.)
if [[ "$TOPOLOGY" == "gateway" ]]; then
  bash "$REPO_DIR/scripts/mesh-eastwest.sh" "${CLUSTERS[@]}"
fi

# Host routing (both topologies) lives in the Docker Desktop VM and is wiped by a Docker restart.
EXTRA="inter-cluster routing is ephemeral — re-run 'solomog net:repair CLUSTERS=\"${CLUSTERS[*]}\"' after a Docker Desktop restart"
[[ "$TOPOLOGY" == "gateway" ]] && EXTRA="east-west gateways exposed + linked. ${EXTRA}"
solomog_summary \
  "Mesh ready: ${#CLUSTERS[@]} clusters, ${TOPOLOGY} topology (${EDITION}, ${ISTIO_MODE})" \
  "${SUMMARY_LINES[@]}" \
  "shared root CA across all clusters (certs/)" \
  "$EXTRA"
