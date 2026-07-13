#!/usr/bin/env bash
set -euo pipefail
#
# Host-level routing between vcluster Docker networks on Docker Desktop, so clusters in a
# multi-cluster Istio mesh can reach one another. Rules go in the Docker Desktop VM's DOCKER-USER
# chain — the one place an ACCEPT is terminal. (A private nft table's accept can NOT override
# Docker's inter-bridge isolation DROP: both are base chains on the forward hook and a DROP in any
# chain wins. FORWARD jumps to DOCKER-USER before DOCKER-FORWARD, so accepting there bypasses it.)
#
#   flat     → clusters share one Istio network; ztunnel sends pod-IP → pod-IP directly, so the
#              ENTIRE peer bridge must be routable (whole-subnet accept, both directions).
#   gateway  → clusters are separate Istio networks; cross-cluster traffic egresses through the
#              peer's east-west gateway, so ONLY that gateway's /32 needs to be reachable. Tighter,
#              and faithful to real multi-network — direct pod-to-pod stays blocked, as in prod.
#              The gateway IP is discovered live from `gateway istio-eastwest -n istio-gateways`.
#
# Rules are EPHEMERAL — they vanish when Docker Desktop restarts. Re-run (`solomog net:repair`)
# afterwards. No stored state: bridges derive from cluster names, gateway IPs from the live cluster.
#
# Usage: networking.sh <flat|gateway> <cluster> <cluster> [<cluster> ...]

MODE="${1:?Usage: networking.sh <flat|gateway> <cluster...>}"
shift
CLUSTERS=("$@")

case "$MODE" in
  flat)    echo "==> Flat network: routing whole peer subnets between: ${CLUSTERS[*]}" ;;
  gateway) echo "==> Gateway topology: routing to peer east-west gateway IPs between: ${CLUSTERS[*]}" ;;
  *) echo "Error: unknown mode '$MODE' (expected flat|gateway)" >&2; exit 1 ;;
esac

if [[ ${#CLUSTERS[@]} -lt 2 ]]; then
  echo "Error: ${MODE} mode requires at least 2 cluster names" >&2
  exit 1
fi

get_bridge() {
  local cluster="$1" net_id
  # vcluster names the network after the cluster; try both patterns.
  net_id=$(
    docker network inspect "vcluster.${cluster}" --format '{{.Id}}' 2>/dev/null \
    || docker network inspect "${cluster}" --format '{{.Id}}' 2>/dev/null \
    || { echo "ERROR: Docker network for cluster '${cluster}' not found" >&2; exit 1; }
  )
  echo "br-${net_id:0:12}"
}

# gateway mode: discover a cluster's east-west gateway IP, waiting until it's programmed.
get_ew_ip() {
  local ctx="vcluster-docker_$1" ip="" n=0
  while [ $n -lt 60 ]; do
    ip=$(kubectl --context "$ctx" -n istio-gateways get gateway istio-eastwest \
      -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
    [ -n "$ip" ] && { printf '%s' "$ip"; return 0; }
    sleep 2; n=$((n + 1))
  done
  echo "ERROR: east-west gateway IP for '$1' not available (is istio-eastwest exposed?)" >&2
  return 1
}

declare -a BRIDGES EWIPS
for cluster in "${CLUSTERS[@]}"; do
  bridge=$(get_bridge "$cluster")
  BRIDGES+=("$bridge")
  if [[ "$MODE" == "gateway" ]]; then
    ip=$(get_ew_ip "$cluster") || exit 1
    EWIPS+=("$ip")
    echo "    $cluster → $bridge  (east-west gw $ip)"
  else
    echo "    $cluster → $bridge"
  fi
done

# Build DOCKER-USER accept rules for every ordered bridge pair. Return traffic rides conntrack
# (Docker's DOCKER-CT ESTABLISHED,RELATED accept), so only the initiating direction is strictly
# needed — but we add both so either cluster may initiate. `-C` gives exact-match idempotency
# (the old `grep -qF <bridge>` guard skipped the reverse rule once both names were in the chain).
echo "==> Injecting DOCKER-USER accept rules into Docker Desktop VM..."
ipt_cmds="nft delete table ip solomog 2>/dev/null || true;"   # drop the old, ineffective table
for i in "${!BRIDGES[@]}"; do
  for j in "${!BRIDGES[@]}"; do
    [[ "$i" == "$j" ]] && continue
    f="${BRIDGES[$i]}"; t="${BRIDGES[$j]}"
    if [[ "$MODE" == "gateway" ]]; then
      match="-i ${f} -o ${t} -d ${EWIPS[$j]}/32 -j ACCEPT"   # only the peer's east-west gw /32
    else
      match="-i ${f} -o ${t} -j ACCEPT"                       # whole peer subnet
    fi
    ipt_cmds+="
      iptables -C DOCKER-USER ${match} 2>/dev/null || iptables -I DOCKER-USER ${match};"
  done
done

docker run --rm --privileged --pid=host alpine:3.19 \
  nsenter -t 1 -m -u -n -i -- sh -c "
    ${ipt_cmds}
    echo 'Inter-bridge ACCEPT rules now in DOCKER-USER:'
    iptables -S DOCKER-USER | grep -- '-i br-' || true
  "

echo ""
echo "==> Routing configured. Rules are ephemeral — re-run 'solomog net:repair' after a Docker Desktop restart."
