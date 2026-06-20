#!/usr/bin/env bash
set -euo pipefail
#
# Composes one or more Solo products onto a single cluster.
# Creates the cluster, generates Istio certs if a mesh product is requested,
# then installs each product (in canonical dependency order) via its helmfile module.
#
# Products are installed in this fixed order regardless of argument order, so
# dependencies resolve correctly (mesh before gateways):
#     istio → gloo-mesh → kgateway → agentgateway
#
# Environment:
#   EDITION      enterprise (default) | community   — passed through to helmfile
#   ISTIO_MODE   ambient (default) | sidecar        — used by the istio module
#
# Usage: stack.sh <cluster-name> <product> [<product> ...]
#   e.g. stack.sh cluster-one istio kgateway agentgateway

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCTS_DIR="$REPO_DIR/helmfiles/products"

EDITION="${EDITION:-enterprise}"

if [[ $# -lt 2 ]]; then
  echo "Usage: stack.sh <cluster-name> <product> [<product> ...]" >&2
  echo "  products: istio gloo-mesh kgateway agentgateway" >&2
  exit 1
fi

CLUSTER="$1"; shift
REQUESTED=("$@")
CTX="vcluster.${CLUSTER}"

# Canonical install order — append new products here as modules are added.
CANONICAL_ORDER=(istio gloo-mesh kgateway agentgateway)

# Validate every requested product has a module.
for p in "${REQUESTED[@]}"; do
  if [[ ! -f "$PRODUCTS_DIR/${p}.yaml" ]]; then
    echo "Error: unknown product '${p}' (no helmfiles/products/${p}.yaml)" >&2
    echo "Available: $(cd "$PRODUCTS_DIR" && ls *.yaml | sed 's/.yaml//' | tr '\n' ' ')" >&2
    exit 1
  fi
done

requested() {
  local needle="$1"
  for p in "${REQUESTED[@]}"; do [[ "$p" == "$needle" ]] && return 0; done
  return 1
}

echo "==> Stack: cluster=${CLUSTER} edition=${EDITION} products=[${REQUESTED[*]}]"

# 1. Create the cluster
bash "$REPO_DIR/scripts/vind-create.sh" "$CLUSTER"

# 2. Generate shared Istio certs if any mesh product is in the stack
if requested istio || requested gloo-mesh; then
  bash "$REPO_DIR/scripts/gen-certs.sh" "$CLUSTER"
fi

# 3. Install each requested product in canonical order
for product in "${CANONICAL_ORDER[@]}"; do
  requested "$product" || continue
  echo ""
  echo "==> Installing '${product}' onto ${CTX} (edition=${EDITION})"
  helmfile sync \
    -f "$PRODUCTS_DIR/${product}.yaml" \
    -e "$EDITION" \
    --kube-context "$CTX"
done

echo ""
echo "==> Stack ready on ${CLUSTER}."
echo "    kubectl --context ${CTX} get pods -A"
