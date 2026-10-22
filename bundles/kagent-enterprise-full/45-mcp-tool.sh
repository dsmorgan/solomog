#!/usr/bin/env bash
# An MCP server deployed by kmcp, and an agent that calls its tool.
#
#   MCPServer mock-mcp        (kagent.dev/v1alpha1, kmcp) kmcp turns it into a Deployment and a
#                             Service. The server is helpers/mocks/mock_mcp.py, mounted from a
#                             ConfigMap into a stock Python image; every tool returns
#                             "TOOL-<name>-OK" and every call is logged at /requests.
#   RemoteMCPServer mock-mcp  (api.kagent.dev) An agent's tools can name only this kind, so it
#                             points at the Service kmcp made.
#   Agent toolcall            the mock model with that server bound. "CALL:add" in the user text
#                             makes the mock model call the `add` tool.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/helpers/env.sh"
CTX="${CONTEXT:?CONTEXT not set — solomog sets this for bundle hooks}"
k() { kubectl --context "$CTX" "$@"; }
SRC="$HERE/helpers/mocks/mock_mcp.py"

echo "==> ${KAGENT_NS}: MCPServer mock-mcp (kmcp), RemoteMCPServer mock-mcp, Agent toolcall"
k -n "$KAGENT_NS" create configmap mock-mcp-src --from-file=mock_mcp.py="$SRC" \
  --dry-run=client -o yaml | k apply -f - >/dev/null
k apply -f - >/dev/null <<EOF
apiVersion: kagent.dev/v1alpha1
kind: MCPServer
metadata:
  name: mock-mcp
  namespace: ${KAGENT_NS}
  annotations: {mocks/hash: "$(shasum < "$SRC" | cut -c1-12)"}
spec:
  transportType: http
  httpTransport:
    targetPort: 8080
    path: /mcp
  deployment:
    image: public.ecr.aws/docker/library/python:3.12-alpine
    cmd: python3
    args: ["-u", "/mocks/mock_mcp.py", "8080"]
    port: 8080
    volumes:
    - name: mocks
      configMap: {name: mock-mcp-src}
    volumeMounts:
    - {name: mocks, mountPath: /mocks}
---
apiVersion: api.kagent.dev/v1alpha3
kind: RemoteMCPServer
metadata: {name: mock-mcp, namespace: ${KAGENT_NS}}
spec:
  description: MCP double deployed by kmcp; every tool returns TOOL-name-OK
  protocol: STREAMABLE_HTTP
  url: http://mock-mcp.${KAGENT_NS}.svc:8080/mcp
  timeout: 30s
---
apiVersion: api.kagent.dev/v1alpha3
kind: AgentTemplate
metadata: {name: toolcall, namespace: ${KAGENT_NS}}
spec:
  description: Calls a mock MCP tool when asked
  modelConfig:
    name: mock-model
  systemPrompt: |
    Follow the user's instructions exactly.
  tools:
  - mcp:
      server:
        kind: RemoteMCPServer
        name: mock-mcp
---
apiVersion: api.kagent.dev/v1alpha3
kind: Agent
metadata: {name: toolcall, namespace: ${KAGENT_NS}}
spec:
  template:
    ref:
      name: toolcall
  harnessRef:
    name: adk
EOF

for _ in $(seq 1 36); do
  k -n "$KAGENT_NS" get deploy mock-mcp >/dev/null 2>&1 && break
  sleep 5
done
k -n "$KAGENT_NS" rollout status deploy/mock-mcp --timeout=180s \
  || { echo "    ✗ kmcp didn't bring up deploy/mock-mcp. MCPServer status:" >&2
       k -n "$KAGENT_NS" get mcpserver mock-mcp -o jsonpath='{range .status.conditions[*]}      {.type}={.status} {.reason}: {.message}{"\n"}{end}' >&2
       exit 1; }
echo "    ✓ kmcp deployed mock-mcp"
