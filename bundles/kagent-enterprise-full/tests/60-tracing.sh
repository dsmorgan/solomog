#!/usr/bin/env bash
# A turn shows up where the UI's tracing pages read it: GenAI spans and a turn row in ClickHouse,
# stamped with this cluster and namespace. Also checks Substrate's own telemetry, which feeds the
# dashboard's fleet figures.
#
# Prompt and reply text aren't captured by default, so the turn is found by counting spans.
. "$(dirname "$0")/../helpers/checks.sh"

spans() { ch "select count() from genai_spans where AgentName = 'assistant' and Operation = 'invoke_agent' and Namespace = '${KAGENT_NS}' and Cluster = '${CLUSTER}'"; }
before="$(spans)"
case "$before" in ''|*[!0-9]*) no "can't query ClickHouse: ${before}"; exit 1 ;; esac
turn assistant "Trace this turn" || { no "turn failed: $(tail -3 <<<"$TURN_OUT")"; exit 1; }
for _ in $(seq 1 30); do [ "$(spans)" -gt "$before" ] && break; sleep 2; done
after="$(spans)"
[ "$after" -gt "$before" ] && ok "invoke_agent span for assistant in genai_spans (${before} → ${after})" \
  || { no "no new invoke_agent span after 60s"; say "collector logs: kubectl --context ${CTX} -n ${KAGENT_NS} logs statefulset/solo-enterprise-telemetry-collector --tail=20"; }
ops="$(ch "select arrayStringConcat(groupUniqArray(Operation), ',') from genai_spans where AgentName = 'assistant'")"
ok "operations recorded for assistant: ${ops}"
t="$(ch "select count() from genai_turns")"
[ "${t:-0}" -gt 0 ] 2>/dev/null && ok "genai_turns has ${t} turn(s)" || no "genai_turns is empty"

for tbl in substrate_actor_lifecycle substrate_actor_requests; do
  n="$(ch "select count() from ${tbl}")"
  [ "${n:-0}" -gt 0 ] 2>/dev/null && ok "${tbl}: ${n} rows (Substrate telemetry reaches ClickHouse)" \
    || no "${tbl} is empty: is otel.endpoint set on the substrate release (20-substrate.sh)?"
done
exit "$fail"
