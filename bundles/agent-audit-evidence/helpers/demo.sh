#!/usr/bin/env bash
# The four demo steps from the pitch deck, one keypress at a time, for recording.
#
#   01 SIGN IN  one reviewer, two agents
#   02 LOOK     each agent lists its tools
#   03 ESCAPE   intake-agent tries approve_prior_auth anyway
#   04 ASK      the auditor's question, answered from the log store
#
# Usage:  CLUSTER=audit bash helpers/demo.sh          (log in first: bash helpers/xaa-login.sh)
#         NOPAUSE=true CLUSTER=audit bash helpers/demo.sh
set -euo pipefail
. "$(dirname "$0")/_env.bash"

pause() { [ "${NOPAUSE:-false}" = true ] || { printf '\n\033[2m[enter]\033[0m '; read -r _; }; }
title() { printf '\n\033[1;35m━━ %s\033[0m\n' "$1"; }
claims() { local s; s=$(cut -d. -f2 | tr '_-' '/+'); case $(( ${#s} % 4 )) in 2) s="$s==";; 3) s="$s=";; esac; printf '%s' "$s" | base64 -d 2>/dev/null; }

CACHE=$(bash "$HELPERS/xaa-token-path.sh" a) || { echo "✗ no login cached — run: bash $HELPERS/xaa-login.sh" >&2; exit 1; }
ID_TOKEN=$(jq -r .id_token "$CACHE")
EXP=$(printf '%s' "$ID_TOKEN" | claims | jq -r .exp)
[ "$EXP" -gt "$(date +%s)" ] || { echo "✗ the reviewer login expired — run: bash $HELPERS/xaa-login.sh" >&2; exit 1; }

title "01 · SIGN IN — one reviewer, one Okta login"
printf '%s' "$ID_TOKEN" | claims | jq '{reviewer: .email, okta_user: .sub, issuer: .iss}'
pause

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
for role in priorauth intake; do
  curl -sS "https://${HOST}/agents/${role}" -H "Authorization: Bearer ${ID_TOKEN}" > "$TMP/$role.json"
done

title "02 · LOOK — the same reviewer, through two agents"
for role in priorauth intake; do
  jq -r '"\n\(.agent)  (act.sub = \(.saw.token.act_sub))\n  tools it can see: \(.mcp.tools_visible | join(", "))"' "$TMP/$role.json"
done
pause

title "03 · ESCAPE — intake-agent tries approve_prior_auth anyway"
jq -r '"  \(.agent) → approve_prior_auth: " + (if .mcp.sensitive_permitted then "APPROVED" else "REFUSED at the gateway (\(.mcp.sensitive_error))" end)' "$TMP/intake.json"
jq -r '"  \(.agent) → approve_prior_auth: " + (if .mcp.sensitive_permitted then "APPROVED" else "REFUSED (\(.mcp.sensitive_error))" end)' "$TMP/priorauth.json"
pause

title "04 · ASK — \"who tried to approve, on whose authority, and what happened?\""
sleep 3   # let the collector flush the records to Loki
TRACE=$(kubectl --context "$CONTEXT" logs -n agent-evidence deploy/intake-agent --since=2m 2>/dev/null \
  | sed -n 's/^app-log //p' | jq -r 'select(.action == "approve_prior_auth") | .trace_id' | tail -1)
MINUTES=1 TRACE="$TRACE" CLUSTER="$CLUSTER" bash "$HELPERS/evidence-query.sh"
