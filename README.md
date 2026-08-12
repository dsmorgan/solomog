# solomog

Quickly stand up local [vcluster](https://www.vcluster.com/) (vind) Kubernetes
environments with Solo.io products and sample apps preinstalled — so you can skip
the setup and get to the work that matters: testing, validating configs, and
reproducing customer issues.

Supports **agentgateway**, **kagent**, **kgateway**, and **Istio** (ambient + sidecar), in
both **Solo enterprise** and **community/OSS** editions, on single or multi-cluster
topologies.

---

## Prerequisites

These must be present **before** running `bash scripts/setup.sh`:

| Dependency | Purpose | Install |
|---|---|---|
| **Docker Desktop** | Runs the vcluster containers; the flat-network routing reaches into its VM | https://docs.docker.com/desktop/ |
| **vind** (or `vcluster`) | Creates the local virtual clusters | https://www.vcluster.com/docs |
| **meshctl** | Gloo Mesh CLI (expected at `~/.gloo-mesh/bin/meshctl`, on `$PATH`) | https://docs.solo.io/gloo-mesh-enterprise/latest/setup/cli/ |
| **Homebrew** | Installs the remaining tools below | https://brew.sh |

`bash scripts/setup.sh` installs the rest via Homebrew:

| Tool | Purpose |
|---|---|
| `go-task` (`task`) | Task runner that backs the `solomog` CLI |
| `helmfile` | Declarative multi-release Helm orchestration |
| `helm` | Chart installs |
| `jq` | JSON parsing in scripts |
| `step` | PKI / shared-CA cert generation for multi-cluster Istio mTLS |
| `mkcert` | Local CA for gateway TLS (`expose`) |
| `uv` | Isolated Python deps for some bundle tests |

---

## Initialize

```bash
# 1. From the repo root, create your local secrets file
cp .env.example .env
#    Later: `solomog env:sync` rebuilds .env from .env.example (keeps your values +
#    section comments); `solomog env:diff` shows key drift; `solomog env:backup`
#    snapshots to .solomog/env-backups/ (also auto-runs before aws/gcp refresh).

# 2. Add your license key(s) to .env  (see "License keys" below)
#    For community-only use you can leave these blank.

# 3. Install prerequisites and link the `solomog` command onto your PATH.
#    Run the script directly — `task` isn't installed yet, and this installs it.
bash scripts/setup.sh
#    This installs the brew tools and symlinks ./solomog -> ~/.local/bin/solomog
#    If ~/.local/bin isn't on your PATH, add to ~/.zshrc:
#      export PATH="$HOME/.local/bin:$PATH"

# 4. Verify
solomog            # lists every available scenario
```

> `solomog` is a thin wrapper that runs `task` from the repo root regardless of
> your current directory, so the commands below work from anywhere.

---

## Assumptions

- **macOS + Docker Desktop.** Inter-cluster routing
  ([scripts/networking.sh](scripts/networking.sh)) injects rules into the Docker
  Desktop Linux VM. Those rules are **ephemeral** — after a Docker Desktop restart,
  recover with `solomog net:repair CLUSTERS="…"` (clusters / Istio / certs survive).
- **vcluster docker driver.** Clusters are created with `vcluster create --driver
  docker` (vcluster-in-Docker) using default config, then `vcluster connect`ed.
- **kube context naming.** The docker driver registers contexts as
  `vcluster-docker_NAME` (e.g. `vcluster-docker_cluster-one`) — note the Docker
  *network* is `vcluster.NAME`, which is different. Scripts/helmfiles use the
  `vcluster-docker_` context form.
- **Shared root CA** is generated once into `certs/` (gitignored) and reused across
  runs. Delete `certs/` to rotate. Multi-cluster Istio mTLS depends on this.
- **Enterprise chart repos/versions** in
  [helmfiles/environments/enterprise.yaml](helmfiles/environments/enterprise.yaml)
  and [versions.env](versions.env) are starting points — verify them against the
  versions you actually run (search for `TODO`).
- **Short-lived clusters.** Designed for create → use for hours/days → tear down.
  Teardown always prompts before destroying anything.
- **Enterprise kagent is resource-heavy and experimental.** Solo recommends at
  least 2 vCPU / 8 GB per cluster; the bundled management plane includes
  ClickHouse and PostgreSQL. Its secured Istio/agentgateway topology has a
  narrower compatibility matrix than solomog's general product defaults.

---

## Concepts

- **Products** are composable helmfile modules in [helmfiles/products/](helmfiles/products/):
  `istio`, `gloo-mesh`, `kgateway`, `gloo-gateway`, `agentgateway`, `kagent`.
  - `istio` = enterprise installs **Solo managed Istio** via the **Gloo Operator** +
    a `ServiceMeshController` CR (`dataplaneMode` Ambient/Sidecar); community installs
    upstream Istio Helm charts.
  - `kgateway` = **enterprise kgateway** (kgateway 2.2.x) / upstream kgateway in community.
  - `gloo-gateway` = **Gloo Gateway** (gloo-ee 1.21.x) — a *separate* product, not the same as kgateway.
  - `agentgateway` = **enterprise agentgateway** (CalVer default; override for SemVer customer pins) / OSS agentgateway in community.
  - `kagent` = stable **OSS kagent** in community; the **Solo Enterprise build**
    plus the shared management/UI plane in enterprise (experimental in solomog).
  - `gloo-mesh` = optional **Gloo Mesh Enterprise** management plane (repo unverified — TODO).

  Enterprise and community use different registries and version lines; the right
  ones are selected automatically by `EDITION`. All chart coordinates are verified
  against the product docs except `gloo-mesh`.
- **Editions** are a helmfile environment dimension: `EDITION=enterprise` (default)
  or `EDITION=community`. Switches chart repos and license handling.
- **Istio mode** is `ISTIO_MODE=ambient` (default) or `sidecar`.
- **Scenarios** are `task` targets that wire products + topology + networking + certs
  together.

---

## Usage

### Single cluster — compose any products

```bash
# General-purpose: any combination on one cluster, installed in dependency order
solomog stack CLUSTER=cluster-one PRODUCTS="istio kgateway agentgateway"
solomog stack PRODUCTS="istio gloo-mesh" ISTIO_MODE=sidecar

# Shortcuts
solomog istio:ambient:single
solomog istio:sidecar:single
solomog gloo-mesh:single                 # istio + Gloo Mesh mgmt plane
solomog kgateway                         # enterprise kgateway 2.2.x
solomog kgateway:with-istio
solomog gloo-gateway                     # Gloo Gateway 1.21.x (separate product)
solomog agentgateway
solomog kagent                           # Enterprise evaluation topology (experimental)

# Community editions (no license key needed)
solomog kgateway EDITION=community
solomog gloo-gateway EDITION=community
solomog kagent EDITION=community         # Stable OSS kagent
solomog kagent EDITION=community KAGENT_PROVIDER=ollama
```

Kagent defaults to `KAGENT_PROVIDER=openAI` and reads `OPENAI_API_KEY`; use
`anthropic` with `CLAUDE_API_KEY`, or `ollama` with no API key. Both editions
install a bundled PostgreSQL suitable for short PoVs. The install summary prints
the relevant UI port-forward command. Enterprise inherits `SOLO_UI_OIDC_*` when
configured; use the CLI-only `KAGENT_AUTOAUTH=true` for a disposable standalone
cluster that should use the bundled IdP instead.

Enterprise kagent 0.5.x documents Kubernetes 1.32–1.36, Gateway API 1.5.0,
agentgateway 2026.7.0, and Istio 1.26–1.29. Standalone evaluation is allowed.
Composition with agentgateway warns when pins differ, and composition with Istio
is rejected until `ISTIO_VERSION` is explicitly set to a supported release:

```bash
solomog stack PRODUCTS="agentgateway kagent" CLUSTER=a1
solomog stack PRODUCTS="istio agentgateway kagent" CLUSTER=a1 ISTIO_VERSION=1.29.6
```

### Multi-cluster Istio

```bash
solomog istio:ambient:multi-flat         # 2 clusters, shared (flat) network
solomog istio:ambient:multi-gateway      # 2 clusters, multi-network (east-west wired)
solomog istio:ambient:multi-3            # 3 clusters (supports mixed versions)
# sidecar:* variants exist for each
```

Override the cluster names with `CLUSTERS="east west"` (or `CLUSTER="east west"` —
the two are interchangeable aliases). Multi-cluster meshes are orchestrated by
[scripts/mesh.sh](scripts/mesh.sh), which installs the `istio` product module onto
each cluster with one shared root CA. Per-cluster Istio version overrides
(`ISTIO_VERSION_CLUSTER_TWO`, `_THREE`) in `versions.env` enable mixed-version meshes.

After a Docker Desktop restart, host routing between clusters is gone — recover with
`solomog net:repair CLUSTERS="…"` (auto-detects flat vs gateway; no full mesh re-run).

> **`CLUSTER` / `CLUSTERS` are aliases.** Single-cluster tasks take the first name
> from whichever you set; multi-cluster tasks take the whole list. So a singular/plural
> slip (`CLUSTERS=foo` on a single task, `CLUSTER="a b"` on a mesh) just works.
> The wrapper **warns** (does not fail) when a multi-name list is passed to
> single-cluster tasks like `expose` / `apps:*` / `apply` — those do **not** fan out.
>
> Multi-cluster mesh tasks (`istio:*:multi-*`) orchestrate all clusters in one
> phased run (shared CA, routing, east-west). That is not the same as repeating
> `expose` / `apps` / `apply` on each mesh member. For that, use a shell loop:
>
> ```bash
> for c in east west; do solomog agentgateway expose apps:utils ROUTE=true CLUSTER=$c; done
> ```

### Expose a gateway (Gateway + TLS + DNS) and route apps

`expose` creates the Gateway, an mkcert TLS cert/secret, and wires the vcluster
LoadBalancer IP into `/etc/hosts` (the `/etc/hosts` edit needs `sudo`). Apps attach
their own HTTPRoute when invoked with `ROUTE=true` — all in one CLI call:

```bash
# Gateway + TLS + DNS, then route two apps onto it (distinct default paths)
solomog expose apps:mock-openai apps:mcp-stripe ROUTE=true CLUSTER=a1
#   expose      → Gateway agw (http:8080 + https:443/TLS), host agw.a1.test
#   mock-openai → HTTPRoute at /openai
#   mcp-stripe  → HTTPRoute at /mcp

# expose the kgateway gateway instead (→ gw 'kgw', host kgw.a1.test)
solomog expose CLUSTER=a1 PRODUCT=kgateway

# route a single app on a custom path
solomog apps:mock-openai CLUSTER=a1 ROUTE=true ROUTE_PATH=/llm
```

Without `ROUTE=true`, apps deploy their backend only (no route). `PRODUCT` seeds the
gateway name/namespace defaults — `agentgateway` → `agw`/`agentgateway-system`,
`kgateway` → `kgw`/`kgateway-system` — and `CLASS` is resolved from the GatewayClass
actually on the cluster (`enterprise-*` or the community short name). `NAME`/`NAMESPACE`/`CLASS`/`HOST`/`SECRET`
are still individually overridable. **`PRODUCT` is auto-detected** from the cluster's
GatewayClasses when not set, so `solomog expose CLUSTER=cluster-one` on a kgateway
cluster picks `kgw` automatically (falls back to agentgateway if both/neither are present).

The hostname defaults to **`<NAME>.<CLUSTER>.test`** (e.g. `agw.a1.test`, `kgw.a1.test`) —
`.test` is the RFC 6761 name reserved for testing (`.local` is avoided: it collides with
mDNS/Bonjour and resolves slowly), and including the cluster keeps hostnames unique when
multiple clusters are up.

### Shared Solo UI, Portal & monitoring add-ons

The Solo UI is one singleton `management` Helm release. `agentgateway:ui` enables
agentgateway on it; Enterprise `kagent` enables kagent on that same release and
preserves any existing product values. Never install a second management release:
its bundled cluster-scoped CRDs would have conflicting Helm owners. Portal and
monitoring remain separate add-ons. When kagent is present, `agentgateway:ui`
also preserves the shared release's OIDC mode so it cannot change kagent's issuer
out from under the controller. Routed UIs use sub-hosts nested under
`expose`'s wildcard cert:

```bash
# agentgateway + its Solo UI in one shot (enterprise only), then route the UI
solomog agentgateway:ui expose ROUTE=true CLUSTER=a1
#   → UI at  https://ui.agw.a1.test/age/   (Solo UI serves under /age/)

# Solo Portal (developer portal) — needs enterprise kgateway already on the cluster.
# Own license (PORTAL_LICENSE_KEY). Separate task so it can later attach beyond SEFK.
solomog kgateway portal CLUSTER=a1
#   → controller + starter Portal in portal-system
solomog expose apply BUNDLE=portal-httpbin PRODUCT=kgateway CLUSTER=a1
#   → frontend + httpbin ApiProduct at https://portal.kgw.a1.test/

# Prometheus + Grafana — product-agnostic; auto-installs the agentgateway
# PodMonitor + dashboard when agentgateway is detected on the cluster
solomog monitoring expose ROUTE=true CLUSTER=a1
#   → Grafana at  https://grafana.agw.a1.test/   (admin / prom-operator)
```

- **`agentgateway:ui`** installs agentgateway and enables its UI integration on
  `agentgateway-system/management`. Enterprise kagent reuses the same release and
  enables `products.kagent`; order does not matter. Management CRDs are bundled
  (no separate `management-crds` release). **Enterprise only.**
- **`portal`** installs Solo Portal (`portal-crds` + `portal` controller) into
  `portal-system`, then a starter `PortalParameters` + `Portal`. **Enterprise only;**
  preflights for GatewayClass `enterprise-kgateway`. License: `PORTAL_LICENSE_KEY`
  (falls back to `SOLO_LICENSE_KEY`). Version pin: `PORTAL_VERSION` in `versions.env`.
  Not folded into `kgateway` — Portal may attach to other Solo products later.
- **`monitoring`** is cross-cutting (not under a product) because one Prometheus/Grafana
  serves every product. It auto-detects installed products and loads their dashboards —
  override with `DASHBOARDS="agentgateway"` or `DASHBOARDS=none`. Grafana password defaults
  to `prom-operator`; override via `GRAFANA_ADMIN_PASSWORD` in `.env` if needed.
- **Routing vs port-forward.** UI/Grafana default to a port-forward (printed after install).
  Adding `ROUTE=true` (with `expose`) routes them host-based at `/` — the UIs each get
  their own host because the Solo UI (`/age/`) and Grafana both assume they own their
  base path, so a path-prefix rewrite would break their assets. Order doesn't matter:
  `expose` backfills the `/etc/hosts` entry for any sub-host route already on the gateway.

### Sample apps

```bash
solomog apps:bookinfo CLUSTER=cluster-one
solomog apps:online-boutique
solomog apps:utils                       # httpbin, curl, netshoot
solomog apps:utils CLUSTER=a1 ROUTE=true # also route httpbin through the gateway (any gateway)
                                         #   at /httpbin — the universal routing smoke test
solomog apps:mock-openai                 # OpenAI-compatible mock LLM + agentgateway route
                                         #   (needs enterprise agentgateway installed)
solomog apps:mcp-stripe                  # stripe-mock exposed as MCP tools via OpenAPI
                                         #   (needs enterprise agentgateway; add ROUTE=true to route)
```

Both AI/MCP apps need a gateway to be reachable — run `solomog expose` (above) first
or in the same CLI call.

### Inspect agentgateway config

Two complementary, read-only views of what's on a cluster's agentgateway(s):

```bash
# Terminal: Gateway → listeners → HTTPRoutes (host/path → backend, policies, ACTIVE?)
solomog routes CLUSTER=a1
solomog routes CLUSTER=a1 WIDE=true          # also matchers/filters + failure reasons

# Browser: interactive HTML graph (Gateway → routes → backends → policies + control plane)
solomog graph CLUSTER=a1
solomog graph CLUSTER=a1 OPEN=false          # write HTML only
solomog graph CLUSTER=a1 DUMP=false          # skip proxy /config_dump (faster; no live version)
```

- **`routes`** is built from kubectl CR `.status` only — so it also shows routes that
  *aren't* active (`Accepted` / `ResolvedRefs` / `Programmed` = False). The proxy's
  `/config_dump` omits those.
- **`graph`** snapshots the same CR relationship model into a self-contained HTML file
  (Cytoscape). By default it also port-forwards each gateway pod's admin port (`:15000`)
  on an ephemeral local port and fetches `/config_dump` — that surfaces the live proxy
  **version** in the subtitle, marks which routes/backends/policies the proxy actually
  loaded, and embeds the dump (Dump button → summary + download). Soft-fails if the
  admin port is unreachable (falls back to the dataplane image tag for version).
  `DUMP=false` skips the fetch entirely.

Both accept a registered external cluster the same way as other tasks
(`CLUSTER=e2a2` after `eks:create`, or `CONTEXT=…`).

### Clusters & external targets (EKS & vSphere homelab)

```bash
solomog cluster:list                         # vind + registered EKS/vsphere/external, with live status
solomog cluster:show CLUSTER=a1

# Stand up / tear down an EKS cluster and register it for solomog CLUSTER=…
solomog eks:create CLUSTER=dmorgan-agw
solomog eks:delete CLUSTER=dmorgan-agw
```

Once registered (or with `CONTEXT=`), install/expose/graph/routes use that cluster like
a local vind one — solomog does not create or network it.

**vSphere homelab (optional):** builds real k3s clusters (1 server + N agent VMs,
Ubuntu + cloud-init, MetalLB for LoadBalancer IPs) on a vCenter 7.0.x and registers
them the same way — `expose` then works exactly like vind (mkcert + `/etc/hosts`).
Entirely opt-in: fill the `VSPHERE_*` section in `.env` and `brew install opentofu`
(deliberately not a setup.sh prerequisite); without them every `vsphere:*` task fails
fast with guidance and nothing else is affected. Design/spec:
[docs/specs/vsphere-provisioner.md](docs/specs/vsphere-provisioner.md).

```bash
solomog vsphere:init                          # one-time: content library + Ubuntu template + VM folder
solomog vsphere:create CLUSTER=s1             # ~5 min; NODES=2 agents by default; SNAPSHOT=true → baseline
solomog agentgateway expose apps:utils ROUTE=true CLUSTER=s1   # …then use it like any cluster
solomog vsphere:stop CLUSTER=s1               # pause: graceful VM shutdown, state kept, host RAM freed
solomog vsphere:start CLUSTER=s1              # resume exactly where you left off
solomog vsphere:snapshot CLUSTER=s1           # (re)take the baseline snapshot on demand
solomog vsphere:reset CLUSTER=s1              # revert to baseline — clean cluster in ~VM-boot time
solomog vsphere:delete CLUSTER=s1             # tofu destroy; also deletes the cluster's
                                              #   DNS=real records from OPNsense (best-effort)
```

### Custom config bundles (customer repros)

When you need to apply bespoke config that isn't worth generalizing into a product or
app — e.g. recreating a specific customer's routes/policies — drop manifests in a
**bundle** directory and apply them in order:

```bash
solomog bundles:list                                   # what's available
solomog bundles:show BUNDLE=acme                       # files in apply order
solomog apply BUNDLE=acme CLUSTER=aaa                   # apply, in order
solomog apply BUNDLE=acme CLUSTER=aaa DRY_RUN=true      # validate only (server-side)

# recreate a whole customer env in one chained call:
solomog agentgateway:ui expose apply BUNDLE=acme ROUTE=true CLUSTER=aaa
```

A bundle is `bundles/<name>/` (committed) or `bundles/private/<name>/` (gitignored, for
anything sensitive). Files apply in `LC_ALL=C` sorted order, so prefix them with a
zero-padded number (`01-`, `10-`, `20-`) to sequence. Files ending `.yaml.tmpl` are
rendered with `%%CLUSTER%%` / `%%GATEWAY%% `/ `%%HOST%%` placeholders before apply
(plain `.yaml` is applied verbatim). A `.sh` file is *run* at its place in the order —
the escape hatch for imperative steps like creating a Secret from a key in `.env`
(`--from-literal="…=$CLAUDE_API_KEY"`), so the value never lands in a committed file.
`kubectl apply` is idempotent (safe to re-run) and nothing is pruned. See
[bundles/README.md](bundles/README.md) for the full convention.

### Versions & teardown

```bash
solomog versions:show
solomog versions:update                  # check GitHub (read-only — does not write versions.env)
solomog teardown                         # prompts, then destroys all solomog-created clusters
solomog teardown CLUSTER=cluster-one     # destroy just one cluster
```

---

## License keys

Set keys in `.env`. Use one key for everything, or map a specific key per product:

```bash
SOLO_LICENSE_KEY=...              # fallback for any product without its own key
SOLO_ISTIO_LICENSE_KEY=...        # overrides for Solo managed Istio (Gloo Operator)
GLOO_MESH_LICENSE_KEY=...         # overrides for Gloo Mesh mgmt plane
KGATEWAY_LICENSE_KEY=...          # overrides for enterprise kgateway
GLOO_GATEWAY_LICENSE_KEY=...      # overrides for Gloo Gateway
AGENTGATEWAY_LICENSE_KEY=...      # overrides for agentgateway
KAGENT_LICENSE_KEY=...           # overrides for Enterprise kagent
```

A product-specific key always wins; otherwise the product falls back to
`SOLO_LICENSE_KEY`. Resolution lives in
[helmfiles/environments/default.yaml.gotmpl](helmfiles/environments/default.yaml.gotmpl).
Community editions ignore license keys entirely.

Enterprise kagent purchases provide separate kagent, Istio, and agentgateway
entitlements. The shared management release prefers `KAGENT_LICENSE_KEY` when
present, matching Solo's documented upgrade-in-place path; the individual Istio
and agentgateway charts continue to use their own keys.

---

## Repository layout

```
solomog
├── solomog                     # CLI wrapper → runs `task` from repo root
├── Taskfile.yaml               # all scenarios (the `solomog <scenario>` targets)
├── .env / .env.example         # secrets + template (.env gitignored; env:sync aligns them)
├── versions.env                # pinned product versions
├── scripts/
│   ├── setup.sh                # install prereqs + link solomog
│   ├── vind-create.sh          # create vclusters (docker driver, default config) + connect
│   ├── vind-teardown.sh        # destroy solomog-created clusters (with confirmation)
│   ├── networking.sh           # inter-cluster Docker routing (flat / gateway)
│   ├── gen-certs.sh            # shared root CA + per-cluster intermediates
│   ├── stack.sh                # compose products onto one cluster, in order
│   ├── prepare-kagent.sh       # validate provider + create Enterprise JWT/OIDC secrets
│   ├── mesh.sh                 # multi-cluster Istio (istio module per cluster, shared CA)
│   ├── net-repair.sh           # re-apply inter-cluster Docker routing after a Docker restart
│   ├── expose.sh               # Gateway + TLS + DNS (backfills sub-host /etc/hosts)
│   ├── route-host.sh           # route a Service on its own sub-host under expose's wildcard
│   ├── routes.sh               # terminal view of agentgateway routing (CR status)
│   ├── graph.sh                # interactive HTML graph (+ optional /config_dump enrichment)
│   ├── clusters.sh             # cluster:list / cluster:show
│   ├── env-backup.sh / env-sync.sh / env-diff.sh  # .env hygiene (lib/envfile.sh)
│   ├── install-agentgateway-ui.sh  # enable agentgateway on shared management + tracing + route
│   ├── install-portal.sh       # Solo Portal (portal-crds + controller) + starter Portal
│   ├── install-monitoring.sh   # Prometheus/Grafana + product dashboards + route
│   ├── apply-bundle.sh         # apply a custom-config bundle to a cluster, in order
│   ├── bundles.sh              # list / show available bundles
│   ├── versions-update.sh      # check pinned versions against GitHub (read-only)
│   ├── lib/target.sh           # CLUSTER → kube context (vind / registry / CONTEXT)
│   ├── lib/envfile.sh          # .env backup / in-place set / sync-from-example
│   └── apps/install-bookinfo.sh
├── clusters/                   # vcluster configs (single, multi, multi-3)
├── taskfiles/vsphere.yaml      # OPTIONAL include: all vsphere:* tasks (homelab provisioner)
├── terraform/                  # OpenTofu roots: vsphere-init (template) + vsphere-k3s (workspace/cluster)
├── bundles/                    # custom-config bundles (bundles/private/ is gitignored)
├── dashboards/                 # vendored Grafana dashboards (agentgateway-overview.json)
├── helmfiles/
│   ├── commons.yaml            # shared environment definitions (bases)
│   ├── environments/           # default + enterprise/community + ambient/sidecar
│   ├── products/               # one module per product (*.yaml.gotmpl, composable)
│   ├── addons/                 # UI (management) + Portal + monitoring stack
│   └── apps/                   # sample app helmfiles
├── values/                     # per-product Helm values
└── charts/
    ├── managed-istio/          # ServiceMeshController CR for the Gloo Operator
    └── utils/                  # httpbin/curl/netshoot
```

See [CLAUDE.md](CLAUDE.md) for architecture details and how to extend this repo.
