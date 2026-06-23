#!/usr/bin/env bash
set -euo pipefail
#
# Deploys the Stripe mock server (stripe/stripe-mock) and exposes a curated subset
# of its OpenAPI 3.0 spec as MCP tools via an enterprise agentgateway entMcp backend
# (protocol: OpenAPI). Lets you exercise OpenAPI-to-MCP without a Stripe account.
#
# Source: fe-enterprise-agentgateway-workshop/openapi-to-mcp-in-cluster.md
#
# ROUTING IS INTENTIONALLY OMITTED: the workshop's HTTPRoute (path /mcp on the
# agentgateway-proxy Gateway) is NOT applied here — routing is handled separately
# (the /mcp path is shared across the MCP labs and needs coordination).
#
# Requires ENTERPRISE agentgateway (EnterpriseAgentgatewayBackend CRD).
# Install it first:  solomog agentgateway CLUSTER=<name>
#
# Usage: install-mcp-stripe.sh <kube-context>

CONTEXT="${1:?Usage: install-mcp-stripe.sh <kube-context>}"

# Routing is opt-in (ROUTE=true). When set, an HTTPRoute attaches this backend to
# the gateway at ROUTE_PATH. The backend itself is always created.
ROUTE="${ROUTE:-false}"
ROUTE_PATH="${ROUTE_PATH:-/mcp}"
GATEWAY="${GATEWAY:-agentgateway-proxy}"

# Preflight: the enterprise agentgateway API must be present (direct GET, deterministic).
if ! kubectl --context "$CONTEXT" get crd \
     enterpriseagentgatewaybackends.enterpriseagentgateway.solo.io >/dev/null 2>&1; then
  echo "Error: EnterpriseAgentgatewayBackend CRD not found on context '$CONTEXT'." >&2
  echo "       This sample needs enterprise agentgateway. Install it first:" >&2
  echo "         solomog agentgateway CLUSTER=<name>" >&2
  exit 1
fi

echo "==> Deploying stripe-mock server (namespace stripe-mock)"
kubectl --context "$CONTEXT" create namespace stripe-mock --dry-run=client -o yaml \
  | kubectl --context "$CONTEXT" apply -f -

kubectl --context "$CONTEXT" apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: stripe-mock
  namespace: stripe-mock
spec:
  replicas: 1
  selector:
    matchLabels:
      app: stripe-mock
  template:
    metadata:
      labels:
        app: stripe-mock
    spec:
      containers:
        - name: stripe-mock
          image: stripe/stripe-mock:latest
          ports:
            - containerPort: 12111
              name: http
---
apiVersion: v1
kind: Service
metadata:
  name: stripe-mock
  namespace: stripe-mock
spec:
  selector:
    app: stripe-mock
  ports:
    - name: http
      port: 12111
      targetPort: 12111
EOF

echo "==> Storing curated OpenAPI schema in a ConfigMap (agentgateway-system)"
kubectl --context "$CONTEXT" apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: stripe-mock-schema
  namespace: agentgateway-system
data:
  schema: |
    {
      "openapi": "3.0.0",
      "info": {
        "title": "Stripe Mock API (subset)",
        "version": "1.0.0",
        "description": "Curated subset of the Stripe API served by stripe-mock."
      },
      "servers": [
        { "url": "/" }
      ],
      "paths": {
        "/v1/products": {
          "get": {
            "operationId": "listProducts",
            "summary": "List products",
            "description": "Returns the product catalog. stripe-mock returns hardcoded sample products (e.g. a 'T-shirt'), each with a name, description, and default price.",
            "parameters": [
              {
                "name": "limit",
                "in": "query",
                "required": false,
                "description": "Maximum number of products to return (1-100).",
                "schema": { "type": "integer" }
              }
            ],
            "responses": {
              "200": { "description": "A list of products" }
            }
          }
        },
        "/v1/prices": {
          "get": {
            "operationId": "listPrices",
            "summary": "List prices",
            "description": "Returns prices for products in the catalog. Monetary amounts are in the smallest currency unit, so unit_amount 2000 means $20.00 USD. stripe-mock returns hardcoded sample data.",
            "parameters": [
              {
                "name": "limit",
                "in": "query",
                "required": false,
                "description": "Maximum number of prices to return (1-100).",
                "schema": { "type": "integer" }
              }
            ],
            "responses": {
              "200": { "description": "A list of prices" }
            }
          }
        },
        "/v1/customers": {
          "get": {
            "operationId": "listCustomers",
            "summary": "List customers",
            "description": "Returns a list of customers. stripe-mock returns hardcoded sample data.",
            "parameters": [
              {
                "name": "limit",
                "in": "query",
                "required": false,
                "description": "Maximum number of customers to return (1-100).",
                "schema": { "type": "integer" }
              },
              {
                "name": "email",
                "in": "query",
                "required": false,
                "description": "Filter customers by exact email match.",
                "schema": { "type": "string" }
              }
            ],
            "responses": {
              "200": { "description": "A list of customers" }
            }
          }
        },
        "/v1/charges": {
          "get": {
            "operationId": "listCharges",
            "summary": "List charges",
            "description": "Returns a list of charges. Monetary amounts (e.g. amount) are in the smallest currency unit, so 100 means $1.00 USD. stripe-mock returns hardcoded sample data.",
            "parameters": [
              {
                "name": "limit",
                "in": "query",
                "required": false,
                "description": "Maximum number of charges to return (1-100).",
                "schema": { "type": "integer" }
              }
            ],
            "responses": {
              "200": { "description": "A list of charges" }
            }
          }
        }
      }
    }
EOF

echo "==> Creating upstream credential Secret + entMcp/OpenAPI backend"
kubectl --context "$CONTEXT" apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: stripe-mock-token
  namespace: agentgateway-system
type: Opaque
stringData:
  Authorization: "Bearer sk_test_123"
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayBackend
metadata:
  name: stripe-mock-openapi
  namespace: agentgateway-system
spec:
  entMcp:
    targets:
      - name: stripe-mock
        static:
          host: stripe-mock.stripe-mock.svc.cluster.local
          port: 12111
          protocol: OpenAPI
          openAPI:
            schemaRef:
              name: stripe-mock-schema
          # Upstream credential for stripe-mock lives per-target in 2.3.x (the
          # workshop's top-level spec.policies.auth trips a "[ai mcp]" CEL rule).
          policies:
            auth:
              secretRef:
                name: stripe-mock-token
EOF

echo "==> Waiting for stripe-mock to be ready..."
kubectl --context "$CONTEXT" wait --for=condition=available \
  deployment/stripe-mock -n stripe-mock --timeout=90s || true

if [[ "$ROUTE" == "true" ]]; then
  echo "==> Routing: HTTPRoute openapi-mcp-stripe → ${GATEWAY} at ${ROUTE_PATH}"
  kubectl --context "$CONTEXT" apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: openapi-mcp-stripe
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
        - name: stripe-mock-openapi
          group: enterpriseagentgateway.solo.io
          kind: EnterpriseAgentgatewayBackend
EOF
  if ! kubectl --context "$CONTEXT" get gateway "$GATEWAY" -n agentgateway-system >/dev/null 2>&1; then
    echo "    NOTE: Gateway '${GATEWAY}' not found — run 'solomog expose' first so the route programs."
  fi
else
  echo "==> Backend only (no route). Add one with: ROUTE=true [ROUTE_PATH=${ROUTE_PATH}]"
fi

echo ""
echo "==> Mock MCP (stripe-mock via OpenAPI) deployed."
echo "    Once routed + gateway is up, list tools at ${ROUTE_PATH} via MCP Inspector or curl."
