# solomog

Quickly stand up local [vcluster](https://www.vcluster.com/) (vind) Kubernetes
environments with Solo.io products and sample apps preinstalled — so you can skip
the setup and get to the work that matters: testing, validating configs, and
reproducing customer issues.

Supports **agentgateway**, **kagent**, **kgateway**, **Gloo Gateway**, and **Istio**
(ambient + sidecar), in both **Solo enterprise** and **community/OSS** editions, on
single or multi-cluster topologies. Optional add-ons: Solo UI, Solo Portal, and
Prometheus/Grafana. Optional cluster backends besides local vind: EKS and a vSphere
homelab provisioner.

---

## Prerequisites

These must be present **before** running `bash scripts/setup.sh`:

| Dependency | Purpose | Install |
|---|---|---|
| **Docker Desktop** | Runs the vcluster containers; the flat-network routing reaches into its VM | https://docs.docker.com/desktop/ |
| **vcluster** (`vind`) | Creates the local virtual clusters | https://www.vcluster.com/docs |
| **kubectl** | Talks to those clusters; ships with Docker Desktop | https://kubernetes.io/docs/tasks/tools/ |
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
solomog                 # grouped index (one screen)
solomog help products   # tasks in a group
solomog help expose     # per-task variables, defaults, and examples
solomog help --all      # every task, grouped
#    `solomog help <task>` is the source of truth for knobs. The wrapper strips
#    go-task's resolved vars/env trailer so license keys never print.

# 5. Optional, once per machine: passwordless /etc/hosts edits (see below)
solomog setup:sudo
```

> `solomog` is a thin wrapper that runs `task` from the repo root regardless of
> your current directory, so the commands below work from anywhere. It rejects
> unknown tasks and unknown `KEY=` names before any task runs (`monitor` →
> `monitoring`). Bare `solomog` (and `solomog help`) print a grouped index. Drill
> down with `solomog help <group>` (`setup`, `cluster`, `products`, `istio`,
> `apps`, `bundles`, `creds`), `solomog help --all` for every task, or
> `solomog help <task>` for knobs and examples.

### Passwordless /etc/hosts (one-time)

`expose` / `route-host` pin a gateway LoadBalancer IP to a `.test` hostname in
`/etc/hosts` — solomog's **only** privileged operation. Left as-is, a long
unattended run (`solomog stack …`) can stall halfway waiting for a sudo password.

```bash
solomog setup:sudo              # install the rule (prompts once)
solomog setup:sudo CHECK=true   # verify only — no writes, no prompt
solomog setup:sudo REMOVE=true  # undo
```

It writes `/etc/sudoers.d/solomog` granting exactly one command with exactly one
argument — `<you> ALL=(root) NOPASSWD: /usr/bin/tee /etc/hosts` — and *generates*
that line from the same variable [scripts/lib/hosts.sh](scripts/lib/hosts.sh)
executes, so the sudoers spec can't drift from the command actually run (sudoers
matches the fully-qualified path **and** the arguments). The line dedup that
precedes the write is unprivileged, which is what keeps the grant this narrow.

Trade-off, plainly: afterwards anything running as your user can rewrite
`/etc/hosts` with no prompt — hostname redirection on this machine. It grants no
shell, no other file, no other command. Skip it if that's not a trade you want;
everything still works, sudo just prompts. Not needed at all for `DNS=real`
(vsphere/OPNsense) clusters — those write no `/etc/hosts` entries.

---

## Assumptions

- **macOS + Docker Desktop.** Inter-cluster routing
  ([scripts/networking.sh](scripts/networking.sh)) injects rules into the Docker
  Desktop Linux VM. Those rules are **ephemeral** — after a Docker Desktop restart,
  recover with `solomog net:repair CLUSTERS="…"` (clusters / Istio / certs survive).
- **vcluster docker driver.** Clusters are created with `vcluster create --driver
  docker` (vcluster-in-Docker) using default config, then `vcluster connect`ed.
- **`CLUSTER` is required on single-cluster tasks.** There is no default name.
  Pass `CLUSTER=<name>` (or `CONTEXT=` for an unregistered kube context).
  Multi-cluster Istio tasks default to `cluster-one cluster-two` (or `…-three`).
- **kube context naming.** Scripts resolve `CLUSTER` through
  [scripts/lib/target.sh](scripts/lib/target.sh): `CONTEXT` override → the
  `.solomog/contexts` registry (EKS / vSphere) → the vind default
  `vcluster-docker_<name>`. The Docker *network* is `vcluster.<name>`, which is
  different and only used by inter-cluster routing.
- **Shared root CA** is generated once into `certs/` (gitignored) and reused across
  runs. Delete `certs/` to rotate. Multi-cluster Istio mTLS depends on this.
- **Enterprise chart repos/versions** in
  [helmfiles/environments/enterprise.yaml](helmfiles/environments/enterprise.yaml)
  and [versions.env](versions.env) are starting points — verify them against the
  versions you actually run (search for `TODO`).
- **Short-lived clusters.** Designed for create → use for hours/days → tear down.
  Teardown names its targets explicitly (there is no destroy-all) and prompts before
  destroying anything unless you pass `FORCE=true`.
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
- **Standalone** is the one path with no cluster in it. Standalone agentgateway is a
  single self-contained binary — no control plane, no CRDs — so `solomog standalone` runs it
  as a Docker container against `standalone/<name>/config.yaml`, and none of products /
  editions / Istio mode apply. Instances are still tracked targets: they appear in
  `cluster:list` and are destroyed by `teardown` like anything else.
  See [standalone/README.md](standalone/README.md).

---

## Usage

### Single cluster — compose any products

```bash
# General-purpose: any combination on one cluster, installed in dependency order
solomog stack CLUSTER=cluster-one PRODUCTS="istio kgateway agentgateway"
solomog stack CLUSTER=cluster-one PRODUCTS="istio gloo-mesh" ISTIO_MODE=sidecar

# Shortcuts (CLUSTER is required — there is no default name)
solomog istio:ambient:single CLUSTER=cluster-one
solomog istio:sidecar:single CLUSTER=cluster-one
solomog gloo-mesh:single CLUSTER=cluster-one     # istio + Gloo Mesh mgmt plane
solomog kgateway CLUSTER=cluster-one             # enterprise kgateway 2.2.x
solomog kgateway:with-istio CLUSTER=cluster-one
solomog gloo-gateway CLUSTER=cluster-one         # Gloo Gateway 1.21.x (separate product)
solomog agentgateway CLUSTER=cluster-one
solomog kagent CLUSTER=cluster-one               # Enterprise evaluation topology (experimental)

# Community editions (no license key needed)
solomog kgateway EDITION=community CLUSTER=cluster-one
solomog gloo-gateway EDITION=community CLUSTER=cluster-one
solomog kagent EDITION=community CLUSTER=cluster-one
solomog kagent EDITION=community CLUSTER=cluster-one KAGENT_PROVIDER=ollama
```

Enterprise agentgateway accepts two CLI-only install flags (never put them in
`.env` — they would leak onto the next unrelated cluster):

- `TOKEN_EXCHANGE=true` — enable the OBO token-exchange STS and restart the `agw` proxy
- `OAUTH_ISSUER=true` — gateway acts as an OAuth authorization server at `/oauth-issuer`
  (needs `TOKEN_EXCHANGE=true` and `OKTA_*` in `.env`)

`solomog help agentgateway` lists the related JWKS / callback knobs. Enterprise
kgateway has `KGATEWAY_ELS_CRD` and `KGATEWAY_SKIP_SHARED_CRDS` for the same
reason (`solomog help kgateway`).

Kagent defaults to `KAGENT_PROVIDER=openAI` and reads `OPENAI_API_KEY`; use
`anthropic` with `CLAUDE_API_KEY`, or `ollama` with no API key. Both editions
install a bundled PostgreSQL suitable for short PoVs. The install summary prints
the UI port-forward: Enterprise is the shared Solo UI at
`http://localhost:4000/ke/` (`/age/` is agentgateway, `/ie/` is Istio — always
name the prefix; bare `/` redirects to whichever product is enabled first).
Community kagent ships its own UI at `http://localhost:8080/`.

Enterprise defaults to the chart's bundled auto-IdP (the documented quickstart
path — no IdP setup needed); set `KAGENT_OIDC_ISSUER` + `SOLO_UI_OIDC_*` to put
it behind a real IdP. `SOLO_UI_OIDC_*` alone does **not** switch kagent off the
auto-IdP. A cluster whose shared management release is already on an external
IdP stops with the two choices spelled out (`KAGENT_OIDC_ISSUER` to join that
IdP, or `KAGENT_AUTOAUTH=true` to reset the release to the bundled IdP), since
either silent default would break one of the two UIs.

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
solomog istio:ambient:multi-3            # 3 clusters, flat (supports mixed versions)
solomog istio:ambient:multi-3-gateway    # 3 clusters, east-west full mesh
# sidecar:* variants exist for each
```

Override the cluster names with `CLUSTERS="east west"` (or `CLUSTER="east west"` —
the two are interchangeable aliases). Multi-cluster meshes are orchestrated by
[scripts/mesh.sh](scripts/mesh.sh), which installs the `istio` product module onto
each cluster with one shared root CA. Per-cluster Istio version overrides
(`ISTIO_VERSION_CLUSTER_TWO`, `_THREE`) in `versions.env` enable mixed-version meshes.

After a Docker Desktop restart, host routing between clusters is gone — recover with
`solomog net:repair CLUSTERS="…"` (auto-detects flat vs gateway; no full mesh re-run).

Registered **vSphere** clusters can join a gateway-topology mesh
(`istio:ambient:multi-gateway CLUSTERS="s6 s7"`) — they must already exist; mixing
vind + external is refused; flat is refused (it needs Docker-bridge routing). East-west
gateways sit on MetalLB IPs, so there is no host routing to repair.

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

`expose` creates the Gateway and makes it reachable. On local-LB targets (vind,
vSphere without `DNS=real`) that means an mkcert TLS cert/secret plus an
`/etc/hosts` line (needs `sudo` — run
[`solomog setup:sudo`](#passwordless-etchosts-one-time) once and it stops prompting).
Apps attach their own HTTPRoute when invoked with `ROUTE=true` — all in one CLI call:

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

On a **vSphere** cluster, `DNS=real` switches off mkcert + `/etc/hosts` and instead
upserts a flat hostname on the homelab DNS (`SOLOMOG_DOMAIN`) with a Certwarden
Let's Encrypt cert. See `solomog help expose` and `.env.example`. EKS uses the
cloud LoadBalancer hostname (no `/etc/hosts`).

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
solomog apps:online-boutique CLUSTER=cluster-one
solomog apps:utils CLUSTER=cluster-one           # httpbin, curl, netshoot
solomog apps:utils CLUSTER=a1 ROUTE=true         # also route httpbin through the gateway (any gateway)
                                                 #   at /httpbin — the universal routing smoke test
solomog apps:mock-openai CLUSTER=a1              # OpenAI-compatible mock LLM + agentgateway backend
                                                 #   (needs enterprise agentgateway; add ROUTE=true)
solomog apps:mcp-stripe CLUSTER=a1               # stripe-mock exposed as MCP tools via OpenAPI
                                                 #   (needs enterprise agentgateway; add ROUTE=true)
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
# Needs eksctl + AWS creds (`solomog aws:refresh`, or export them in the shell).
solomog eks:create CLUSTER=dmorgan-agw
solomog eks:delete CLUSTER=dmorgan-agw
# Keyless SigV4 from the agentgateway proxy to AgentCore (replaces ≤12h env creds):
solomog eks:irsa CLUSTER=dmorgan-agw
```

`cluster:list` marks the current kubectl context with `*`. A `~` means kubectl is
on that same cluster through a different context name (eksctl and
`aws eks update-kubeconfig` each write their own). Status for EKS is live when
AWS creds work, otherwise `—`.

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
solomog bundles:list FILTER=acme                       # names containing a substring
solomog bundles:show BUNDLE=acme                       # files in apply order
solomog apply BUNDLE=acme CLUSTER=aaa                   # apply, in order
solomog apply BUNDLES="llmroute-vertex llmroute-bbr" CLUSTER=aaa   # several, left-to-right
solomog apply BUNDLE=acme CLUSTER=aaa DRY_RUN=true      # validate only (server-side)
solomog test BUNDLE=acme CLUSTER=aaa                    # run bundles/<name>/tests/*.sh
solomog test BUNDLE=acme CLUSTER=aaa TESTS="54 56"      # only tests whose name starts with these
solomog export BUNDLE=acme                              # portable, secret-safe hand-off (no cluster)

# recreate a whole customer env in one chained call:
solomog agentgateway:ui expose apply BUNDLE=acme ROUTE=true CLUSTER=aaa
```

`BUNDLE` and `BUNDLES` are aliases; either may name several bundles, applied (or
tested) left-to-right. `export` packages one bundle's declarative manifests for
someone who is not using solomog — hooks are copied into `manual-steps/`, not run.

A bundle is `bundles/<name>/` (committed) or `bundles/private/<name>/` (gitignored, for
anything sensitive). Files apply in `LC_ALL=C` sorted order, so prefix them with a
zero-padded number (`01-`, `10-`, `20-`) to sequence. Files ending `.yaml.tmpl` are
rendered with `%%CLUSTER%%` / `%%GATEWAY%%` / `%%HOST%%` (and, when set,
`%%BEDROCK_GUARDRAIL_ID%%` / `%%BEDROCK_GUARDRAIL_VERSION%%`) before apply; plain
`.yaml` is applied verbatim. A `.sh` file is *run* at its place in the order —
the escape hatch for imperative steps like creating a Secret from a key in `.env`
(`--from-literal="…=$CLAUDE_API_KEY"`), so the value never lands in a committed file.
`kubectl apply` is idempotent (safe to re-run) and nothing is pruned.

Only the bundle **root** is applied, so a bundle can carry standard subdirectories without
them ever being deployed: `tests/` (run by `solomog test`), `docs/` (detail the README links
to), `custref/` (customer-supplied config being recreated), and `helpers/` (scripts you run by
hand — log in, mint a token, mutate the system under test). All optional. See
[bundles/README.md](bundles/README.md) for the full convention, including the required
per-bundle `README.md` that `bundles:list` and `bundles:show` print.

### Standalone agentgateway (no cluster)

Standalone agentgateway is one self-contained binary — no control plane, no xDS, no CRDs, and
the proxy needs no Kubernetes API access. So this path runs it as a Docker container against a
local config file, and never creates or touches a cluster.

```bash
solomog standalone:list                        # instances: name, state, config, UI URL
solomog standalone NAME=minimal                # start it; prints the gateway and UI URLs
solomog standalone:logs INSTANCE=minimal
solomog standalone:stop INSTANCE=minimal       # container goes; config and state stay
solomog standalone:delete INSTANCE=minimal     # the instance stops existing
```

`NAME` picks the config; `INSTANCE` names the running thing and defaults to `NAME`. Set it to
run the same config twice — the second gets its own config copy under `.solomog/standalone/`,
so the two never fight over one file, and its UI edits stay out of the repo:

```bash
solomog standalone NAME=minimal INSTANCE=scratch    # lands on the next free ports
```

Instances are registered, so they are ordinary solomog targets rather than a separate world:

```bash
solomog cluster:list                     # standalone rows beside vind / eks / vsphere
solomog teardown CLUSTER=scratch         # one delete for any target, whatever its type
```

Configs live in [standalone/](standalone/), one directory per instance, each holding a
`config.yaml` in agentgateway's `LocalConfig` schema. Three ship with the repo: `minimal`
(gateway + UI), `llm` (two providers behind one OpenAI-compatible endpoint), and `mcp` (MCP
federation).

The UI is the gateway's **own**, compiled into the binary — a different thing from the Solo
Enterprise UI management chart that `agentgateway:ui` installs onto a cluster.

Check a config without starting anything, or a cluster, or even a license:

```bash
solomog standalone:validate NAME=llm
```

That is worth doing first. Secrets are `$VAR` references expanded from the environment at load
time, and an unset one aborts the whole config load with an error that does not name it —
`validate` names it. `standalone` runs the same check as a pre-flight.

Host ports are probed and incremented until one is free, so several instances coexist and a
busy 4000 never wedges the task:

```bash
solomog standalone NAME=minimal               # 127.0.0.1:4000, UI on 15000
solomog standalone NAME=mcp                   # 4000 taken → 4001, UI on 15001
solomog standalone NAME=llm PORT_TRIES=50     # widen the search
solomog standalone NAME=minimal BIND=0.0.0.0  # publish beyond loopback (opt-in)
```

`BIND` is loopback by default on purpose — Docker's own default would put the UI on your LAN.

Migrating from LiteLLM? The gateway's importer translates a `config.yaml` and reports what it
could and could not carry over:

```bash
solomog standalone:import NAME=from-litellm FILE=~/litellm/config.yaml
solomog standalone:validate NAME=from-litellm
```

Version pin is `AGENTGATEWAY_STANDALONE_VERSION` in [versions.env](versions.env), deliberately
separate from `AGENTGATEWAY_VERSION`: standalone landed in 2026.8.0 with no equivalent on the
older SemVer line, so pinning agentgateway back to mirror a customer environment must not drag
standalone to a release where it does not exist.

See [standalone/README.md](standalone/README.md) for the authoring convention and the full
list of things that will bite you.

### Short-lived credentials

Bundle backends that talk to GCP or AWS consume tokens from `.env`. Refresh writes
**only** `.env` (in-place, after a backup under `.solomog/env-backups/`); re-run
`apply` to push the secret into the cluster. Chain them — the wrapper re-reads
`.env` between tasks:

```bash
solomog gcp:refresh apply BUNDLE=llmroute-vertex CLUSTER=aaa     # ~1h GCP token
solomog aws:refresh apply BUNDLE=llmroute-bedrock CLUSTER=aaa    # ≤12h SSO creds
```

`AWS_PROFILE` / `AWS_SSO_SESSION` live in `.env`. The `agentcore` CLI is the
opposite posture on purpose: it runs in *your* shell (never reads `.env`), so it
wants the auto-refreshing SSO **profile**, not those static keys:

```bash
solomog agentcore:list                   # discover projects; verify against AWS
solomog agentcore:prune                  # drop local state for runtimes AWS no longer has
eval "$(solomog agentcore:env NAME=<project>)"   # stdout is shell-only — must be eval'd
solomog agentcore:shell NAME=<project>   # same creds, already cd'd into the project
```

Projects are discovered (any directory holding `agentcore/agentcore.json`) — no
bundle or runtime name is hardcoded.

### Versions & teardown

```bash
solomog versions:show
solomog versions:update                  # check GitHub (read-only — does not write versions.env)
solomog teardown CLUSTER=aaa             # type-agnostic; prompts; vind / vsphere / EKS
solomog teardown CLUSTERS="aaa hl1 e1"   # mixed types in one run
solomog vind:delete CLUSTER=aaa          # vind-only (also: vsphere:delete, eks:delete)
```

`CLUSTER` / `CLUSTERS` is required — there is no destroy-all. `teardown` (alias `delete`)
detects each name's type and dispatches; the `*:delete` tasks refuse the wrong type.

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
KAGENT_LICENSE_KEY=...            # overrides for Enterprise kagent
PORTAL_LICENSE_KEY=...            # overrides for Solo Portal (own entitlement)
```

A product-specific key always wins; otherwise the product falls back to
`SOLO_LICENSE_KEY`. Resolution lives in
[helmfiles/environments/default.yaml.gotmpl](helmfiles/environments/default.yaml.gotmpl).
Community editions ignore license keys entirely.

Enterprise kagent purchases provide separate kagent, Istio, and agentgateway
entitlements. The shared management release prefers `KAGENT_LICENSE_KEY` when
present, matching Solo's documented upgrade-in-place path; the individual Istio
and agentgateway charts continue to use their own keys.

Two exceptions to the fallback rule:

- **`solomog standalone` requires `AGENTGATEWAY_LICENSE_KEY` and does not fall back.** The
  standalone binary's license verifier needs a `product` claim, which the generic
  `SOLO_LICENSE_KEY` does not carry — so the fallback would turn a missing key into a
  confusing `malformed claims` crash instead of a clear message. Standalone also has no grace
  period: unlicensed, it exits rather than starting degraded.
- **Never leave trailing whitespace in a key's value.** A value of `"   "` is not empty as far
  as dotenv and helmfile's `| default` are concerned, so it silently defeats the whole
  fallback chain, and padding breaks anything that passes the value verbatim (`docker run -e`
  most of all). `solomog env:diff` reports any key whose value carries leading or trailing
  whitespace, by name only.

---

## Repository layout

```
solomog
├── solomog                     # CLI wrapper → runs `task` from repo root
├── Taskfile.yaml               # all scenarios (the `solomog <scenario>` targets)
├── CLAUDE.md / AGENTS.md       # architecture + conventions; Cursor Cloud agent notes
├── .env / .env.example         # secrets + template (.env gitignored; env:sync aligns them)
├── versions.env                # pinned product versions
├── scripts/
│   ├── setup.sh / setup-sudo.sh  # install prereqs + link solomog; passwordless /etc/hosts
│   ├── run.sh / list.sh        # per-step framing; the grouped `solomog` help index
│   ├── lib/help.sh             # index / group / --all pages (catalog in help-catalog.txt)
│   ├── vind-create.sh / vind-teardown.sh / teardown.sh
│   ├── networking.sh / mesh-eastwest.sh / net-repair.sh
│   ├── gen-certs.sh            # shared root CA + per-cluster intermediates
│   ├── stack.sh                # compose products onto one cluster, in order
│   ├── prepare-kagent.sh       # validate provider + create Enterprise JWT/OIDC secrets
│   ├── mesh.sh                 # multi-cluster Istio (istio module per cluster, shared CA)
│   ├── expose.sh / route-host.sh
│   ├── routes.sh / graph.sh    # inspect agentgateway config
│   ├── clusters.sh             # cluster:list / cluster:show
│   ├── env-backup.sh / env-sync.sh / env-diff.sh
│   ├── gcp-refresh.sh / aws-refresh.sh / agentcore-env.sh
│   ├── install-agentgateway-ui.sh / install-portal.sh / install-monitoring.sh
│   ├── apply-bundle.sh / test-bundle.sh / export-bundle.sh / bundles.sh
│   ├── standalone.sh            # run/stop/list/logs/validate/import — Docker, no cluster
│   ├── eks-create.sh / eks-delete.sh / eks-irsa.sh
│   ├── vsphere-*.sh            # homelab lifecycle: init/create/delete/stop/start/snapshot/reset
│   ├── vsphere-snapshot.py     # pyvmomi (vCenter 7.0.x has no REST snapshot API)
│   ├── test-envfile.sh / test-vsphere-lib.sh   # hermetic unit tests (no cluster, no vCenter)
│   ├── versions-update.sh
│   ├── lib/target.sh           # CLUSTER → kube context (vind / registry / CONTEXT)
│   ├── lib/hosts.sh            # the one privileged /etc/hosts write
│   ├── lib/gateway.sh / lib/envfile.sh / lib/ui.sh
│   ├── lib/vsphere.sh / lib/opnsense.sh   # IP+VIP allocators; DNS=real record upserts
│   ├── lib/graph/              # vendored cytoscape.min.js for the self-contained graph
│   └── apps/
├── certs/                      # generated shared root CA (gitignored; delete to rotate)
├── docs/specs/                 # design specs (vsphere-provisioner.md)
├── taskfiles/vsphere.yaml      # OPTIONAL include: all vsphere:* tasks (homelab provisioner)
├── terraform/                  # OpenTofu roots: vsphere-init (template) + vsphere-k3s (workspace/cluster)
├── bundles/                    # custom-config bundles (bundles/private/ is gitignored)
│                               #   see bundles/README.md for the authoring convention
├── standalone/                 # LocalConfig files for `solomog standalone` (no cluster)
│                               #   see standalone/README.md; data.db* gitignored
├── dashboards/                 # vendored Grafana dashboards (agentgateway-overview.json)
├── .solomog/                   # gitignored runtime state: contexts registry, clusters,
│                               #   exports/, test-runs/, env-backups/, audit/, vsphere/
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
