#!/usr/bin/env bash
# The auditor's question, asked of a log store the way a SIEM would:
#   "every attempt to approve a prior auth in the last 15 minutes: which agent, for whom, and was it
#    allowed?"
# Proves the record survives proxy → OTLP → collector → Loki with its attributes intact. Loki turns
# attribute dots into underscores (audit.agent.id → audit_agent_id).
set -uo pipefail
. "$(dirname "$0")/_lib.bash"

r=$(kubectl --context "$CONTEXT" get deploy evidence-loki -n "$NS_APP" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[ "${r:-0}" -ge 1 ] 2>/dev/null || { echo "✗ evidence-loki is not ready"; exit 1; }

PORT=32$(( ($$ % 90) + 10 ))
kubectl --context "$CONTEXT" port-forward -n "$NS_APP" svc/evidence-loki "${PORT}:3100" >/dev/null 2>&1 &
PF=$!; trap 'kill $PF 2>/dev/null || true' EXIT
for _ in 1 2 3 4 5 6; do curl -s -o /dev/null "http://127.0.0.1:${PORT}/ready" && break; sleep 1; done

Q="{service_name=\"${GATEWAY}\"} | gen_ai_tool_name=\"${SENSITIVE_TOOL}\" | mcp_method_name=\"tools/call\""
echo "== LogQL: ${Q}"
END=$(date +%s)000000000; START=$(( $(date +%s) - 900 ))000000000
n=0
for _ in 1 2 3 4 5 6 7 8; do
  RESP=$(curl -s -G "http://127.0.0.1:${PORT}/loki/api/v1/query_range" --data-urlencode "query=${Q}" \
    --data-urlencode "start=${START}" --data-urlencode "end=$(date +%s)000000000" --data-urlencode 'limit=50')
  n=$(printf '%s' "$RESP" | jq '[.data.result[]?.values[]?] | length' 2>/dev/null || echo 0)
  [ "${n:-0}" -ge 1 ] && break; sleep 3
done
echo "  ${n} record(s)"
[ "${n:-0}" -ge 1 ] || { echo "✗ Loki holds no approve attempts. Run tests/50 or /60 first, and check: kubectl --context $CONTEXT -n $NS_APP logs deploy/evidence-collector --tail=40"; exit 1; }

printf '%s' "$RESP" | jq -r '
  [.data.result[] | .stream as $s | .values[] | ($s + (.[2] // {}))]
  | .[] | "  \(.audit_agent_id // "-")  for \(.audit_user_email // "-")  → \(.http_status // "-") \(.reason // "allowed")  trace=\(.trace_id // "-")"' | sort -u
AGENTS=$(printf '%s' "$RESP" | jq -r '[.data.result[] | .stream as $s | .values[] | ($s + (.[2] // {})) | .audit_agent_id // empty] | unique | join(",")')
case "$AGENTS" in *"$INTAKE_ACTOR"*"$PRIORAUTH_ACTOR"*|*"$PRIORAUTH_ACTOR"*"$INTAKE_ACTOR"*) ;;
  *) echo "✗ expected records for both agents, got: ${AGENTS:-none}"; exit 1 ;; esac
echo "✓ the records are queryable with identity attached"
echo "  Grafana → Explore → Loki:"
echo "    ${Q}"
