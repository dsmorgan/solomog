#!/usr/bin/env bash
set -euo pipefail
#
# Creates named vcluster instances with unique pod/service CIDRs.
# Waits for all clusters to be Ready before returning.
#
# Usage: vind-create.sh <cluster-name> [<cluster-name> ...]

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ $# -eq 0 ]]; then
  echo "Usage: vind-create.sh <cluster-name> [<cluster-name> ...]" >&2
  exit 1
fi

CLUSTERS=("$@")

# Prefer vind; fall back to vcluster
if command -v vind &>/dev/null; then
  VCLUSTER_CMD=vind
elif command -v vcluster &>/dev/null; then
  VCLUSTER_CMD=vcluster
else
  echo "Error: neither 'vind' nor 'vcluster' found in PATH" >&2
  exit 1
fi

num_clusters=${#CLUSTERS[@]}
if [[ $num_clusters -eq 1 ]]; then
  CONFIG_TEMPLATE="$REPO_DIR/clusters/single.yaml"
elif [[ $num_clusters -eq 2 ]]; then
  CONFIG_TEMPLATE="$REPO_DIR/clusters/multi.yaml"
else
  CONFIG_TEMPLATE="$REPO_DIR/clusters/multi-3.yaml"
fi

for i in "${!CLUSTERS[@]}"; do
  cluster="${CLUSTERS[$i]}"
  cluster_num=$((i + 1))

  # Check if already exists
  if $VCLUSTER_CMD list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$cluster"; then
    echo "==> Cluster '$cluster' already exists, skipping"
    continue
  fi

  echo "==> Creating cluster: $cluster"

  # Generate a per-cluster config with unique CIDRs to avoid routing conflicts.
  # Pod:  10.<N>0.0.0/16  (10.10.0.0/16, 10.20.0.0/16, 10.30.0.0/16)
  # Svc:  10.1<N>.0.0/20  (10.11.0.0/20, 10.12.0.0/20, 10.13.0.0/20)
  pod_cidr="10.${cluster_num}0.0.0/16"
  svc_cidr="10.1${cluster_num}.0.0/20"

  tmp_config=$(mktemp /tmp/vcluster-XXXXXX.yaml)
  sed \
    -e "s|__CLUSTER_NAME__|${cluster}|g" \
    -e "s|__POD_CIDR__|${pod_cidr}|g" \
    -e "s|__SVC_CIDR__|${svc_cidr}|g" \
    "$CONFIG_TEMPLATE" > "$tmp_config"

  $VCLUSTER_CMD create "$cluster" -f "$tmp_config" --connect=false
  rm -f "$tmp_config"
done

echo ""
echo "==> Waiting for clusters to be Ready..."
for cluster in "${CLUSTERS[@]}"; do
  ctx="vcluster.${cluster}"
  echo -n "    $cluster "
  until kubectl --context "$ctx" get nodes &>/dev/null 2>&1; do
    echo -n "."
    sleep 3
  done
  kubectl --context "$ctx" wait --for=condition=Ready nodes --all --timeout=120s --quiet
  echo " ready"
done

echo ""
echo "Clusters available:"
for cluster in "${CLUSTERS[@]}"; do
  echo "  kubectl --context vcluster.${cluster} ..."
done
