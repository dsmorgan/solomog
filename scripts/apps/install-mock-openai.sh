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
# With ROUTE=true the HTTPRoute targets the gateway named by GATEWAY (default agw,
# created by `solomog expose`); without that gateway the route has no address.
#
# Usage: install-mock-openai.sh <kube-context>

CONTEXT="${1:?Usage: install-mock-openai.sh <kube-context>}"
NS=agentgateway-system

# Routing is opt-in (ROUTE=true). When set, an HTTPRoute attaches this backend to
# the gateway at ROUTE_PATH. The backend itself is always created.
ROUTE="${ROUTE:-false}"
ROUTE_PATH="${ROUTE_PATH:-/openai}"
GATEWAY="${GATEWAY:-agw}"

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

echo "==> Creating EnterpriseAgentgatewayBackend (mock-openai)"
kubectl --context "$CONTEXT" apply -f - <<'EOF'
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

if [[ "$ROUTE" == "true" ]]; then
  echo "==> Routing: HTTPRoute mock-openai → ${GATEWAY} at ${ROUTE_PATH}"
  kubectl --context "$CONTEXT" apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: mock-openai
  namespace: agentgateway-system
spec:
  parentRefs:
    - name: ${GATEWAY}
      namespace: agentgateway-system
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: ${ROUTE_PATH}
      backendRefs:
        - name: mock-openai
          group: enterpriseagentgateway.solo.io
          kind: EnterpriseAgentgatewayBackend
      timeouts:
        request: "120s"
EOF
  if ! kubectl --context "$CONTEXT" get gateway "$GATEWAY" -n "$NS" >/dev/null 2>&1; then
    echo "    NOTE: Gateway '${GATEWAY}' not found — run 'solomog expose' first so the route programs."
  fi
else
  echo "==> Backend only (no route). Add one with: ROUTE=true [ROUTE_PATH=${ROUTE_PATH}]"
fi

echo ""
echo "==> Mock OpenAI deployed. With the gateway exposed (solomog expose), curl via its host:"
echo "    curl -i \"http://${GATEWAY}.<cluster>.test:8080${ROUTE_PATH}\" -H 'content-type: application/json' \\"
echo "      -d '{\"model\":\"mock-gpt-4o\",\"messages\":[{\"role\":\"user\",\"content\":\"Whats your favorite poem?\"}]}'"
