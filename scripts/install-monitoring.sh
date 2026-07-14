#!/usr/bin/env bash
set -euo pipefail
#
# Installs the monitoring stack (Prometheus + Grafana via kube-prometheus-stack) and
# layers on product-specific scrape config + dashboards. Product-agnostic base, so it
# applies to whatever Solo products are on the cluster.
#
# Product dashboards are auto-detected the same way `expose` auto-detects the gateway:
# we look at the cluster's GatewayClasses and install matching pieces. Override with
# DASHBOARDS="agentgateway ..." to force a set, or DASHBOARDS=none for the base only.
#
# With ROUTE=true, Grafana is exposed on its own sub-host under expose's wildcard
# (grafana.agw.<cluster>.test) instead of a port-forward.
#
# Usage: install-monitoring.sh <kube-context>
# Env:
#   DASHBOARDS  "auto" (default) | "none" | space-separated products (e.g. "agentgateway")
#   ROUTE       true|false (default false) — route Grafana on grafana.<gw>.<cluster>.test
#   GATEWAY     gateway to route through (default agw)
#   GATEWAY_NS  gateway namespace (default agentgateway-system)
#   EDITION     enterprise (default) — only selects a helmfile env; stack is OSS either way
#   GRAFANA_ADMIN_PASSWORD  Grafana admin password (default prom-operator).
#                           Set in .env (or the process env) — not a Taskfile CLI var.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTEXT="${1:?Usage: install-monitoring.sh <kube-context>}"
CLUSTER="${CONTEXT#vcluster-docker_}"
EDITION="${EDITION:-enterprise}"
DASHBOARDS="${DASHBOARDS:-auto}"
ROUTE="${ROUTE:-false}"
GATEWAY="${GATEWAY:-agw}"
GATEWAY_NS="${GATEWAY_NS:-agentgateway-system}"

echo "==> Installing monitoring stack (Prometheus + Grafana) into 'monitoring' on ${CONTEXT}"
helmfile sync \
  -f "$REPO_DIR/helmfiles/addons/monitoring.yaml.gotmpl" \
  -e "$EDITION" \
  --kube-context "$CONTEXT"

# Resolve which product dashboards to install.
if [[ "$DASHBOARDS" == "auto" ]]; then
  classes="$(kubectl --context "$CONTEXT" get gatewayclass -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
  DASHBOARDS=""
  [[ "$classes" == *agentgateway* ]] && DASHBOARDS="agentgateway"
  if [[ -n "$DASHBOARDS" ]]; then
    echo "==> Auto-detected products for dashboards: ${DASHBOARDS}"
  else
    echo "==> No known products detected — installing base stack only (override with DASHBOARDS=...)"
  fi
elif [[ "$DASHBOARDS" == "none" ]]; then
  DASHBOARDS=""
fi

install_agentgateway_dashboards() {
  echo "==> [agentgateway] PodMonitor for the agentgateway data plane"
  kubectl --context "$CONTEXT" apply -f - <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: data-plane-monitoring-agentgateway-metrics
  namespace: agentgateway-system
spec:
  namespaceSelector:
    matchNames:
      - agentgateway-system
  podMetricsEndpoints:
    - port: metrics
  selector:
    matchLabels:
      app.kubernetes.io/name: agentgateway-proxy
EOF

  echo "==> [agentgateway] Grafana dashboard (AgentGateway Overview)"
  kubectl create configmap agentgateway-dashboard \
    --from-file=agentgateway-overview.json="$REPO_DIR/dashboards/agentgateway-overview.json" \
    --namespace monitoring --dry-run=client -o yaml \
    | kubectl label --local -f - grafana_dashboard="1" --dry-run=client -o yaml \
    | kubectl --context "$CONTEXT" apply --server-side --force-conflicts -f -
}

for d in $DASHBOARDS; do
  case "$d" in
    agentgateway) install_agentgateway_dashboards ;;
    *) echo "    skipping unknown dashboard set '${d}'" ;;
  esac
done

if [[ "$ROUTE" == "true" ]]; then
  # Resolve the Grafana service (name/port) rather than assuming the release's naming.
  GRAFANA_SVC="$(kubectl --context "$CONTEXT" get svc -n monitoring \
    -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  GRAFANA_PORT="$(kubectl --context "$CONTEXT" get svc -n monitoring \
    -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].spec.ports[0].port}' 2>/dev/null || echo 3000)"
  if [[ -z "$GRAFANA_SVC" ]]; then
    echo "    NOTE: Grafana service not found yet — skipping route. Re-run after pods are up."
  else
    bash "$REPO_DIR/scripts/route-host.sh" \
      "$CONTEXT" "$CLUSTER" grafana "$GRAFANA_SVC" monitoring "$GRAFANA_PORT" "$GATEWAY" "$GATEWAY_NS"
    echo ""
    echo "==> Grafana routed. Open:  https://grafana.${GATEWAY}.${CLUSTER}.test/   (admin / ${GRAFANA_ADMIN_PASSWORD:-prom-operator})"
  fi
else
  echo ""
  echo "==> Monitoring installed (not routed). Reach Grafana either way:"
  echo "    port-forward:  kubectl --context ${CONTEXT} port-forward -n monitoring svc/grafana-prometheus 3000:3000"
  echo "                   then open  http://localhost:3000  (admin / ${GRAFANA_ADMIN_PASSWORD:-prom-operator})"
  echo "    or route it:   solomog monitoring expose ROUTE=true CLUSTER=${CLUSTER}"
fi
