#!/usr/bin/env bash
set -euo pipefail
#
# Gateway (multi-network) topology only: expose an east-west gateway on each cluster, wire the
# host-level routing so each cluster can reach the peers' east-west gateway IPs, then link every
# cluster to every other. Purely declarative (kubectl) — the manifests replicate exactly what
# `istioctl multicluster expose|link` emits, so solomog needs no Solo istioctl binary.
#
# In this topology each cluster's Istio network == its name (see mesh.sh), so a peer's network,
# `topology.istio.io/cluster` label, and trust-domain are all just the peer's cluster name.
#
# Usage: mesh-eastwest.sh <cluster> <cluster> [<cluster> ...]

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_DIR/scripts/lib/ui.sh"
CLUSTERS=("$@")
[[ ${#CLUSTERS[@]} -ge 2 ]] || { echo "Usage: mesh-eastwest.sh <cluster> <cluster> [...]" >&2; exit 1; }

# east-west gateway address of a cluster, waiting until the vcluster LB assigns it.
ew_ip() {
  local ctx="vcluster-docker_$1" ip="" n=0
  while [ $n -lt 60 ]; do
    ip=$(kubectl --context "$ctx" -n istio-gateways get gateway istio-eastwest \
      -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
    [ -n "$ip" ] && { printf '%s' "$ip"; return 0; }
    sleep 2; n=$((n + 1))
  done
  echo "ERROR: east-west gateway IP for '$1' never became available" >&2; return 1
}

# 1. Expose: istio-gateways ns + istio-eastwest Gateway on each cluster.
solomog_step "Expose east-west gateways (istio-gateways ns) on: ${CLUSTERS[*]}"
for cluster in "${CLUSTERS[@]}"; do
  ctx="vcluster-docker_${cluster}"
  kubectl --context "$ctx" create namespace istio-gateways \
    --dry-run=client -o yaml | kubectl --context "$ctx" apply -f - >/dev/null
  kubectl --context "$ctx" apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: istio-eastwest
  namespace: istio-gateways
  labels:
    istio.io/expose-istiod: "15012"
    topology.istio.io/cluster: ${cluster}
    topology.istio.io/network: ${cluster}
  annotations:
    peering.solo.io/data-plane-service-type: loadbalancer
spec:
  gatewayClassName: istio-eastwest
  listeners:
  - name: cross-network
    port: 15008
    protocol: HBONE
    allowedRoutes: { namespaces: { from: Same } }
    tls: { mode: Passthrough }
  - name: xds-tls
    port: 15012
    protocol: TLS
    allowedRoutes: { namespaces: { from: Same } }
    tls: { mode: Passthrough }
EOF
done

# 2. Route: host-level bridge routing to the peer east-west gateway /32s (waits for the LB IPs).
bash "$REPO_DIR/scripts/networking.sh" gateway "${CLUSTERS[@]}"

# 3. Link: on each cluster, one istio-remote-peer-<peer> Gateway per OTHER cluster, addressed to
#    that peer's east-west gateway IP. NB the remote peer advertises only the xds-tls (15012)
#    listener — that's what istioctl emits (the data path uses the cross-network listener above).
solomog_step "Link clusters (remote-peer gateways): ${CLUSTERS[*]}"
for a in "${CLUSTERS[@]}"; do
  ctx="vcluster-docker_${a}"
  for b in "${CLUSTERS[@]}"; do
    [[ "$a" == "$b" ]] && continue
    bip="$(ew_ip "$b")" || exit 1
    kubectl --context "$ctx" apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: istio-remote-peer-${b}
  namespace: istio-gateways
  labels:
    topology.istio.io/cluster: ${b}
    topology.istio.io/network: ${b}
  annotations:
    gateway.istio.io/service-account: istio-eastwest
    gateway.istio.io/trust-domain: ${b}
    peering.solo.io/preferred-data-plane-service-type: loadbalancer
spec:
  gatewayClassName: istio-remote
  addresses:
  - type: IPAddress
    value: ${bip}
  listeners:
  - name: xds-tls
    port: 15012
    protocol: TLS
    allowedRoutes: { namespaces: { from: Same } }
    tls: { mode: Passthrough }
EOF
  done
done

echo "==> East-west gateways exposed + linked across: ${CLUSTERS[*]}"
