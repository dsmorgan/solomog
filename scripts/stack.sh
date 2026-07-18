#!/usr/bin/env bash
set -euo pipefail
#
# Composes one or more Solo products onto a single cluster.
# Creates the cluster, generates Istio certs if a mesh product is requested,
# then installs each product (in canonical dependency order) via its helmfile module.
#
# Products are installed in this fixed order regardless of argument order, so
# dependencies resolve correctly (mesh before gateways):
#     istio → gloo-mesh → kgateway → gloo-gateway → agentgateway
#
# Environment:
#   EDITION          enterprise (default) | community   — passed through to helmfile
#   ISTIO_MODE       ambient (default) | sidecar        — used by the istio module
#   TOKEN_EXCHANGE   true — after installing agentgateway (enterprise only), restart its
#                    data-plane proxy so it picks up the new STS/JWKS config. The proxy
#                    doesn't learn this dynamically via xDS, so a restart is required —
#                    see the agentgateway product module for the tokenExchange values
#                    this gates. No-ops safely if the agw deployment doesn't exist yet.
#
# Usage: stack.sh <cluster-name> <product> [<product> ...]
#   e.g. stack.sh cluster-one istio kgateway agentgateway

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCTS_DIR="$REPO_DIR/helmfiles/products"
source "$REPO_DIR/scripts/lib/ui.sh"
source "$REPO_DIR/scripts/lib/target.sh"

EDITION="${EDITION:-enterprise}"

# Namespace each product lands in (for the final summary).
ns_for() {
  case "$1" in
    istio)        echo "istio-system" ;;
    gloo-mesh)    echo "gloo-mesh" ;;
    kgateway)     echo "kgateway-system" ;;
    gloo-gateway) echo "gloo-system" ;;
    agentgateway) echo "agentgateway-system" ;;
    *)            echo "?" ;;
  esac
}

# Detect an omitted CLUSTER. The Taskfile passes `<CLUSTER> <product...>`; with CLUSTER unset the
# args collapse so the first one is actually a product (or nothing). A cluster name is never a bare
# product keyword, so treat that as "no cluster" and fail with the standard message rather than
# silently using a product name as the cluster.
case "${1:-}" in
  ""|istio|gloo-mesh|kgateway|gloo-gateway|agentgateway)
    solomog_require_cluster "" "this task (usage: solomog <product> CLUSTER=<name>)" ;;
esac

if [[ $# -lt 2 ]]; then
  echo "Usage: stack.sh <cluster-name> <product> [<product> ...]" >&2
  # TODO: usage list omits gloo-gateway (it is in CANONICAL_ORDER below).
  echo "  products: istio gloo-mesh kgateway agentgateway" >&2
  exit 1
fi

CLUSTER="$1"; shift
REQUESTED=("$@")
CTX="$(solomog_context "$CLUSTER")"

# Canonical install order — append new products here as modules are added.
CANONICAL_ORDER=(istio gloo-mesh kgateway gloo-gateway agentgateway)

# Validate every requested product has a module.
for p in "${REQUESTED[@]}"; do
  if [[ ! -f "$PRODUCTS_DIR/${p}.yaml.gotmpl" ]]; then
    echo "Error: unknown product '${p}' (no helmfiles/products/${p}.yaml.gotmpl)" >&2
    echo "Available: $(cd "$PRODUCTS_DIR" && ls *.yaml.gotmpl | sed 's/.yaml.gotmpl//' | tr '\n' ' ')" >&2
    exit 1
  fi
done

requested() {
  local needle="$1"
  for p in "${REQUESTED[@]}"; do [[ "$p" == "$needle" ]] && return 0; done
  return 1
}

solomog_clock_reset

# 1. Create the cluster — vind only. For an external target (CONTEXT set, e.g. EKS) the
#    cluster already exists out-of-band; solomog installs onto it but never creates it.
if solomog_is_external "$CLUSTER"; then
  solomog_step "External target ${CTX} — skipping cluster create (installing onto existing context)"
  if ! kubectl --context "$CTX" version -o json >/dev/null 2>&1; then
    echo "Error: kube context '${CTX}' is not reachable. Check: kubectl --context ${CTX} get ns" >&2
    exit 1
  fi
else
  solomog_step "Create cluster: ${CLUSTER}  (edition=${EDITION}, products=[${REQUESTED[*]}])"
  bash "$REPO_DIR/scripts/vind-create.sh" "$CLUSTER"
fi

# 2. Generate shared Istio certs if any mesh product is in the stack
if requested istio || requested gloo-mesh; then
  solomog_step "Generate shared root CA + cacerts for ${CLUSTER}"
  bash "$REPO_DIR/scripts/gen-certs.sh" "$CLUSTER"
fi

# 3. Install each requested product in canonical order.
# Exported so helmfile hooks / the istio ServiceMeshController target this cluster.
export SOLO_CONTEXT="$CTX"
export SOLO_CLUSTER="$CLUSTER"
export SOLO_NETWORK="$CLUSTER"
SUMMARY_LINES=()
for product in "${CANONICAL_ORDER[@]}"; do
  requested "$product" || continue
  solomog_step "Install ${product} onto ${CTX}  (edition=${EDITION})"
  helmfile sync \
    -f "$PRODUCTS_DIR/${product}.yaml.gotmpl" \
    -e "$EDITION" \
    --kube-context "$CTX"
  SUMMARY_LINES+=("${product}  →  namespace $(ns_for "$product")")

  # OBO token exchange: the agw data-plane proxy doesn't pick up the controller's new
  # STS/JWKS config dynamically, so restart it. Only when this invocation actually asked
  # for it — TOKEN_EXCHANGE is CLI-only (see Taskfile), never silently inherited from .env.
  if [[ "$product" == "agentgateway" && "$EDITION" == "enterprise" && "${TOKEN_EXCHANGE:-false}" == "true" ]]; then
    # TODO: label selector hardcodes gateway-name=agw — custom NAME= gateways are never restarted.
    solomog_step "Restart agw data-plane proxy (token exchange enabled)"
    kubectl --context "$CTX" rollout restart deployment -n agentgateway-system -l gateway.networking.k8s.io/gateway-name=agw
    kubectl --context "$CTX" rollout status  deployment -n agentgateway-system -l gateway.networking.k8s.io/gateway-name=agw
  fi
done

solomog_summary \
  "Stack ready: cluster '${CLUSTER}' (${EDITION})" \
  "context:  ${CTX}" \
  "${SUMMARY_LINES[@]}" \
  "inspect:  kubectl --context ${CTX} get pods -A"
