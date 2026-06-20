#!/usr/bin/env bash
set -euo pipefail
#
# Deploys the Istio Bookinfo sample application.
# Uses the version of Bookinfo that matches the installed Istio version.
#
# Usage: install-bookinfo.sh <kube-context>

CONTEXT="${1:?Usage: install-bookinfo.sh <kube-context>}"

# Derive Istio version from the installed istiod
ISTIO_VERSION=$(
  kubectl --context "$CONTEXT" \
    get deployment istiod -n istio-system \
    -o jsonpath='{.metadata.labels.app\.kubernetes\.io/version}' 2>/dev/null \
  || kubectl --context "$CONTEXT" \
    get deployment istiod -n istio-system \
    -o jsonpath='{.spec.template.metadata.labels.istio}' 2>/dev/null \
  || echo "${ISTIO_VERSION:-1.22.3}"  # fallback to env var or hardcoded default
)

# Strip any leading "v"
ISTIO_VERSION="${ISTIO_VERSION#v}"
# Use only major.minor for the branch
ISTIO_MINOR="release-$(echo "$ISTIO_VERSION" | cut -d. -f1-2)"

BASE_URL="https://raw.githubusercontent.com/istio/istio/${ISTIO_MINOR}/samples/bookinfo/platform/kube"

echo "==> Deploying Bookinfo (Istio ${ISTIO_MINOR}) to context: $CONTEXT"

kubectl --context "$CONTEXT" apply -f "${BASE_URL}/bookinfo.yaml"

echo "==> Deploying Bookinfo gateway resources..."
kubectl --context "$CONTEXT" apply -f "${BASE_URL}/bookinfo-gateway.yaml" 2>/dev/null || true

echo ""
echo "==> Bookinfo deployed."
echo "    Pods: kubectl --context $CONTEXT get pods -n default"
