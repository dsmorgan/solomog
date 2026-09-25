# The MCP relay in front of the claims MCP server. Tool RBAC only fires on a genuine MCP relay
# (entMcp), so checkpoint 2 is a relay rather than a plain HTTP backend. The target forwards the
# incoming Authorization unchanged (passthrough) so `whoami` can report the composite that arrived.
# No exchange happens on this route, so passthrough shadows nothing.
# CONTEXT exported by apply-bundle.sh.
set -euo pipefail

MCP_HOST=claims-mcp.agent-evidence.svc.cluster.local
echo "==> MCP relay claims-mcp-relay -> ${MCP_HOST}:8000/mcp (auth: passthrough)"

kubectl --context "$CONTEXT" apply -f - <<EOF2
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayBackend
metadata:
  name: claims-mcp-relay
  namespace: agentgateway-system
spec:
  entMcp:
    targets:
      - name: claims
        static:
          host: ${MCP_HOST}
          port: 8000
          path: /mcp
          protocol: StreamableHTTP
          policies:
            auth:
              passthrough: {}
EOF2

echo "✓ applied claims-mcp-relay"
