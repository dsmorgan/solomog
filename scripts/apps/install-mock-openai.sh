#!/usr/bin/env bash
set -euo pipefail
#
# Deploys an OpenAI-compatible mock LLM server (the vLLM simulator, maintained by
# the llm-d community) plus an agentgateway HTTPRoute + EnterpriseAgentgatewayBackend
# that routes /openai to it. Lets you exercise AI Gateway routing/metrics/tracing
# without real OpenAI credentials.
#
# Source: fe-enterprise-agentgateway-workshop/configure-mock-openai-server.md
#
# Adapted for enterprise-agentgateway 2.3.x: the workshop's backend used
# `spec.policies.auth.passthrough`, but in 2.3.x `spec.policies` is for AI policies
# and has no `auth`. The mock needs no credentials, so the policies block is omitted.
#
# Requires ENTERPRISE agentgateway (provides the EnterpriseAgentgatewayBackend CRD).
# Install it first:  solomog agentgateway CLUSTER=<name>
# The HTTPRoute targets a Gateway named `agentgateway-proxy` (created by the
# workshop's setup lab); without it the route has no external address.
#
# Usage: install-mock-openai.sh <kube-context>

CONTEXT="${1:?Usage: install-mock-openai.sh <kube-context>}"
NS=agentgateway-system

# Preflight: the enterprise agentgateway API must be present. A direct CRD GET is
# deterministic (unlike `api-resources`, whose full discovery can transiently fail).
if ! kubectl --context "$CONTEXT" get crd \
     enterpriseagentgatewaybackends.enterpriseagentgateway.solo.io >/dev/null 2>&1; then
  echo "Error: EnterpriseAgentgatewayBackend CRD not found on context '$CONTEXT'." >&2
  echo "       This sample needs enterprise agentgateway. Install it first:" >&2
  echo "         solomog agentgateway CLUSTER=<name>" >&2
  exit 1
fi

echo "==> Deploying mock vLLM server (mock-gpt-4o) into ${NS}"
kubectl --context "$CONTEXT" apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mock-gpt-4o
  namespace: agentgateway-system
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
      - args:
        - --model
        - mock-gpt-4o
        - --port
        - "8000"
        - --max-loras
        - "2"
        - --lora-modules
        - '{"name": "food-review-1"}'
        image: ghcr.io/llm-d/llm-d-inference-sim:latest
        imagePullPolicy: IfNotPresent
        name: vllm-sim
        env:
          - name: POD_NAME
            valueFrom:
              fieldRef:
                apiVersion: v1
                fieldPath: metadata.name
          - name: POD_NAMESPACE
            valueFrom:
              fieldRef:
                apiVersion: v1
                fieldPath: metadata.namespace
        ports:
        - containerPort: 8000
          name: http
          protocol: TCP
---
apiVersion: v1
kind: Service
metadata:
  name: mock-gpt-4o-svc
  namespace: agentgateway-system
  labels:
    app: mock-gpt-4o
spec:
  selector:
    app: mock-gpt-4o
  ports:
    - protocol: TCP
      port: 8000
      targetPort: 8000
      name: http
  type: ClusterIP
EOF

echo "==> Creating HTTPRoute + EnterpriseAgentgatewayBackend (mock-openai)"
kubectl --context "$CONTEXT" apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: mock-openai
  namespace: agentgateway-system
spec:
  parentRefs:
    - name: agentgateway-proxy
      namespace: agentgateway-system
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /openai
      backendRefs:
        - name: mock-openai
          group: enterpriseagentgateway.solo.io
          kind: EnterpriseAgentgatewayBackend
      timeouts:
        request: "120s"
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
      host: mock-gpt-4o-svc.agentgateway-system.svc.cluster.local
      port: 8000
      path: "/v1/chat/completions"
EOF

# The HTTPRoute needs a parent Gateway named agentgateway-proxy to get an address.
if ! kubectl --context "$CONTEXT" get gateway agentgateway-proxy -n "$NS" >/dev/null 2>&1; then
  echo ""
  echo "NOTE: Gateway 'agentgateway-proxy' not found in ${NS}; the HTTPRoute has no"
  echo "      parent yet, so there's no external address to curl. The workshop's setup"
  echo "      lab creates that Gateway."
fi

echo ""
echo "==> Mock OpenAI deployed. Once the gateway has an address:"
echo "    GATEWAY_IP=\$(kubectl --context $CONTEXT get svc -n $NS \\"
echo "      --selector=gateway.networking.k8s.io/gateway-name=agentgateway-proxy \\"
echo "      -o jsonpath='{.items[*].status.loadBalancer.ingress[0].ip}')"
echo "    curl -i \"\$GATEWAY_IP:8080/openai\" -H 'content-type: application/json' \\"
echo "      -d '{\"model\":\"mock-gpt-4o\",\"messages\":[{\"role\":\"user\",\"content\":\"Whats your favorite poem?\"}]}'"
