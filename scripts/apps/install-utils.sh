#!/usr/bin/env bash
set -euo pipefail
#
# Deploys the utility pods (httpbin, curl, netshoot). With ROUTE=true it also exposes
# httpbin through the cluster's gateway. httpbin is a plain Kubernetes Service, so the
# HTTPRoute uses a standard Service backendRef and works on ANY gateway (agentgateway
# or kgateway) — making it the universal "is routing working?" test. curl and netshoot
# stay as in-cluster clients (never routed).
#
# The route uses a URLRewrite filter so /<ROUTE_PATH>/get maps to httpbin's /get.
#
# Usage: install-utils.sh <kube-context>
# Env:
#   ROUTE        true|false (default false) — create the httpbin HTTPRoute
#   ROUTE_PATH   path prefix (default /httpbin)
#   GATEWAY      gateway name      (default: auto-detected agw/kgw)
#   GATEWAY_NS   gateway namespace (default: auto-detected)

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/gateway.sh
source "$REPO_DIR/scripts/lib/gateway.sh"
CONTEXT="${1:?Usage: install-utils.sh <kube-context>}"
ROUTE="${ROUTE:-false}"
ROUTE_PATH="${ROUTE_PATH:-/httpbin}"
GATEWAY="${GATEWAY:-}"
GATEWAY_NS="${GATEWAY_NS:-}"

echo "==> Deploying utility pods (httpbin, curl, netshoot) to ${CONTEXT}"
helmfile sync -f "$REPO_DIR/helmfiles/apps/utils.yaml" --kube-context "$CONTEXT"

if [[ "$ROUTE" != "true" ]]; then
  echo "==> httpbin not routed. Expose it with: ROUTE=true [ROUTE_PATH=${ROUTE_PATH}]"
  exit 0
fi

# Auto-detect the gateway (name + namespace) when not given. Edition-aware via gateway.sh
# (enterprise-* or community GatewayClass → kgw/kgateway-system or agw/agentgateway-system).
if [[ -z "$GATEWAY" || -z "$GATEWAY_NS" ]]; then
  product="$(solomog_detect_product "$(solomog_gateway_classes "$CONTEXT")")"
  if [[ "$product" == kgateway ]]; then _GW=kgw; _GWNS=kgateway-system
  else _GW=agw; _GWNS=agentgateway-system; fi
  GATEWAY="${GATEWAY:-$_GW}"
  GATEWAY_NS="${GATEWAY_NS:-$_GWNS}"
fi

echo "==> Routing: HTTPRoute httpbin → ${GATEWAY} (${GATEWAY_NS}) at ${ROUTE_PATH}"
kubectl --context "$CONTEXT" apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: httpbin
  namespace: utils
spec:
  parentRefs:
    - name: ${GATEWAY}
      namespace: ${GATEWAY_NS}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: ${ROUTE_PATH}
      filters:
        - type: URLRewrite
          urlRewrite:
            path:
              type: ReplacePrefixMatch
              replacePrefixMatch: /
      backendRefs:
        - name: httpbin
          port: 80
EOF

if ! kubectl --context "$CONTEXT" get gateway "$GATEWAY" -n "$GATEWAY_NS" >/dev/null 2>&1; then
  echo "    NOTE: Gateway '${GATEWAY}' not found in ${GATEWAY_NS} — run 'solomog expose' so the route programs."
fi
echo ""
echo "==> httpbin routed. With the gateway exposed, curl it at:  <gateway-host>:8080${ROUTE_PATH}/get"
