#!/usr/bin/env bash
# THE EVIDENCE: the gateway's own record of the forced approve, answering Q1 to Q4.
#
# Drives intake-agent (whose forced approve_prior_auth is refused) and priorauth-agent (whose approve
# is allowed), then reads the gateway access log for each agent's tools/call of approve_prior_auth and
# asserts every field the pitch deck's evidence slide shows:
#   Q1 audit.agent.id (IdP-asserted act.sub), audit.agent.okta_id, audit.declared.agent_name/version
#   Q2 jwt.sub, audit.user.email, audit.token.scopes, audit.token.issuer
#   Q3 gen_ai.tool.name, route, mcp.target
#   Q4 http.status, reason (MCP on the refusal; absent on the allowed call)
#   trace.id
set -uo pipefail
. "$(dirname "$0")/_lib.bash"
ev_require_login
ID_TOKEN=$(ev_id_token)
fail=0

for role in intake priorauth; do
  curl -sS -o /dev/null "https://${HOST}/agents/${role}" -H "Authorization: Bearer ${ID_TOKEN}"
done

record() {  # $1 declared agent name (X-Agent-Name)
  ev_log_select "\"${SENSITIVE_TOOL}\"" \
    ".[\"gen_ai.tool.name\"] == \"${SENSITIVE_TOOL}\" and .[\"audit.declared.agent_name\"] == \"$1\" and .[\"mcp.method.name\"] == \"tools/call\"" 15
}

show() {  # $1 line
  local l="$1"
  echo "  Q1 which agent"
  ev_report_field "$l" audit.agent.id                  || fail=1
  ev_report_field "$l" audit.agent.okta_id
  ev_report_field "$l" audit.declared.agent_name
  ev_report_field "$l" audit.declared.agent_version
  echo "  Q2 whose authority"
  ev_report_field "$l" jwt.sub                         || fail=1
  ev_report_field "$l" audit.user.email                || fail=1
  ev_report_field "$l" audit.token.scopes              || fail=1
  ev_report_field "$l" audit.token.issuer              || fail=1
  echo "  Q3 what it called"
  ev_report_field "$l" gen_ai.tool.name                || fail=1
  ev_report_field "$l" route
  ev_report_field "$l" mcp.target
  echo "  Q4 which control decided"
  ev_report_field "$l" http.status
  ev_report_field "$l" reason
  ev_report_field "$l" error
  echo "  join"
  ev_report_field "$l" trace.id                        || fail=1
}

echo "── the refused attempt: intake-agent forcing ${SENSITIVE_TOOL}"
DENY=$(record "$INTAKE_NAME") || DENY=""
if [ -z "$DENY" ]; then
  echo "✗ no access record for intake-agent's tools/call of ${SENSITIVE_TOOL}"; exit 1
fi
show "$DENY"
[ "$(printf '%s' "$DENY" | jq -r '.reason // empty')" = MCP ] || { echo "  ✗ expected reason=MCP"; fail=1; }
[ "$(printf '%s' "$DENY" | jq -r '.["audit.agent.id"] // empty')" = "$INTAKE_ACTOR" ] || { echo "  ✗ expected audit.agent.id=${INTAKE_ACTOR}"; fail=1; }

echo ""
echo "── the allowed call: priorauth-agent approving"
ALLOW=$(record "$PRIORAUTH_NAME") || ALLOW=""
if [ -z "$ALLOW" ]; then
  echo "✗ no access record for priorauth-agent's tools/call of ${SENSITIVE_TOOL}"; exit 1
fi
show "$ALLOW"
[ -z "$(printf '%s' "$ALLOW" | jq -r '.reason // empty')" ] || { echo "  ✗ the allowed call carries a reason"; fail=1; }
[ "$(printf '%s' "$ALLOW" | jq -r '.["audit.agent.id"] // empty')" = "$PRIORAUTH_ACTOR" ] || { echo "  ✗ expected audit.agent.id=${PRIORAUTH_ACTOR}"; fail=1; }

echo ""
echo "  full refused record:"; printf '%s\n' "$DENY" | jq -S . | sed 's/^/    /'
[ "$fail" = 0 ] || exit 1
echo "✓ one record per tool call answers which agent, whose authority, what it called, and which control decided"
