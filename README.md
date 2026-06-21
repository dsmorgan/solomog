# solomog

Quickly stand up local [vcluster](https://www.vcluster.com/) (vind) Kubernetes
environments with Solo.io products and sample apps preinstalled — so you can skip
the setup and get to the work that matters: testing, validating configs, and
reproducing customer issues.

Supports **agentgateway**, **kgateway**, and **Istio** (ambient + sidecar), in
both **Solo enterprise** and **community/OSS** editions, on single or multi-cluster
topologies.

---

## Prerequisites

These must be present **before** running `task setup`:

| Dependency | Purpose | Install |
|---|---|---|
| **Docker Desktop** | Runs the vcluster containers; the flat-network routing reaches into its VM | https://docs.docker.com/desktop/ |
| **vind** (or `vcluster`) | Creates the local virtual clusters | https://www.vcluster.com/docs |
| **meshctl** | Gloo Mesh CLI (expected at `~/.gloo-mesh/bin/meshctl`, on `$PATH`) | https://docs.solo.io/gloo-mesh-enterprise/latest/setup/cli/ |
| **Homebrew** | Installs the remaining tools below | https://brew.sh |

`task setup` installs the rest via Homebrew:

| Tool | Purpose |
|---|---|
| `go-task` (`task`) | Task runner that backs the `solomog` CLI |
| `helmfile` | Declarative multi-release Helm orchestration |
| `helm` | Chart installs |
| `jq` | JSON parsing in scripts |
| `step` | PKI / shared-CA cert generation for multi-cluster Istio mTLS |

---

## Initialize

```bash
# 1. From the repo root, create your local secrets file
cp .env.example .env

# 2. Add your license key(s) to .env  (see "License keys" below)
#    For community-only use you can leave these blank.

# 3. Install prerequisites and link the `solomog` command onto your PATH
task setup
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

- **macOS + Docker Desktop.** The flat-network routing
  ([scripts/networking.sh](scripts/networking.sh)) injects `nftables` rules into
  the Docker Desktop Linux VM via `nsenter`. These rules are **ephemeral** — re-run
  the relevant scenario (or just `networking.sh`) after a Docker Desktop restart.
- **kube context naming.** Each cluster `NAME` is reachable at context
  `vcluster.NAME` (e.g. `vcluster.cluster-one`). Scripts and helmfiles assume this.
- **Cluster CIDRs are auto-assigned** per cluster index to avoid overlap:
  pod `10.<N>0.0.0/16`, service `10.1<N>.0.0/20`. See
  [scripts/vind-create.sh](scripts/vind-create.sh).
- **Shared root CA** is generated once into `certs/` (gitignored) and reused across
  runs. Delete `certs/` to rotate. Multi-cluster Istio mTLS depends on this.
- **Enterprise chart repos/versions** in
  [helmfiles/environments/enterprise.yaml](helmfiles/environments/enterprise.yaml)
  and [versions.env](versions.env) are starting points — verify them against the
  versions you actually run (search for `TODO`).
- **Short-lived clusters.** Designed for create → use for hours/days → tear down.
  Teardown always prompts before destroying anything.

---

## Concepts

- **Products** are composable helmfile modules in [helmfiles/products/](helmfiles/products/):
  `istio`, `gloo-mesh`, `kgateway`, `gloo-gateway`, `agentgateway`.
  - `istio` = enterprise installs **Solo managed Istio** via the **Gloo Operator** +
    a `ServiceMeshController` CR (`dataplaneMode` Ambient/Sidecar); community installs
    upstream Istio Helm charts.
  - `kgateway` = **enterprise kgateway** (kgateway 2.2.x) / upstream kgateway in community.
  - `gloo-gateway` = **Gloo Gateway** (gloo-ee 1.21.x) — a *separate* product, not the same as kgateway.
  - `agentgateway` = **enterprise agentgateway** (2.3.x).
  - `gloo-mesh` = optional **Gloo Mesh Enterprise** management plane (repo unverified — TODO).
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

# Community editions (no license key needed)
solomog kgateway EDITION=community
solomog gloo-gateway EDITION=community
```

### Multi-cluster Istio

```bash
solomog istio:ambient:multi-flat         # 2 clusters, shared (flat) network
solomog istio:ambient:multi-gateway      # 2 clusters, multi-network (east-west: TODO)
solomog istio:ambient:multi-3            # 3 clusters (supports mixed versions)
# sidecar:* variants exist for each
```

Multi-cluster meshes are orchestrated by [scripts/mesh.sh](scripts/mesh.sh), which
installs the `istio` product module onto each cluster with one shared root CA.
Per-cluster Istio version overrides (`ISTIO_VERSION_CLUSTER_TWO`, `_THREE`) in
`versions.env` enable mixed-version meshes.

### Sample apps

```bash
solomog apps:bookinfo CONTEXT=vcluster.cluster-one
solomog apps:online-boutique
solomog apps:utils                       # httpbin, curl, netshoot
```

### Versions & teardown

```bash
solomog versions:show
solomog versions:update                  # check GitHub, optionally bump versions.env
solomog teardown                         # prompts before destroying all clusters
solomog teardown:cluster CLUSTER=cluster-one
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
```

A product-specific key always wins; otherwise the product falls back to
`SOLO_LICENSE_KEY`. Resolution lives in
[helmfiles/environments/default.yaml](helmfiles/environments/default.yaml).
Community editions ignore license keys entirely.

---

## Repository layout

```
solomog
├── solomog                     # CLI wrapper → runs `task` from repo root
├── Taskfile.yaml               # all scenarios (the `solomog <scenario>` targets)
├── .env / .env.example         # license keys (.env is gitignored)
├── versions.env                # pinned product versions
├── scripts/
│   ├── setup.sh                # install prereqs + link solomog
│   ├── vind-create.sh          # create vclusters with unique CIDRs
│   ├── vind-teardown.sh        # destroy clusters (with confirmation)
│   ├── networking.sh           # flat-network nftables routing (Docker Desktop)
│   ├── gen-certs.sh            # shared root CA + per-cluster intermediates
│   ├── stack.sh                # compose products onto one cluster, in order
│   ├── mesh.sh                 # multi-cluster Istio (istio module per cluster, shared CA)
│   ├── versions-update.sh      # fetch latest versions from GitHub
│   └── apps/install-bookinfo.sh
├── clusters/                   # vcluster configs (single, multi, multi-3)
├── helmfiles/
│   ├── commons.yaml            # shared environment definitions (bases)
│   ├── environments/           # default + enterprise/community + ambient/sidecar
│   ├── products/               # one module per product (composable)
│   └── apps/                   # sample app helmfiles
├── values/                     # per-product Helm values
└── charts/
    ├── managed-istio/          # ServiceMeshController CR for the Gloo Operator
    └── utils/                  # httpbin/curl/netshoot
```

See [CLAUDE.md](CLAUDE.md) for architecture details and how to extend this repo.
