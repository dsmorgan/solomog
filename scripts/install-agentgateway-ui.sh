#!/usr/bin/env bash
set -euo pipefail
#
# Enables agentgateway on solomog's singleton Solo UI (`management` chart), wires
# tracing to its built-in OTEL collector, and — with ROUTE=true — exposes the UI
# on its own sub-host under expose's wildcard (ui.agw.<cluster>.test).
#
# This is the UI half of `solomog agentgateway:ui`; the agentgateway product itself
# is installed first (by the task, via stack.sh). Enterprise kagent may already
# own the same release; helmfile reuses its values and enables agentgateway rather
# than installing a second CRD-owning management release.
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
# shellcheck source=lib/target.sh
source "$REPO_DIR/scripts/lib/target.sh"
# Target: positional context arg (back-compat) → else CLUSTER/CONTEXT via lib/target.sh
# (registry-aware: vind, EKS, vsphere alike — never hardcode vcluster-docker_).
if [ -n "${1:-}" ]; then CONTEXT="$1"; else
  solomog_require_cluster "${CLUSTER:-}" "agentgateway:ui"
  CONTEXT="$(solomog_context "${CLUSTER:-}")"
fi
# Bare cluster name for the sub-host; prefer the CLUSTER env (correct for registered
# externals), stripping the vind prefix only as a raw-context fallback.
[ -z "${CLUSTER:-}" ] && CLUSTER="${CONTEXT#vcluster-docker_}"
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

# Never create a second management release: its bundled cluster-scoped CRDs can
# only have one Helm owner. Enterprise kagent and agentgateway UI share this one.
management_releases="$(
  helm list --kube-context "$CONTEXT" -A -o json 2>/dev/null \
    | jq -r '.[] | select(.chart | startswith("management-")) | "\(.namespace)/\(.name)"' \
    || true
)"
if [[ -n "$management_releases" && "$management_releases" != "${NS}/management" ]]; then
  echo "Error: found a management chart outside solomog's singleton release:" >&2
  printf '       %s\n' "$management_releases" >&2
  echo "       Move/upgrade it to ${NS}/management; a second release causes CRD conflicts." >&2
  exit 1
fi

# Once kagent is installed, changing management OIDC alone breaks the kagent
# controller. Preserve the release's current auth mode; a subsequent kagent sync
# is the coordinated path for changing it.
if helm status kagent --kube-context "$CONTEXT" -n kagent >/dev/null 2>&1; then
  export MANAGEMENT_PRESERVE_OIDC=true
  echo "==> Preserving shared management OIDC values owned with Enterprise kagent"
fi

echo "==> Enabling agentgateway in shared Solo UI (${NS} on ${CONTEXT})"
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
