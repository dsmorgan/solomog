# Plan: `kagent-enterprise-full` bundle

Status: **Phase 1 built and verified 2026-10-22**: `bundles/kagent-enterprise-full`, 8/8 from a
fresh vind cluster in 2m24s. Phase 2 (agentevals) and phase 3 (new pins) are open. Uncommitted.

As built, versus the proposal below:
- Open questions settled by default: names `kagent-enterprise-full` and `kef`, mock model only,
  old `bundles/kagent-substrate` left alone.
- Added `05-ca-bootstrap.sh` (the pools and `ate-api-authentication`); native mode still needs them.
- `45-mcp-tool.sh` covers kmcp and the tool test together: kmcp deploys the mock MCP server from an
  `MCPServer`, and a RemoteMCPServer points at its Service (agents reference only that kind).
- Substrate's `otel.endpoint` points at kagent's collector, so the `substrate_actor_*` tables (the
  dashboard's fleet figures) fill; not in the original plan.
- The UI test calls the API as the browser does: gRPC-Web under `/api/proxy/cluster/<cluster>/api/`.

A public, single-tenant bundle that stands up every piece of enterprise kagent 1.0 on Agent
Substrate on a local vind cluster, including the UI with working tracing. The purpose is
learning the components, not reproducing a customer. Customer-specific derivatives are made
later, as private bundles, if needed.

A companion plan returns the private `customer-kagent-eks` bundle to that customer's operating
model; it lives in that bundle's `docs/plan-realign.md`.

## Decisions (agreed 2026-10-22)

| # | Decision | Notes |
|---|----------|-------|
| D1 | Runs on **local vind** | Earlier kagent 1.0 alphas ran on vind with Kubernetes feature gates on, so the native certificate APIs exist (`usePodCertificateAPI: true`, no ate-ca compatibility layer) |
| D2 | **Public** bundle, no customer names | Private derivatives later |
| D3 | **Bundled auth** (the chart's auto-auth IdP) | Empty `enterprise.oidc.issuer`. The UI signs in as admin with no login page |
| D4 | **UI tracing on, backed by ClickHouse** | The chart's default backend |
| D5 | **kmcp and agentevals** wanted; phased if easier | See phases |
| D6 | **Pinned versions** | enterprise kagent `1.0.0-alpha11`, substrate-enterprise `0.5.0-alpha4`. Swap when the next release lands (expected 2026-10-22/23) |

## Facts gathered for the plan

- **vind prior art.** `bundles/private/customer-kagent-substrate/helpers/vcluster-substrate.yaml`
  (copied into several private bundles) and the public `bundles/kagent-substrate` README. The file
  holds three things Substrate needs on vind:
  - Apiserver and controller-manager feature gates `ClusterTrustBundle`,
    `ClusterTrustBundleProjection` and `PodCertificateRequest`, plus
    `--runtime-config=certificates.k8s.io/v1beta1=true`.
  - `--service-account-jwks-uri=https://kubernetes.default.svc.cluster.local/openid/v1/jwks`. vind
    advertises 127.0.0.1, which pods can't reach.
  - An MSS-clamp systemd unit, because gVisor actors ignore the 1450 overlay MTU and TLS stalls.
  - kubelet: the same feature gates, `serializeImagePulls: false`, `maxParallelImagePulls: 4`.
- **Not yet proven on vind:** Substrate 0.5 and kagent alpha6+. The last vind runs were
  alpha5-era. Expect some new breakage.
- **Sandbox class: gVisor.** microVM needs `/dev/kvm`, which vind doesn't have.
- **Docker Desktop:** 16 CPUs and about 31 GiB. ClickHouse alone requests 2 CPU and 3Gi; the
  Substrate images are about 570 MB.
- **Chart facts at alpha11** (`charts/kagent-enterprise/values.yaml` at tag `v1.0.0-alpha11` in
  solo-io/enterprise-kagent):
  - `ui.enabled: true` by default. The UI image is `solo-enterprise-ui-frontend`.
  - With `enterprise.oidc.issuer` empty, the chart renders:
    - An `idp` sidecar on the controller.
    - An nginx `/autoauth/` route in front of it.
    - `KAGENT_UI_EXTENSION_AUTO_AUTH_ENABLED`.
    - `AUTO_AUTH_ENABLED` for the controller.
  - **Tracing needs the collector.** `telemetry.enabled` defaults to **false**, and it requires
    `global.cluster` to be set: the collector hard-fails without it.
  - **Backend choice.** `global.telemetry.backend` defaults to `clickhouse`. `postgres` is the
    "observability lite" alternative, which stores GenAI spans in PostgreSQL. It's documented in
    the values comments, never tried.
  - `clickhouse.enabled: true`, `kmcp.enabled: true`, `agentevals.enabled: false`.
  - **agentevals needs an image tag.** `agentevals.image.tag` is required when enabled, with no
    default.
  - **No bundled PostgreSQL** since alpha9. alpha11 wants two logins in Secrets
    `kagent-postgres-owner` and `kagent-postgres-readwrite`, and roles
    `config.database.owner.role` and `.readWrite.role`. The eks bundle's `17-postgres.sh` does
    this.
  - `global.istio.ambient.enabled: true` by default. It only adds labels; check that it's harmless
    without Istio.
- **What to reuse from the eks bundle** (private, so port the logic with generic names, never
  copy customer text):
  - `17-postgres.sh`: PostgreSQL with two logins.
  - `20-substrate.sh`: Substrate install.
  - `35-mock-model.sh`: the OpenAI-compatible mock.
  - `40-agents.sh`: ModelConfig, Harness and AgentTemplate.
  - `44-tool-fixture.sh`: mock MCP server.
  - `helpers/a2a-turn`: Go A2A client.
  - `helpers/checks.sh`: `admin_token` and `turn`.

## Bundle shape (proposed)

Name `kagent-enterprise-full` (open to change). Cluster name in examples: `kef`.

```
bundles/kagent-enterprise-full/
  README.md                  one screen: create cluster, apply, test, open UI
  helpers/vcluster.yaml      VCLUSTER_VALUES for vind:create (gates, jwks-uri, MSS clamp, kubelet)
  helpers/env.sh             pins and names
  helpers/ui.sh              port-forward the UI and print the URL
  helpers/a2a-turn/          Go A2A client (ported)
  00-preflight.sh            cluster gates, APIs, license present
  10-postgres.sh             PostgreSQL with owner + read/write logins
  20-substrate.sh            substrate-crds + substrate-enterprise, native podcert
  30-kagent.sh               kagent-enterprise-crds + kagent-enterprise: UI, bundled IdP,
                             ClickHouse, telemetry collector (global.cluster set), kmcp
  35-mock-model.sh           OpenAI-compatible mock (optional real key from .env later)
  40-agents.sh               ModelConfig, Harness, AgentTemplate, Agent(s)
  45-mcp-tool.sh             a mock MCP server and an Agent that calls it
  tests/                     see below
  docs/components.md         what each component is, which pod, which port, who talks to whom
```

## Tests (proposed, cheapest first)

1. `10-platform`: every Deployment and StatefulSet Ready; feature gates and APIs present.
2. `20-auth`: `/autoauth/token` returns an admin token.
3. `30-golden`: the Agent's golden snapshot is Ready.
4. `40-turn`: a turn through the mock model echoes a canary.
5. `50-ui`:
   - The UI serves through a port-forward.
   - `env-config.js` shows auto-auth on and the backend host `/`.
   - An API call through the UI's nginx succeeds with the token.
6. `60-tracing`: after a turn, its spans and turn rows appear in ClickHouse, which is what the
   UI's tracing pages read.
7. `70-mcp-tool`: a turn that calls the MCP tool; the tool records the call.
8. `80-kmcp`: an MCPServer resource deployed by kmcp becomes Ready and an agent can use it.
9. Phase 2: `90-agentevals`, an eval run that writes a result.

## Phases

1. **Phase 1:** cluster, PostgreSQL, Substrate, kagent with UI, bundled IdP, ClickHouse and
   telemetry, mock model, agents, MCP tool, kmcp. Tests 10–80. Write `docs/components.md` as I
   go.
2. **Phase 2:** agentevals (needs its image tag and the ClickHouse result sink). Test 90.
3. **Phase 3:** swap pins to the new release and re-run.

## Working rules

- David runs every `solomog` command and anything that changes a cluster. I hand back exact
  commands and read results from `.solomog/test-runs/`.
- Public repo: no customer names, no secrets. The license comes from `.env`
  (`KAGENT_LICENSE_KEY`).
- Commit only when David asks.

## Open questions

- Bundle and cluster names (`kagent-enterprise-full`, `kef`)?
- Real model as well as the mock (an OpenAI key from `.env`)?
- Keep or retire the old public `bundles/kagent-substrate` (kagent 1.0.0-alpha1 era,
  SandboxAgents)?
