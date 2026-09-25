#!/usr/bin/env bash
# THE DEMO, end to end: one call per agent, with the reviewer's own Okta ID token.
#
#   curl -H "Authorization: Bearer $ID_TOKEN" https://$HOST/agents/intake
#
# Checkpoint 1 validates the reviewer and runs both Cross App Access legs; the agent receives the
# composite, lists its tools through /claims-tools, reads a claim, then forces approve_prior_auth.
# Same reviewer, identical agent code, different answer.
set -uo pipefail
. "$(dirname "$0")/_lib.bash"
ev_require_login
ID_TOKEN=$(ev_id_token)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail=0

for role in priorauth intake; do
  RAW=$(curl -sS -w '\n%{http_code}' "https://${HOST}/agents/${role}" -H "Authorization: Bearer ${ID_TOKEN}")
  CODE=$(printf '%s' "$RAW" | tail -n1); printf '%s' "$RAW" | sed '$d' > "$TMP/$role.json"
  if [ "$CODE" != 200 ] || ! jq -e . "$TMP/$role.json" >/dev/null 2>&1; then
    echo "✗ /agents/${role} → HTTP ${CODE}:"; cat "$TMP/$role.json"; fail=1; continue
  fi
  jq -r --arg t "$SENSITIVE_TOOL" '
    "── \(.agent)",
    "  received:  sub=\(.saw.token.sub)  email=\(.saw.token.email)  act.sub=\(.saw.token.act_sub)",
    "  tools:     \(.mcp.tools_visible | join(", "))",
    "  \($t): visible=\(.mcp.sensitive_visible) permitted=\(.mcp.sensitive_permitted)\(if .mcp.sensitive_error then "  (\(.mcp.sensitive_error))" else "" end)",
    "  traceparent in: \(.traceparent // "<none>")"' "$TMP/$role.json"
  MERR=$(jq -r '.mcp.error // empty' "$TMP/$role.json")
  [ -z "$MERR" ] || { echo "✗ ${role}: MCP hairpin failed: ${MERR}"; fail=1; }
done
[ "$fail" = 0 ] || exit 1

P="$TMP/priorauth.json"; I="$TMP/intake.json"
check() { if eval "$2"; then echo "  ✓ $1"; else echo "  ✗ $1"; fail=1; fi; }
check "same reviewer for both agents"            '[ "$(jq -r .saw.token.sub $P)" = "$(jq -r .saw.token.sub $I)" ]'
check "priorauth act.sub = ${PRIORAUTH_ACTOR}"   '[ "$(jq -r .saw.token.act_sub $P)" = "$PRIORAUTH_ACTOR" ]'
check "intake act.sub = ${INTAKE_ACTOR}"         '[ "$(jq -r .saw.token.act_sub $I)" = "$INTAKE_ACTOR" ]'
check "both read a claim (benign tool)"          '[ "$(jq -r .mcp.benign_ok $P)$(jq -r .mcp.benign_ok $I)" = truetrue ]'
check "priorauth sees and may call ${SENSITIVE_TOOL}" '[ "$(jq -r .mcp.sensitive_visible $P)$(jq -r .mcp.sensitive_permitted $P)" = truetrue ]'
check "intake neither sees nor may call it"      '[ "$(jq -r .mcp.sensitive_visible $I)$(jq -r .mcp.sensitive_permitted $I)" = falsefalse ]'
[ "$fail" = 0 ] || exit 1
echo "✓ same reviewer, identical code: only the named agent can approve, and the other never sees the tool"
