#!/usr/bin/env bash
set -euo pipefail
#
# Creates vcluster instances using the docker driver (vcluster-in-Docker), then connects
# each so a kube context exists. Default config unless VCLUSTER_VALUES names a file.
#
# Env:
#   VCLUSTER_VALUES  optional path to a vcluster config file, passed to `vcluster create -f`.
#                    For control-plane config solomog has no first-class knob for — e.g. a
#                    bundle that needs apiserver feature gates. CREATE-TIME ONLY: vcluster
#                    does not re-render an existing instance from a values file, so an
#                    already-existing cluster warns rather than silently ignoring it.
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
VALUES="${VCLUSTER_VALUES:-}"

if [ -n "$VALUES" ] && [ ! -f "$VALUES" ]; then
  echo "Error: VCLUSTER_VALUES='$VALUES' is not a readable file" >&2
  echo "  Pass a path relative to the repo root, or an absolute one." >&2
  exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Records the clusters solomog created (cluster:list / stale-prune). Destroy is
# name-explicit: `solomog teardown CLUSTER=…` / `vind:delete` never defaults to all.
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
    if [ -n "$VALUES" ]; then
      echo "    WARNING: VCLUSTER_VALUES was NOT applied — it takes effect only at create."
      echo "             To change control-plane config, destroy and recreate:"
      echo "               solomog teardown CLUSTER=$cluster"
    fi
  elif [ -n "$VALUES" ]; then
    echo "==> Creating cluster: $cluster (docker driver, config from $VALUES)"
    vcluster create "$cluster" --driver docker --connect=false -f "$VALUES"
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
