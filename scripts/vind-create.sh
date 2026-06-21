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

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Records the clusters solomog created, so teardown never touches hand-made clusters.
STATE_FILE="$REPO_DIR/.solomog/clusters"

if ! command -v vcluster &>/dev/null; then
  echo "Error: 'vcluster' not found in PATH" >&2
  exit 1
fi

# Record a cluster name as solomog-managed (idempotent).
record_cluster() {
  mkdir -p "$(dirname "$STATE_FILE")"
  touch "$STATE_FILE"
  grep -qxF "$1" "$STATE_FILE" || echo "$1" >> "$STATE_FILE"
}

for cluster in "${CLUSTERS[@]}"; do
  if vcluster list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$cluster"; then
    echo "==> Cluster '$cluster' already exists, skipping create"
  else
    echo "==> Creating cluster: $cluster (docker driver, default config)"
    vcluster create "$cluster" --driver docker --connect=false
  fi
  record_cluster "$cluster"

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
