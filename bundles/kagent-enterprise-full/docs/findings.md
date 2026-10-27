# Findings

Observed on 2026-10-22 with enterprise kagent `1.0.0-alpha11` (community kagent `1.0.0-alpha14`,
Go runtime `golang-adk`), substrate-enterprise `0.5.0-alpha4`, agentevals image `1.0.0-alpha11`,
on vind with Kubernetes 1.36.5. None of these are filed.

## 1. agentevals can't evaluate traces from the Go runtime

**What happens:**
- `EvalSets/CreateFromTrace` on a turn's trace returns `InvalidArgument: trace … did not produce any
  invocations`.
- An `EvalRuns/Create` with `TRACE_REPLAY` on the same trace finishes `SUCCEEDED` with no results
  and no rows in ClickHouse `agentevals.eval_results`. Its summary counts the case as `errored: 1`.
  In the UI, that's a green run that scored nothing.

**Why:**
- agentevals picks a converter per trace. The Go ADK's spans carry the `gcp.vertex.agent` scope, so
  it picks its ADK converter.
- That converter accepts a `generate_content` span only when it carries
  `gcp.vertex.agent.llm_request` or `gcp.vertex.agent.llm_response`
  (`agentevals/extraction.py`, `is_adk_generate_content_llm_span`).
- The Go ADK writes the GenAI convention keys `gen_ai.input.messages` and `gen_ai.output.messages`
  instead, and adk-go has no code that writes the ADK keys.
- agentevals' log line: `invoke_agent span … has no converter-compatible ADK LLM descendants;
  expected call_llm or ADK generate_content spans`.
- agentevals also has a GenAI converter (`genai_converter.py`) that reads the keys the Go ADK does
  write, but auto-detection never chooses it for these spans.

**Also:** `EvalRuns/Create` with `AGENT_INVOKE` is refused: `only trace_replay is supported in this
build`. So on alpha11 a Go-runtime agent can't be evaluated either way.

**The Python runtime isn't a way around it** (tried 2026-10-26). It writes the ADK keys, but it
can't run on this build:
- Community kagent stopped publishing the Python `kagent-adk` image after `1.0.0-alpha13`
  (kagent-dev/kagent#3221); 1.0 ships only the Go runtime plus the Claude and Codex harnesses.
- With `kagent-adk:1.0.0-alpha13` as a Harness image, the image's default `run` command exits
  with `Missing argument 'name'`. Overriding `workload.command` to `kagent-adk static` gets
  further, then the golden actor crashes on the controller's config: `runtime.port` is an
  integer, `runtime.telemetry.traces` and `runtime.skill_tools` are unknown keys, and `model`,
  `description` and `instruction` are missing. The Agent ends `GoldenActorCrashed`.

**Where it's headed** (2026-10-26):
- solo-io/enterprise-kagent#429 (open, `Roadmap-worthy`) redesigns the integration on the
  upstream agentevals gRPC API: the controller sends traces from `genai_spans` as OTLP, and
  agentevals runs unmodified. Upstream agentevals v0.10.0 (agentevals-dev/agentevals#241)
  ingests OTel GenAI spans natively, which is what the Go runtime writes.
- solo-io/enterprise-kagent#459 (open) removes the agentevals values from the chart until #429
  lands, and the chart on `main` already has no `agentevals` or `kmcp` subchart. Expect both to
  be gone from the next release.
- solo-io/enterprise-kagent#246 (open) asks for evals on traces from Substrate agents.

`tests/90-agentevals.sh` reproduces the alpha11 behavior and fails on it.

## 2. `config.runtimeDefaults.telemetry.captureContent` had no effect on the Go runtime

With `captureContent: true` in the chart, the setting appears in the controller's rendered
`controller.yaml` under `runtimeDefaults.telemetry`, and the traces endpoint from the same block
does reach the runtime. Prompt and reply text still didn't appear in the spans, including after
the Agents were recreated so their golden snapshots were rebuilt.

Setting the runtime's own override on the Harness did work:

```yaml
spec:
  env:
  - {name: OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT, value: SPAN_ONLY}
```

`40-agents.sh` does that. Not traced further: whether the controller renders that variable from
`captureContent` for the Go runtime on this build.

## 3. Smaller things worth knowing

- **The enterprise APIs are gRPC-Web only.** The `rpc.*.solo.io` services (evals, auth config) are
  served on the controller's `:8085` as gRPC-Web with protobuf bodies; a JSON body fails to
  unmarshal and native gRPC isn't served there. `config.server.grpcReflection: true` on `:8083`
  still describes their messages, which is what `helpers/grpcweb` uses.
- **The UI's `/api/` goes to `:8085`**, not `:8083`. The browser's kagent API calls go to
  `/api/proxy/cluster/<cluster>/api/kagent.api.v1.<Service>/<Method>`.
- **`agentevals.podLabels`** defaults to the Istio ambient label; this bundle sets `{}`.
- **The chart's NOTES warn** that `controller.agentevals.enabled` must be paired with
  `agentevals.enabled` "in the management chart". It prints whenever the controller flag is on,
  even with both set in this one chart.
