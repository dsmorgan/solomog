#!/usr/bin/env bash
set -euo pipefail
#
# Installs the Solo UI (the `management` chart) for agentgateway, wires tracing to
# its built-in OTEL collector, and — with ROUTE=true — exposes the UI on its own
# sub-host under expose's wildcard (ui.agw.<cluster>.test) instead of a port-forward.
#
# This is the UI half of `solomog agentgateway:ui`; the agentgateway product itself
# is installed first (by the task, via stack.sh). The `management` chart bundles its
# CRDs, so there is no separate management-crds step (official 2.3.x path).
#
# Requires ENTERPRISE agentgateway — the Solo UI is an enterprise-only feature.
#
# Usage: install-agentgateway-ui.sh <kube-context>
# Env:
#   EDITION    enterprise (default). community is rejected (no community UI).
#   ROUTE      true|false (default false) — route the UI on ui.<gw>.<cluster>.test
#   GATEWAY    gateway to target for tracing + routing (default agw)
#   GATEWAY_NS gateway namespace (default agentgateway-system)

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTEXT="${1:?Usage: install-agentgateway-ui.sh <kube-context>}"
CLUSTER="${CONTEXT#vcluster-docker_}"   # bare cluster name, for the sub-host
EDITION="${EDITION:-enterprise}"
ROUTE="${ROUTE:-false}"
GATEWAY="${GATEWAY:-agw}"
GATEWAY_NS="${GATEWAY_NS:-agentgateway-system}"
NS=agentgateway-system

if [[ "$EDITION" == "community" ]]; then
  echo "Error: the Solo UI (management chart) is enterprise-only — no community edition." >&2
  echo "       Run 'solomog agentgateway:ui' with the default EDITION=enterprise." >&2
  exit 1
fi

# Preflight: enterprise agentgateway must be present (provides the policy CRD the
# UI's tracing wiring uses). A direct CRD GET is deterministic.
if ! kubectl --context "$CONTEXT" get crd \
     enterpriseagentgatewaypolicies.enterpriseagentgateway.solo.io >/dev/null 2>&1; then
  echo "Error: enterprise agentgateway not found on context '$CONTEXT'." >&2
  echo "       Install it first:  solomog agentgateway CLUSTER=${CLUSTER}" >&2
  echo "       (or use the combined scenario:  solomog agentgateway:ui CLUSTER=${CLUSTER})" >&2
  exit 1
fi

echo "==> Installing Solo UI (management chart) into ${NS} on ${CONTEXT}"
SOLO_CLUSTER="$CLUSTER" helmfile sync \
  -f "$REPO_DIR/helmfiles/addons/agentgateway-ui.yaml.gotmpl" \
  -e "$EDITION" \
  --kube-context "$CONTEXT"

# Tracing: point agentgateway at the UI's built-in OTEL collector. Targets the
# gateway by name — safe to apply before `expose` creates it; the policy attaches
# once the gateway exists.
echo "==> Wiring tracing (EnterpriseAgentgatewayPolicy → solo-enterprise-telemetry-collector)"
kubectl --context "$CONTEXT" apply -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: tracing
  namespace: ${NS}
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: ${GATEWAY}
  frontend:
    tracing:
      backendRef:
        name: solo-enterprise-telemetry-collector
        namespace: ${NS}
        kind: Service
        port: 4317
      randomSampling: "true"
EOF

if [[ "$ROUTE" == "true" ]]; then
  # Solo UI service is solo-enterprise-ui on port 80; it serves under /age/.
  bash "$REPO_DIR/scripts/route-host.sh" \
    "$CONTEXT" "$CLUSTER" ui solo-enterprise-ui "$NS" 80 "$GATEWAY" "$GATEWAY_NS"
  echo ""
  echo "==> Solo UI routed. Open:  https://ui.${GATEWAY}.${CLUSTER}.test/age/"
else
  echo ""
  echo "==> UI installed (not routed). Reach it either way:"
  echo "    port-forward:  kubectl --context ${CONTEXT} port-forward -n ${NS} svc/solo-enterprise-ui 4000:80"
  echo "                   then open  http://localhost:4000/age/"
  echo "    or route it:   solomog agentgateway:ui expose ROUTE=true CLUSTER=${CLUSTER}"
fi
