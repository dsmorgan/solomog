# Add-ons, sample apps, and standalone recipes for scripts/explain.sh.
# Sourced, not executed.

explain_task_addon() {
  local t="$1"
  case "$t" in
    portal)
      explain_section "portal"
      if [ "$EDITION" != "enterprise" ]; then
        echo "# Portal is enterprise-only and needs Solo Enterprise for kgateway on the cluster."
        echo
        return 0
      fi
      echo "# Docs: https://docs.solo.io/kgateway/2.3.x/portal/setup/"
      echo "# Needs enterprise kgateway already installed."
      explain_helm_oci portal-crds \
        oci://us-docker.pkg.dev/solo-public/enterprise-kgateway/charts/portal-crds \
        "${PORTAL_VERSION}" portal-system --wait
      explain_helm_oci portal \
        oci://us-docker.pkg.dev/solo-public/enterprise-kgateway/charts/portal \
        "${PORTAL_VERSION}" portal-system \
        '--set licensing.licenseKey="$PORTAL_LICENSE_KEY"' \
        --wait
      ;;
    monitoring)
      explain_section "monitoring"
      echo "# kube-prometheus-stack (Prometheus + Grafana). Edition-agnostic."
      echo "# Product dashboards are extra ConfigMaps the Grafana sidecar picks up."
      explain_helm_repo prometheus-community \
        https://prometheus-community.github.io/helm-charts \
        grafana-prometheus prometheus-community/kube-prometheus-stack \
        "${KUBE_PROM_STACK_VERSION}" monitoring \
        --set alertmanager.enabled=false \
        --set nodeExporter.enabled=false \
        --set grafana.service.type=ClusterIP \
        --set grafana.service.port=3000 \
        --wait
      ;;
  esac
}

explain_task_app() {
  local t="$1"
  local gw="${GATEWAY:-agw}"
  local gw_ns="${GATEWAY_NS:-agentgateway-system}"
  local route_path
  case "$t" in
    apps:utils)
      explain_section "apps:utils"
      route_path="${ROUTE_PATH:-/httpbin}"
      echo "# httpbin (mccutchen/go-httpbin — multi-arch) plus optional curl/netshoot clients."
      cat <<EOF
kubectl create namespace utils --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f - <<'APP'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: httpbin
  namespace: utils
spec:
  replicas: 1
  selector:
    matchLabels:
      app: httpbin
  template:
    metadata:
      labels:
        app: httpbin
    spec:
      containers:
        - name: httpbin
          image: mccutchen/go-httpbin:latest
          ports:
            - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: httpbin
  namespace: utils
spec:
  selector:
    app: httpbin
  ports:
    - port: 80
      targetPort: 8080
APP
EOF
      echo
      if [ "${ROUTE:-false}" = "true" ]; then
        cat <<EOF
kubectl apply -f - <<'RT'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: httpbin
  namespace: utils
spec:
  parentRefs:
    - name: ${gw}
      namespace: ${gw_ns}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: ${route_path}
      filters:
        - type: URLRewrite
          urlRewrite:
            path:
              type: ReplacePrefixMatch
              replacePrefixMatch: /
      backendRefs:
        - name: httpbin
          port: 80
RT
EOF
        echo
      else
        echo "# No HTTPRoute. Add one with ROUTE=true (default path ${route_path})."
        echo
      fi
      ;;
    apps:mock-openai)
      explain_section "apps:mock-openai"
      route_path="${ROUTE_PATH:-/openai}"
      echo "# Mock OpenAI-compatible LLM (vLLM simulator) plus an EnterpriseAgentgatewayBackend."
      echo "# Needs enterprise agentgateway. Workload ns: mock-openai; config stays with the gateway."
      cat <<EOF
kubectl create namespace mock-openai --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f - <<'APP'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mock-gpt-4o
  namespace: mock-openai
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mock-gpt-4o
  template:
    metadata:
      labels:
        app: mock-gpt-4o
    spec:
      containers:
        - name: vllm-sim
          image: ghcr.io/llm-d/llm-d-inference-sim:latest
          args: ["--model", "mock-gpt-4o", "--port", "8000"]
          ports:
            - containerPort: 8000
---
apiVersion: v1
kind: Service
metadata:
  name: mock-gpt-4o-svc
  namespace: mock-openai
spec:
  selector:
    app: mock-gpt-4o
  ports:
    - port: 8000
      targetPort: 8000
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayBackend
metadata:
  name: mock-openai
  namespace: agentgateway-system
spec:
  ai:
    provider:
      openai:
        model: "mock-gpt-4o"
      host: mock-gpt-4o-svc.mock-openai.svc.cluster.local
      port: 8000
      path: "/v1/chat/completions"
APP
EOF
      echo
      if [ "${ROUTE:-false}" = "true" ]; then
        cat <<EOF
kubectl apply -f - <<'RT'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: mock-openai
  namespace: agentgateway-system
spec:
  parentRefs:
    - name: ${gw}
      namespace: agentgateway-system
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: ${route_path}
      backendRefs:
        - name: mock-openai
          group: enterpriseagentgateway.solo.io
          kind: EnterpriseAgentgatewayBackend
RT
EOF
        echo
      else
        echo "# Backend only. Add a route with ROUTE=true (default path ${route_path})."
        echo
      fi
      ;;
    apps:mcp-stripe)
      explain_section "apps:mcp-stripe"
      route_path="${ROUTE_PATH:-/mcp}"
      echo "# stripe-mock workload (ns stripe-mock) plus an MCP EnterpriseAgentgatewayBackend."
      echo "# Pair it with an OpenAPI schema ConfigMap in agentgateway-system (not inlined here)."
      echo "# Needs enterprise agentgateway."
      cat <<EOF
kubectl create namespace stripe-mock --dry-run=client -o yaml | kubectl apply -f -
# Deploy stripe-mock, then:
kubectl apply -f - <<'APP'
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayBackend
metadata:
  name: stripe-mock
  namespace: agentgateway-system
spec:
  mcp:
    targets:
      - name: stripe
        openapi:
          url: http://stripe-mock.stripe-mock.svc.cluster.local:12111
APP
EOF
      echo
      if [ "${ROUTE:-false}" = "true" ]; then
        echo "# HTTPRoute at ${route_path} → EnterpriseAgentgatewayBackend stripe-mock (gateway ${gw})."
        echo
      else
        echo "# Backend only. Add a route with ROUTE=true (default path ${route_path})."
        echo
      fi
      ;;
    apps:bookinfo)
      explain_section "apps:bookinfo"
      echo "# Upstream Istio bookinfo sample."
      echo "kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-${ISTIO_VERSION%.*}/samples/bookinfo/platform/kube/bookinfo.yaml"
      echo
      ;;
  esac
}

explain_task_standalone() {
  local t="$1"
  local img="us-docker.pkg.dev/solo-public/enterprise-agentgateway/agentgateway-enterprise:${AGENTGATEWAY_STANDALONE_VERSION:-2026.8.2}"
  # CONFIG is the task-level name for the config dir; NAME is its alias.
  local name="${CONFIG:-${NAME:-minimal}}"
  explain_section "$t"
  echo "# Standalone agentgateway — one Docker container, no Kubernetes, no CRDs."
  echo "# ADMIN_ADDR must be 0.0.0.0:15000 so published ports reach the process."
  echo "# License: AGENTGATEWAY_LICENSE_KEY only (SOLO_LICENSE_KEY has no product claim)."
  echo "# Bind defaults to 127.0.0.1. Config dir is read-write so UI edits persist."
  if [ "$t" = "standalone:validate" ]; then
    echo "docker run --rm \\"
    echo "  -e ADMIN_ADDR=0.0.0.0:15000 \\"
    echo "  -v /path/to/${name}:/config \\"
    echo "  ${img} --validate-only -f /config/config.yaml"
    echo
    return 0
  fi
  echo "docker run -d --name ${name} \\"
  echo "  -e ENTERPRISE_AGENTGATEWAY_LICENSE_KEY \\"
  echo "  -e ADMIN_ADDR=0.0.0.0:15000 \\"
  echo "  -p 127.0.0.1:15000:15000 \\"
  echo "  -p 127.0.0.1:4000:4000 \\"
  echo "  -v /path/to/${name}:/config \\"
  echo "  ${img} -f /config/config.yaml"
  echo
}
