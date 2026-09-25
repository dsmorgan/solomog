# Register Loki as a Grafana datasource, if Grafana is here.
#
# kube-prometheus-stack runs a sidecar that watches the release namespace for ConfigMaps labelled
# `grafana_datasource=1`, provisions what it finds, and asks Grafana to reload. So adding a
# datasource is a ConfigMap, not a Helm upgrade — which matters, because `solomog monitoring` owns
# that release and a bundle has no business re-templating it.
#
# SELF-SKIPS when the monitoring namespace is absent. Grafana is optional here for the same reason
# Loki is: the collector's stdout already answers the question, Grafana only makes it pleasant.
#
# CONTEXT is exported by apply-bundle.sh.
set -euo pipefail

if ! kubectl --context "$CONTEXT" get namespace monitoring >/dev/null 2>&1; then
  echo "==> Grafana datasource: skipped (no 'monitoring' namespace)"
  echo "    install it with:  solomog monitoring CLUSTER=<c>   then re-apply this bundle"
  exit 0
fi

echo "==> Grafana datasource: Loki -> evidence-loki.agent-evidence:3100"

kubectl --context "$CONTEXT" apply -f - <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: evidence-loki-datasource
  namespace: monitoring
  labels:
    grafana_datasource: "1"
data:
  loki-datasource.yaml: |
    apiVersion: 1
    datasources:
      - name: Loki
        uid: evidence-loki
        type: loki
        access: proxy
        url: http://evidence-loki.agent-evidence.svc.cluster.local:3100
        isDefault: false
        jsonData:
          # Attribute names carry dots (auth.token.issuer); Loki turns those into underscores in
          # structured metadata, so query them as auth_token_issuer.
          maxLines: 1000
YAML

echo "✓ applied evidence-loki-datasource (Grafana reloads it within ~60s via the sidecar)"
