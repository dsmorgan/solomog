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
# shellcheck source=lib/target.sh
source "$REPO_DIR/scripts/lib/target.sh"
CLUSTERS=("$@")
[[ ${#CLUSTERS[@]} -ge 2 ]] || { echo "Usage: mesh-eastwest.sh <cluster> <cluster> [...]" >&2; exit 1; }

# east-west GatewayClass name — Solo enterprise registers "istio-eastwest", upstream
# community registers "istio-east-west" (only with AMBIENT_ENABLE_MULTI_NETWORK on,
# which mesh.sh sets for gateway topology). Waits briefly: the class appears a beat
# after istiod starts.
ew_class() {   # args: <ctx>
  local n=0
  while [ $n -lt 30 ]; do
    kubectl --context "$1" get gatewayclass istio-eastwest  >/dev/null 2>&1 && { echo istio-eastwest;  return 0; }
    kubectl --context "$1" get gatewayclass istio-east-west >/dev/null 2>&1 && { echo istio-east-west; return 0; }
    sleep 2; n=$((n + 1))
  done
  echo "ERROR: no east-west GatewayClass (istio-eastwest / istio-east-west) on $1 — is istiod up with multi-network enabled?" >&2
  return 1
}

# east-west gateway address of a cluster, waiting until the vcluster LB assigns it.
ew_ip() {
  local ctx ip="" n=0; ctx="$(solomog_context "$1")"
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
  ctx="$(solomog_context "$cluster")"
  EW_CLASS="$(ew_class "$ctx")" || exit 1
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
  gatewayClassName: ${EW_CLASS}
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
# vind only — external (vsphere) east-west gateways sit on real MetalLB IPs that are
# already routable on the LAN, so there is nothing to wire (and nothing that decays).
if solomog_is_external "${CLUSTERS[0]}"; then
  solomog_step "Skip host routing — external clusters peer over real LB IPs"
else
  bash "$REPO_DIR/scripts/networking.sh" gateway "${CLUSTERS[@]}"
fi

# 3. Link: on each cluster, one istio-remote-peer-<peer> Gateway per OTHER cluster, addressed to
#    that peer's east-west gateway IP. The manifest shape is flavor-specific:
#      Solo enterprise (class istio-eastwest): per-cluster trust domains (= cluster
#        name) and only the xds-tls (15012) listener — as Solo istioctl emits.
#      upstream community (class istio-east-west): everything lives in the default
#        cluster.local trust domain, and the remote peer must ALSO advertise the
#        cross-network (15008) listener or ztunnel never learns the remote data path
#        — as upstream `istioctl multicluster link` emits.
solomog_step "Link clusters (remote-peer gateways): ${CLUSTERS[*]}"
FLAVOR_CLASS="$(ew_class "$(solomog_context "${CLUSTERS[0]}")")" || exit 1
for a in "${CLUSTERS[@]}"; do
  ctx="$(solomog_context "$a")"
  for b in "${CLUSTERS[@]}"; do
    [[ "$a" == "$b" ]] && continue
    bip="$(ew_ip "$b")" || exit 1
    if [[ "$FLAVOR_CLASS" == "istio-eastwest" ]]; then trust_domain="$b"; else trust_domain="cluster.local"; fi
    cross_network=""
    [[ "$FLAVOR_CLASS" == "istio-east-west" ]] && cross_network="
  - name: cross-network
    port: 15008
    protocol: HBONE
    allowedRoutes: { namespaces: { from: Same } }
    tls: { mode: Passthrough }"
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
    gateway.istio.io/trust-domain: ${trust_domain}
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
    tls: { mode: Passthrough }${cross_network}
EOF
  done
done

# 4. Upstream community only: cross-cluster SERVICE DISCOVERY. The ambient east-west
#    gateway carries data-plane traffic but cannot expose istiod across networks
#    (upstream limitation), so discovery uses the classic multi-primary mechanism —
#    each istiod reads the peer's API server via a "remote secret" (a kubeconfig for
#    the peer's istio-reader SA, labeled istio/multiCluster=true). This replicates
#    `istioctl create-remote-secret` with plain kubectl: a long-lived SA token secret
#    on the peer + a kubeconfig secret locally. Needs istiod→peer-API reachability
#    (vsphere: same VLAN, fine). Solo enterprise discovers through its own peering.
if [[ "$FLAVOR_CLASS" == "istio-east-west" ]]; then
  solomog_step "Exchange remote secrets (upstream API-server discovery): ${CLUSTERS[*]}"

  remote_kubeconfig() {   # args: <cluster> — emits a kubeconfig for its istio-reader SA
    local ctx token ca server n=0
    ctx="$(solomog_context "$1")"
    kubectl --context "$ctx" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: istio-reader-token-solomog
  namespace: istio-system
  annotations:
    kubernetes.io/service-account.name: istio-reader-service-account
type: kubernetes.io/service-account-token
EOF
    while [ $n -lt 30 ]; do
      token="$(kubectl --context "$ctx" get secret istio-reader-token-solomog -n istio-system \
        -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || true)"
      [ -n "$token" ] && break; sleep 2; n=$((n + 1))
    done
    [ -n "$token" ] || { echo "ERROR: istio-reader token for '$1' never populated" >&2; return 1; }
    # ca gets the same non-empty check as token/server: an empty ca.crt yields a
    # kubeconfig that APPLIES cleanly but only fails later as istiod TLS errors
    # reading the peer API — miserable to trace back here.
    ca="$(kubectl --context "$ctx" get secret istio-reader-token-solomog -n istio-system -o jsonpath='{.data.ca\.crt}' 2>/dev/null || true)"
    [ -n "$ca" ] || { echo "ERROR: istio-reader ca.crt for '$1' is empty — cannot build a working remote secret" >&2; return 1; }
    server="$(kubectl config view -o jsonpath="{.clusters[?(@.name=='$ctx')].cluster.server}")"
    [ -n "$server" ] || { echo "ERROR: no kubeconfig cluster entry '$ctx'" >&2; return 1; }
    # vind's docker driver writes a Mac-local API address into the kubeconfig; a peer
    # istiod can't reach it, so discovery would come up silently broken. Warn loudly.
    case "$server" in
      *127.0.0.1*|*localhost*)
        echo "    WARNING: '$1' API server is ${server} — a local-only address that peer istiods" >&2
        echo "             likely cannot reach. If cross-cluster discovery stays broken (check with" >&2
        echo "             'istioctl remote-clusters'), this is why." >&2 ;;
    esac
    cat <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: ${ca}
    server: ${server}
  name: ${1}
contexts:
- context: {cluster: ${1}, user: ${1}}
  name: ${1}
current-context: ${1}
users:
- name: ${1}
  user: {token: ${token}}
EOF
  }

  for a in "${CLUSTERS[@]}"; do
    ctx="$(solomog_context "$a")"
    for b in "${CLUSTERS[@]}"; do
      [[ "$a" == "$b" ]] && continue
      kc="$(remote_kubeconfig "$b")" || exit 1
      kubectl --context "$ctx" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: istio-remote-secret-${b}
  namespace: istio-system
  labels:
    istio/multiCluster: "true"
  annotations:
    networking.istio.io/cluster: ${b}
stringData:
  ${b}: |
$(printf '%s\n' "$kc" | sed 's/^/    /')
EOF
      echo "    ${a} ← reads ${b}'s API (istio-remote-secret-${b})"
    done
  done
fi

echo "==> East-west gateways exposed + linked across: ${CLUSTERS[*]}"
