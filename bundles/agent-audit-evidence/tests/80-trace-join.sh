#!/usr/bin/env bash
# "Keep your logs": the gateway record joins each application's own log line on trace.id.
#
# The agents forward the traceparent the gateway sent them, and write an app-log line for the approve
# attempt; claims-mcp writes one for each tool it serves. This asserts the trace id on intake-agent's
# own log line for its refused attempt equals the trace id on the gateway's record of that tools/call,
# and the same for priorauth-agent and claims-mcp's record of the approval.
set -uo pipefail
. "$(dirname "$0")/_lib.bash"
ev_require_login
ID_TOKEN=$(ev_id_token)
fail=0

for role in intake priorauth; do
  curl -sS -o /dev/null "https://${HOST}/agents/${role}" -H "Authorization: Bearer ${ID_TOKEN}"
done
sleep 2

applog() {  # $1 deployment  $2 jq filter  → last matching app-log JSON
  kubectl --context "$CONTEXT" logs -n "$NS_APP" "deploy/$1" --since=3m 2>/dev/null \
    | sed -n 's/^app-log //p' | jq -c "select($2)" 2>/dev/null | tail -1
}
gwtrace() {  # $1 agent name → trace.id of the latest gateway record of its approve tools/call
  ev_log_select "\"${SENSITIVE_TOOL}\"" \
    ".[\"gen_ai.tool.name\"] == \"${SENSITIVE_TOOL}\" and .[\"audit.declared.agent_name\"] == \"$1\" and .[\"mcp.method.name\"] == \"tools/call\"" 10 \
    | jq -r '.["trace.id"] // empty'
}

A_INTAKE=$(applog intake-agent ".action == \"${SENSITIVE_TOOL}\"")
G_INTAKE=$(gwtrace "$INTAKE_NAME")
echo "── intake-agent (refused)"
echo "  app log:  ${A_INTAKE:-<none>}"
echo "  gateway:  trace.id=${G_INTAKE:-<none>}"
T=$(printf '%s' "$A_INTAKE" | jq -r '.trace_id // empty')
if [ -n "$T" ] && [ "$T" = "$G_INTAKE" ]; then echo "  ✓ joined on trace.id ${T}"; else echo "  ✗ trace ids differ or are missing"; fail=1; fi

A_MCP=$(applog claims-mcp ".action == \"${SENSITIVE_TOOL}\"")
G_PRIOR=$(gwtrace "$PRIORAUTH_NAME")
echo "── priorauth-agent (approved), as claims-mcp logged it"
echo "  app log:  ${A_MCP:-<none>}"
echo "  gateway:  trace.id=${G_PRIOR:-<none>}"
T=$(printf '%s' "$A_MCP" | jq -r '.trace_id // empty')
if [ -n "$T" ] && [ "$T" = "$G_PRIOR" ]; then echo "  ✓ joined on trace.id ${T}"; else echo "  ✗ trace ids differ or are missing"; fail=1; fi

if [ "$fail" != 0 ]; then
  echo "  An empty app-log trace_id means no traceparent reached the workload: check that a"
  echo "  frontend.tracing policy exists on the gateway (62-tracing.sh)."
  exit 1
fi
echo "✓ the gateway record and each application's own log line share one trace id"
