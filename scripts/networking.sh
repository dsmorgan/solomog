#!/usr/bin/env bash
set -euo pipefail
#
# Sets up inter-cluster pod-network routing between vcluster instances on Docker Desktop.
# Injects bidirectional nftables rules into the Docker Desktop VM via nsenter.
#
# For "gateway" mode (east-west gateway topology) this is a no-op — traffic routes through
# Istio east-west gateways and no host-level routing is needed.
#
# Rules are EPHEMERAL: they must be re-run after Docker Desktop restarts.
#
# Usage: networking.sh <mode> <cluster-one> <cluster-two> [<cluster-three>]
#   mode: flat | gateway

MODE="${1:?Usage: networking.sh <flat|gateway> <cluster...>}"
shift
CLUSTERS=("$@")

if [[ "${MODE}" == "gateway" ]]; then
  echo "==> Topology: east-west gateways — skipping host network routing"
  echo "    Cross-cluster traffic will route through Istio east-west gateways."
  exit 0
fi

if [[ ${#CLUSTERS[@]} -lt 2 ]]; then
  echo "Error: flat mode requires at least 2 cluster names" >&2
  exit 1
fi

echo "==> Setting up flat-network routing between: ${CLUSTERS[*]}"

get_bridge() {
  local cluster="$1"
  local net_id
  # vcluster creates a Docker network named after the cluster; try both patterns
  net_id=$(
    docker network inspect "vcluster.${cluster}" --format '{{.Id}}' 2>/dev/null \
    || docker network inspect "${cluster}" --format '{{.Id}}' 2>/dev/null \
    || { echo "ERROR: Docker network for cluster '${cluster}' not found" >&2; exit 1; }
  )
  echo "br-${net_id:0:12}"
}

declare -a BRIDGES
for cluster in "${CLUSTERS[@]}"; do
  bridge=$(get_bridge "$cluster")
  BRIDGES+=("$bridge")
  echo "    $cluster → $bridge"
done

echo "==> Injecting nftables rules into Docker Desktop VM..."

# Build rule-add commands (idempotent: check before inserting)
nft_cmds=""
for i in "${!BRIDGES[@]}"; do
  for j in "${!BRIDGES[@]}"; do
    [[ "$i" == "$j" ]] && continue
    br_from="${BRIDGES[$i]}"
    br_to="${BRIDGES[$j]}"
    rule="iifname \\\"${br_from}\\\" oifname \\\"${br_to}\\\" counter accept"
    nft_cmds+="
      nft list chain ip solomog forward 2>/dev/null | grep -qF '${br_from}' \
        || nft add rule ip solomog forward ${rule};"
  done
done

docker run --rm --privileged --pid=host alpine:3.19 \
  nsenter -t 1 -m -u -n -i -- sh -c "
    nft list table ip solomog 2>/dev/null \
      || nft add table ip solomog
    nft list chain ip solomog forward 2>/dev/null \
      || nft add chain ip solomog forward '{ type filter hook forward priority 0; policy accept; }'
    ${nft_cmds}
    echo 'Current solomog forward rules:'
    nft list chain ip solomog forward
  "

echo ""
echo "==> Flat-network routing configured."
echo "    Note: rules are ephemeral — re-run after Docker Desktop restarts."
