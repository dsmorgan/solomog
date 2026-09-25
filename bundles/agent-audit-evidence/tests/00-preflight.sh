#!/usr/bin/env bash
# Preflight: the environment is what the bundle expects, before any Okta or MCP assertion.
# Version, workload readiness, and every policy Accepted. A failure here is environment, not product.
set -uo pipefail
. "$(dirname "$0")/_lib.bash"
fail=0

IMG=$(kubectl --context "$CONTEXT" get deploy "$GATEWAY" -n "$NS_GW" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
echo "== gateway image: ${IMG:-<not found>}"
[ -n "$IMG" ] || { echo "✗ no Deployment ${NS_GW}/${GATEWAY}. Run: solomog agentgateway:ui monitoring expose CLUSTER=<c>"; exit 1; }
case "$IMG" in
  *enterprise*) ;;
  *) echo "✗ not an enterprise agentgateway image; crossAppAccess and entMcp need enterprise"; fail=1 ;;
esac

echo "== workloads in ${NS_APP}"
for d in evidence-resource-as claims-mcp evidence-probe-echo priorauth-agent intake-agent evidence-collector evidence-loki; do
  r=$(kubectl --context "$CONTEXT" get deploy "$d" -n "$NS_APP" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  if [ "${r:-0}" -ge 1 ] 2>/dev/null; then echo "  ✓ $d"; else echo "  ✗ $d not ready  (kubectl --context $CONTEXT -n $NS_APP logs deploy/$d --tail=30)"; fail=1; fi
done

echo "== policies"
for p in agents-priorauth-xaa agents-intake-xaa probe-priorauth-xaa probe-intake-xaa claims-tools-authz claims-tools-rbac evidence-telemetry; do
  st=$(kubectl --context "$CONTEXT" get enterpriseagentgatewaypolicy "$p" -n "$NS_GW" \
    -o jsonpath='{range .status.ancestors[*].conditions[?(@.type=="Accepted")]}{.status}{" "}{.message}{end}' 2>/dev/null)
  case "$st" in
    True*) echo "  ✓ $p Accepted" ;;
    *) echo "  ✗ $p: ${st:-no status}"; fail=1 ;;
  esac
done

[ "$fail" = 0 ] && echo "✓ preflight clean" || exit 1
