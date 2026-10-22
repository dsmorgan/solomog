# kagent-enterprise-full — every kagent Enterprise component on Agent Substrate, on vind

One kagent Enterprise install with everything it ships turned on: the UI with the bundled IdP,
ClickHouse-backed tracing, kmcp, and Agent Substrate running agents in gVisor sandboxes. A
mock model and a mock MCP server make every turn predictable and free. Single tenant, made for
learning how the pieces fit, not for reproducing a customer.

## Deploy

```bash
# The cluster needs Kubernetes feature gates for native pod certificates, so create it with
# this bundle's vcluster file (create-time only; changing it means recreating the cluster).
solomog vind:create CLUSTER=kef VCLUSTER_VALUES=bundles/kagent-enterprise-full/helpers/vcluster.yaml
solomog apply BUNDLE=kagent-enterprise-full CLUSTER=kef
solomog test  BUNDLE=kagent-enterprise-full CLUSTER=kef          # TESTS=40 runs one

# Open the UI (signs in as admin, no login page)
bash bundles/kagent-enterprise-full/helpers/ui.sh kef            # http://localhost:8080
```

## Facts

| | |
|---|---|
| covers | kagent controller, UI, bundled IdP, ClickHouse, telemetry collector, kmcp, Substrate (native podcert, gVisor), PostgreSQL with two logins per product |
| needs | `KAGENT_LICENSE_KEY` and `AGENTGATEWAY_LICENSE_KEY` (Substrate's router runs agentgateway) in `.env`; Go for the turn tests; about 6 CPU and 10 GiB free in Docker |
| versions | kagent Enterprise `1.0.0-alpha11`, substrate-enterprise `0.5.0-alpha4-da3c2e5` (`KEF_*` in `helpers/env.sh`) |
| clash-safe | no: owns the cluster |
| verified | 2026-10-22 on vind (Kubernetes 1.36.5): 8/8 from a fresh cluster, `vind:create apply test` chained, 2m24s |
| not yet | agentevals (phase 2) |

## Tests

`10-platform` workloads Ready and native certificate mode · `20-auth` IdP token accepted, bad token
refused · `30-golden` Agents Ready · `40-turn` a turn through the mock model · `50-ui` the UI's
nginx: app, `env-config.js`, token, and an API call as the browser makes it · `60-tracing` spans,
turns and Substrate events in ClickHouse · `70-mcp-tool` a tool call to the kmcp server ·
`80-kmcp` MCPServer Ready, owned children, tools discovered.

## Layout

| File | Does |
|---|---|
| `00-preflight.sh` | Refuses a cluster without the certificate APIs or a pod-reachable `jwks_uri` |
| `05-ca-bootstrap.sh` | The CA and JWT pools Substrate mounts and no chart creates |
| `10-postgres.sh` | PostgreSQL with owner and read/write logins for Substrate and kagent |
| `20-substrate.sh` | `substrate-crds`, `substrate-podcert`, `substrate` |
| `30-kagent.sh` | `kagent-enterprise-crds`, `kagent-enterprise` with UI, IdP, ClickHouse, collector, kmcp |
| `35-mock-model.sh` | OpenAI-compatible mock model |
| `40-agents.sh` | ModelConfig, Harness, AgentTemplate, and Agent `assistant` |
| `45-mcp-tool.sh` | MCPServer (kmcp), RemoteMCPServer, and Agent `toolcall` |

`docs/components.md` explains what each component is, where it runs, and who talks to whom.
