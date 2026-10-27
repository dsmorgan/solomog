#!/usr/bin/env bash
# agentevals, driven the way the UI's Evaluations pages drive it (the rpc.evals.solo.io services on
# the controller's :8085, gRPC-Web only, so helpers/grpcweb makes the calls).
#
# What works on alpha11, asserted:
#   - the agentevals service is up and the controller lists its built-in evaluators
#   - eval sets and eval configs can be created
#   - a turn's trace carries the prompt and reply (content capture, 40-agents.sh)
#
# What doesn't, and why (2026-10-22, enterprise kagent 1.0.0-alpha11, Go runtime golang-adk 1.0.0-alpha14):
#   - EvalRuns/Create with AGENT_INVOKE is refused: "only trace_replay is supported in this build".
#     Reported, not failed: it's how this build is meant to behave.
#   - Turning a Go-runtime trace into eval invocations FAILS, so CreateFromTrace and TRACE_REPLAY have
#     nothing to score. agentevals sees the gcp.vertex.agent scope, picks its ADK converter, and that
#     converter needs gcp.vertex.agent.llm_request or llm_response on the generate_content span. The
#     Go ADK writes gen_ai.input.messages and gen_ai.output.messages instead and never writes the ADK
#     keys. agentevals logs: "invoke_agent span … has no converter-compatible ADK LLM descendants;
#     expected call_llm or ADK generate_content spans". This test fails on it until that changes.
. "$(dirname "$0")/../helpers/checks.sh"

k -n "$KAGENT_NS" rollout status deploy/kagent-agentevals --timeout=60s >/dev/null 2>&1 \
  && ok "deploy/kagent-agentevals Ready" || { no "deploy/kagent-agentevals not Ready"; exit 1; }

canary="eval-${RANDOM}${RANDOM}"
turn assistant "Evaluate ${canary}" && grep -q "ECHO.*${canary}" <<<"$TURN_OUT" \
  || { no "turn failed: $(tail -3 <<<"$TURN_OUT")"; exit 1; }
tid=""
for _ in $(seq 1 30); do
  tid="$(ch "select TraceId from genai_spans where AgentName = 'assistant' and position(Input, '${canary}') > 0 limit 1")"
  [ -n "$tid" ] && break; sleep 2
done
[ -n "$tid" ] && ok "turn traced with its prompt captured (trace ${tid})" \
  || { no "no span with ${canary} in its Input after 60s: is OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT on the Harness?"; exit 1; }

api_open || exit 1
trap pf_stop EXIT

evs="$(ent rpc.evals.solo.io.Evaluators/List '{"limit":100}' 2>&1 | jq -r '[.evaluators[]?.name] | join(",")' 2>/dev/null)"
case ",$evs," in *,response_match_score,*) ok "built-in evaluators: ${evs}" ;; *) no "Evaluators/List: ${evs:-nothing}" ;; esac

set_json="$(ent rpc.evals.solo.io.EvalSets/Create "{\"name\":\"${canary}\",\"cases\":[{\"name\":\"echo\",\"conversation\":{\"invocations\":[{\"userContent\":{\"role\":\"user\",\"parts\":[{\"text\":\"Evaluate ${canary}\"}]},\"finalResponse\":{\"role\":\"model\",\"parts\":[{\"text\":\"ECHO Evaluate ${canary}\"}]}}]}}]}" 2>&1)"
sid="$(jq -r '.evalSet.id // empty' <<<"$set_json" 2>/dev/null)"
[ -n "$sid" ] && ok "EvalSets/Create: set ${sid}, one case" || { no "EvalSets/Create: ${set_json}"; exit 1; }
cfg_json="$(ent rpc.evals.solo.io.EvalConfigs/Create "{\"name\":\"${canary}\",\"evaluators\":[{\"name\":\"response_match_score\",\"type\":\"EVALUATOR_TYPE_BUILTIN\",\"threshold\":0.8,\"timeoutS\":60}]}" 2>&1)"
cid="$(jq -r '.evalConfig.id // empty' <<<"$cfg_json" 2>/dev/null)"
[ -n "$cid" ] && ok "EvalConfigs/Create: response_match_score, threshold 0.8" || { no "EvalConfigs/Create: ${cfg_json}"; exit 1; }

out="$(ent rpc.evals.solo.io.EvalRuns/Create "{\"evalConfigId\":\"${cid}\",\"evalSetId\":\"${sid}\",\"approach\":\"EVAL_RUN_APPROACH_AGENT_INVOKE\",\"target\":{\"agent_name\":\"assistant\",\"agent_id\":\"${KAGENT_NS}/assistant\"}}" 2>&1)"
case "$out" in
  *"only trace_replay"*) say "AGENT_INVOKE refused as expected on alpha11: ${out}" ;;
  *'"evalRun"'*) ok "AGENT_INVOKE accepted: this build runs live evaluations (newer than alpha11?)" ;;
  *) no "AGENT_INVOKE: ${out}" ;;
esac

out="$(ent rpc.evals.solo.io.EvalSets/CreateFromTrace "{\"name\":\"${canary}-from-trace\",\"traceId\":\"${tid}\",\"caseName\":\"replay\"}" 2>&1)"
if jq -e '.evalSet.cases[0].conversation.invocations | length > 0' <<<"$out" >/dev/null 2>&1; then
  ok "EvalSets/CreateFromTrace made a case from the Go-runtime trace"
else
  no "EvalSets/CreateFromTrace: ${out}"
  say "agentevals' ADK converter needs gcp.vertex.agent.llm_request/llm_response, which the Go ADK doesn't write:"
  k -n "$KAGENT_NS" logs deploy/kagent-agentevals --since=2m 2>/dev/null | grep "$tid" | grep -m1 "converter-compatible" | sed 's/.*WARNING:agentevals.converter://' | cut -c1-260 | sed 's/^/      /'
fi

# TRACE_REPLAY with the hand-written set: the run converts the same trace, so it shows the same gap
# from the run's side (a status and per-result errors rather than a refused call).
j="$(ent rpc.evals.solo.io.EvalRuns/Create "{\"evalConfigId\":\"${cid}\",\"evalSetId\":\"${sid}\",\"approach\":\"EVAL_RUN_APPROACH_TRACE_REPLAY\",\"target\":{\"trace_ids\":[\"${tid}\"]}}" 2>&1)"
rid="$(jq -r '.evalRun.id // empty' <<<"$j" 2>/dev/null)"
[ -n "$rid" ] || { no "EvalRuns/Create TRACE_REPLAY: ${j}"; exit "$fail"; }
for _ in $(seq 1 60); do
  st="$(ent rpc.evals.solo.io.EvalRuns/Get "{\"id\":\"${rid}\"}" | jq -r '.evalRun.status // empty' | sed 's/EVAL_RUN_STATUS_//')"
  case "$st" in SUCCEEDED|FAILED|CANCELLED) break ;; esac
  sleep 3
done
res="$(ent rpc.evals.solo.io.EvalResults/ListByRun "{\"runId\":\"${rid}\",\"limit\":10}" \
  | jq -r '.results[]? | "\(.evaluatorName) \(.status | sub("EVAL_RESULT_STATUS_"; "")) score=\(.score // 0)\(if .errorText then " error=" + (.errorText | .[0:160]) else "" end)"' | head -1)"
sum="$(ent rpc.evals.solo.io.EvalRuns/Get "{\"id\":\"${rid}\"}" | jq -c '.evalRun.summary // {}' | cut -c1-200)"
case "$st $res" in
  "SUCCEEDED "*" PASSED "*) ok "TRACE_REPLAY run ${rid}: ${st}, ${res}" ;;
  # The run reports SUCCEEDED with nothing scored: a green run in the UI that evaluated nothing.
  *) no "TRACE_REPLAY run ${rid}: ${st:-no status}, ${res:-no results} (summary ${sum})" ;;
esac
n="$(k -n "$KAGENT_NS" exec kagent-clickhouse-shard0-0 -c clickhouse -- clickhouse-client --user default --password password \
  -q "select count() from agentevals.eval_results where toString(run_id) = '${rid}'" 2>&1)"
say "ClickHouse agentevals.eval_results rows for that run: ${n}"
exit "$fail"
