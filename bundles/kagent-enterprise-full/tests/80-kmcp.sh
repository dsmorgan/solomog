#!/usr/bin/env bash
# kmcp owns the MCP server: the MCPServer reports Ready, the Deployment and Service are its
# children, and kagent discovered the server's tools through the RemoteMCPServer.
. "$(dirname "$0")/../helpers/checks.sh"

m="$(k -n "$KAGENT_NS" get mcpserver mock-mcp -o json 2>/dev/null)"
[ -n "$m" ] || { no "MCPServer mock-mcp missing (45-mcp-tool.sh)"; exit 1; }
conds="$(jq -r '[.status.conditions[]? | "\(.type)=\(.status)"] | join(" ")' <<<"$m")"
jq -e '[.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length > 0' <<<"$m" >/dev/null \
  && ok "MCPServer mock-mcp Ready (${conds})" || no "MCPServer mock-mcp not Ready (${conds:-no conditions})"
uid="$(jq -r .metadata.uid <<<"$m")"
for kind in deploy svc; do
  k -n "$KAGENT_NS" get "$kind" mock-mcp -o json 2>/dev/null | jq -e --arg u "$uid" '[.metadata.ownerReferences[]? | select(.uid == $u)] | length > 0' >/dev/null \
    && ok "${kind}/mock-mcp is owned by the MCPServer" || no "${kind}/mock-mcp isn't owned by the MCPServer"
done
tools="$(k -n "$KAGENT_NS" get remotemcpserver.api.kagent.dev mock-mcp -o json 2>/dev/null | jq -r '[.status.discoveredTools[]?.name] | join(",")')"
[ -n "$tools" ] && ok "RemoteMCPServer mock-mcp discovered tools: ${tools}" || no "RemoteMCPServer mock-mcp lists no discovered tools"
exit "$fail"
