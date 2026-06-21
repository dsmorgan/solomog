#!/usr/bin/env bash
set -euo pipefail
#
# Creates vcluster instances using the docker driver (vcluster-in-Docker) with
# default config, then connects each so a kube context exists.
#
# Context naming: the docker driver registers contexts as `vcluster-docker_<name>`
# (note: the Docker *network* is `vcluster.<name>` — different; see networking.sh).
#
# Usage: vind-create.sh <cluster-name> [<cluster-name> ...]

if [[ $# -eq 0 ]]; then
  echo "Usage: vind-create.sh <cluster-name> [<cluster-name> ...]" >&2
  exit 1
fi

CLUSTERS=("$@")

if ! command -v vcluster &>/dev/null; then
  echo "Error: 'vcluster' not found in PATH" >&2
  exit 1
fi

for cluster in "${CLUSTERS[@]}"; do
  if vcluster list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$cluster"; then
    echo "==> Cluster '$cluster' already exists, skipping create"
  else
    echo "==> Creating cluster: $cluster (docker driver, default config)"
    vcluster create "$cluster" --driver docker --connect=false
  fi

  # Connect to register/refresh the kube context (vcluster-docker_<name>).
  # This also waits for the vcluster to be ready.
  echo "    Connecting (kube context: vcluster-docker_${cluster})"
  vcluster connect "$cluster"
done

echo ""
echo "Clusters ready:"
for cluster in "${CLUSTERS[@]}"; do
  echo "  kubectl --context vcluster-docker_${cluster} get pods -A"
done
