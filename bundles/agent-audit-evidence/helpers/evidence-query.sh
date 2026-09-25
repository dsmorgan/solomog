#!/usr/bin/env bash
# The auditor's question, answered from the log store:
#   every attempt to call approve_prior_auth in the last MINUTES, with which agent (asserted and
#   declared), for which reviewer, under which scopes, and what the gateway decided.
#
# Usage:  CLUSTER=audit bash helpers/evidence-query.sh                 # last 15 minutes
#         CLUSTER=audit MINUTES=60 TOOL=get_claim bash helpers/evidence-query.sh
#         CLUSTER=audit TRACE=<trace.id> bash helpers/evidence-query.sh   # + each app's own log line
#
# Reads Loki (proxy → OTLP → collector → Loki), the same shape of query a SIEM runs. The Grafana
# equivalent is printed at the end.
set -euo pipefail
. "$(dirname "$0")/_env.bash"
MINUTES="${MINUTES:-15}"
TOOL="${TOOL:-approve_prior_auth}"

PORT=33$(( ($$ % 90) + 10 ))
kubectl --context "$CONTEXT" port-forward -n agent-evidence svc/evidence-loki "${PORT}:3100" >/dev/null 2>&1 &
PF=$!; trap 'kill $PF 2>/dev/null || true' EXIT
for _ in 1 2 3 4 5 6 7 8; do curl -s -o /dev/null "http://127.0.0.1:${PORT}/ready" && break; sleep 1; done

Q="{service_name=\"${GATEWAY}\"} | gen_ai_tool_name=\"${TOOL}\" | mcp_method_name=\"tools/call\""
RESP=$(curl -s -G "http://127.0.0.1:${PORT}/loki/api/v1/query_range" --data-urlencode "query=${Q}" \
  --data-urlencode "start=$(( $(date +%s) - MINUTES * 60 ))000000000" --data-urlencode "end=$(date +%s)000000000" \
  --data-urlencode 'limit=200')

echo "Every ${TOOL} call in the last ${MINUTES} minutes"
echo ""
printf '%s' "$RESP" | jq -r '
  [.data.result[] | .stream as $s | .values[] | {ts: .[0]} + $s]
  | sort_by(.ts) | .[]
  | [ (.ts | tonumber / 1e9 | strftime("%H:%M:%S")),
      (.audit_agent_id // "-"),
      (.audit_declared_agent_name // "-") + "/" + (.audit_declared_agent_version // "-"),
      (.audit_user_email // .jwt_sub // "-"),
      (.audit_token_scopes // "-"),
      ((.http_status // "-") + " " + (if (.reason // "") == "" then "allowed" else "DENIED " + .reason end)),
      (.trace_id // "-") ]
  | @tsv' \
| (printf 'TIME\tQ1 AGENT (IdP)\tQ1 DECLARED\tQ2 REVIEWER\tQ2 SCOPES\tQ4 DECISION\tTRACE\n'; cat) \
| column -t -s "$(printf '\t')"

if [ -n "${TRACE:-}" ]; then
  echo ""
  echo "Application logs for trace ${TRACE} (each app's own account, joined on trace.id)"
  for d in priorauth-agent intake-agent claims-mcp; do
    kubectl --context "$CONTEXT" logs -n agent-evidence "deploy/$d" --since="${MINUTES}m" 2>/dev/null \
      | sed -n 's/^app-log //p' | jq -c --arg t "$TRACE" 'select(.trace_id == $t)' 2>/dev/null \
      | sed "s/^/  ${d}: /"
  done
fi

echo ""
echo "Grafana → Explore → Loki:  ${Q}"
