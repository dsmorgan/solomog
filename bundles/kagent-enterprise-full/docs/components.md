# Components: what runs where, and who talks to whom

This page maps every pod this bundle installs to what it does and how a turn moves between
them. Names are as installed by `kagent-enterprise` `1.0.0-alpha11` and `substrate-enterprise`
`0.5.0-alpha4`.

## Namespaces at a glance

| Namespace | Installed by | Holds |
|---|---|---|
| `kagent` | `30-kagent.sh`, `40-agents.sh`, `45-mcp-tool.sh` | The kagent control plane, UI, telemetry, kmcp, the WorkerPool's workers, and the mock MCP server |
| `ate-system` | `20-substrate.sh` | The Substrate control plane and node agent |
| `podcertificate-controller-system` | `20-substrate.sh` | The certificate controller and its CA pools |
| `postgres` | `10-postgres.sh` | The one PostgreSQL server both products use |
| `mock-system` | `35-mock-model.sh` | The mock model |

## kagent (`kagent` namespace)

| Workload | Containers | Ports | What it does |
|---|---|---|---|
| `deploy/kagent-controller` | `controller` (8083, 8085, 9090), `idp` (5556) | 8083, 8085 | Reconciles Agents, Harnesses and templates and asks Substrate to build and run agents. 8083 serves the kagent API as native gRPC and A2A. 8085 is the HTTP surface the UI uses: `/autoauth/`, the kagent API as gRPC-Web under `/api/proxy/cluster/<cluster>/api/`, and the enterprise `rpc.*.solo.io` services (evals) as gRPC-Web under `/api/`. `idp` is the bundled IdP, rendered only because `enterprise.oidc.issuer` is empty; it issues an admin token to anyone. |
| `deploy/kagent-ui` | `ui` (nginx and the SPA) | 8080 | Serves the app and `env-config.js`, and proxies `/autoauth/` and `/api/` to the controller's 8085. |
| `deploy/kagent-agentevals` | `agentevals` | 8001 API | Runs evaluations the controller hands it, keeps runs in PostgreSQL schema `agentevals` (its own login), and writes results to ClickHouse database `agentevals`. See `docs/findings.md` item 1. |
| `deploy/kmcp-enterprise-controller-manager` | `manager` | 8443 metrics | Turns an `MCPServer` (`kagent.dev/v1alpha1`) into a Deployment and Service it owns. |
| `statefulset/solo-enterprise-telemetry-collector` | OpenTelemetry Collector | 4317 OTLP gRPC | Receives traces, metrics and logs from agent runtimes and Substrate, and writes them to ClickHouse. Rendered only with `telemetry.enabled` and `global.cluster`. |
| `deploy/solo-enterprise-k8sobjects` | OpenTelemetry Collector | 8888 metrics | Watches Kubernetes objects and writes their history to ClickHouse (`otel_k8sobjects_*`). |
| `statefulset/kagent-clickhouse-shard0` | `clickhouse` | 9000 native, 8123 HTTP | Stores everything the UI's tracing and dashboard pages read. No persistent volume by default. |
| `deploy/kagent-default` | `ateom` (gVisor) | 8080 readiness | The WorkerPool's workers. Substrate restores agent actors onto these. |
| `deploy/mock-mcp` | Python | 8080 | The mock MCP server, created by kmcp from `MCPServer mock-mcp`. |

### The ClickHouse tables to look at

| Table | Written by | Holds |
|---|---|---|
| `genai_spans` | collector, from agent runtimes | One row per GenAI span: `invoke_agent`, `generate_content`, `execute_tool`, with agent, namespace, cluster, model and tool names. Prompt and reply text are captured because the Harness sets `OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=SPAN_ONLY`. |
| `genai_turns` | materialized view over spans | One row per turn |
| `otel_traces_json` | collector | Raw spans |
| `substrate_actor_lifecycle`, `substrate_actor_requests`, `substrate_actor_state` | collector, from Substrate | Actor events and requests: the dashboard's fleet figures. Empty unless the substrate release sets `otel.endpoint`. |
| `otel_k8sobjects_*` | `solo-enterprise-k8sobjects` | Kubernetes object history |
| `agentevals.eval_results` | agentevals result sink | One row per scored case and evaluator |

Query one yourself:

```bash
kubectl --context vcluster-docker_kef -n kagent exec kagent-clickhouse-shard0-0 -c clickhouse -- \
  clickhouse-client --user default --password password --database kagent \
  -q "select Timestamp, Operation, AgentName, ToolName from genai_spans order by Timestamp desc limit 10"
```

## Substrate (`ate-system` and `podcertificate-controller-system`)

| Workload | What it does |
|---|---|
| `deploy/ate-api-server` (2 replicas) | Substrate's API (`api.ate-system.svc:443`, mTLS). The kagent controller calls it to create atespaces, templates and actors. Keeps its records in PostgreSQL database `substrate`. |
| `deploy/ate-controller` | Builds golden snapshots: starts an agent's runtime once, checkpoints it, and stores it in rustfs. An Agent becomes Ready when its golden exists. |
| `daemonset/atelet` | The node agent. Pulls runtime images and restores and checkpoints actors on the workers. |
| `deploy/atenet-router` | agentgateway, run as the actor dataplane. The controller reaches an actor through it (`config.substrate.routerUrl`). |
| `deploy/atenet-egress` | The actors' egress proxy. It can inject credentials into HTTPS calls, using `egress-mitm-ca-pool`. |
| `deploy/k8s-credential-provider` | Hands Secrets to atespaces, default-deny; `credentialProvider.namespacePolicies` lets atespace `kagent` read namespace `kagent`. |
| `deploy/rustfs` | In-cluster S3-compatible store for snapshots (bucket `ate-snapshots`). |
| `deploy/podcertificate-controller` | Signs every `PodCertificateRequest`, so each Substrate pod and worker gets an mTLS identity through a projected `podCertificate` volume. This native mode needs the feature gates in `helpers/vcluster.yaml`. |

`05-ca-bootstrap.sh` makes the CA and JWT pools these mount; its header lists which consumer reads
which pool.

## A turn, end to end

1. A client (the UI, or `helpers/a2a-turn` in tests) gets a token from the bundled IdP and sends
   an A2A message to the controller on 8083, naming `<namespace>/<agent>`.
2. The controller creates or resumes a Session, and asks `ate-api-server` for an actor of that
   Agent's template.
3. Substrate restores the golden snapshot onto a `kagent-default` worker (gVisor), and the
   controller forwards the turn through `atenet-router` to the actor.
4. The runtime (`golang-adk`) calls the model, `mock-llm.mock-system`, and for `toolcall`, the
   MCP server `mock-mcp.kagent`.
5. The runtime exports its spans to the collector, which writes `genai_spans` and `genai_turns`.
   Substrate exports its actor events and request metrics to the same collector.
6. The reply streams back the same way.

## Things worth knowing

- **Native certificate mode.** No `ate-ca-agent` sidecars and no per-namespace trust ConfigMaps.
  An EKS cluster without the feature gates needs `usePodCertificateAPI: false` on both charts and
  the ate-ca issuer instead.
- **The bundled IdP isn't authentication.** Anyone who can reach `/autoauth/token` gets an admin
  token. Setting `enterprise.oidc.issuer` removes it, the `/autoauth/` route, and the UI's
  auto-sign-in.
- **Calling the enterprise APIs yourself.** `helpers/grpcweb` takes a method and a JSON body, for
  example `rpc.evals.solo.io.Evaluators/List '{"limit":10}'`; `helpers/checks.sh`'s `ent` wraps it
  with the port-forward and token.
- **Tracing is off unless you ask.** `telemetry.enabled` defaults to false, and even with it on, no
  runtime exports traces until `config.runtimeDefaults.telemetry.traces.endpoint` names the
  collector.
- **Agents can name only RemoteMCPServer tools.** An `MCPServer` deployed by kmcp is reached through
  a RemoteMCPServer pointing at its Service; the AgentTemplate CRD rejects any other kind.
