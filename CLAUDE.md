# CLAUDE.md

Guidance for working in this repo. Read this before making changes.

## What this is

`solomog` automates standing up local **vcluster (vind)** Kubernetes environments
with Solo.io products preinstalled, for a Customer Solutions Architect's testing /
validation / customer-issue-reproduction work. It is **not** production tooling —
favor clarity, modularity, and easy extension over robustness.

User context: David Morgan, CSA at Solo.io. Runs vind on Docker Desktop (macOS).
Primary products: agentgateway, kgateway, Istio (ambient + sidecar).

## Architecture

Two tools, composed:

- **Taskfile** ([Taskfile.yaml](Taskfile.yaml)) is the CLI surface. Every
  `solomog <x>` is a `task` target. It handles orchestration, env wiring, cluster
  lifecycle, and calls scripts.
- **Helmfile** does the Helm work — release sequencing, per-environment value
  overlays, templated repos/versions/licenses.

The `solomog` wrapper just `cd`s to the repo root and `exec task "$@"`.

### Three orthogonal dimensions

These combine freely and are the core mental model:

1. **Product** — `istio`, `gloo-mesh`, `kgateway`, `gloo-gateway`, `agentgateway`.
   One self-contained helmfile module each in [helmfiles/products/](helmfiles/products/).
   - `istio` = **enterprise**: Solo managed Istio via the **Gloo Operator**
     (`gloo-operator` OCI chart, ns `gloo-mesh`, license `manager.env.SOLO_ISTIO_LICENSE_KEY`)
     plus a `ServiceMeshController` CR (rendered by `charts/managed-istio`; `dataplaneMode`
     Ambient/Sidecar from `ISTIO_MODE`, `version` = Istio version). **community**: upstream
     Istio Helm charts (base/istiod/+cni/ztunnel). Both apply Gateway API CRDs via a presync hook.
   - `kgateway` = **enterprise kgateway** (kgateway 2.2.x, OCI charts `enterprise-kgateway[-crds]`,
     ns `kgateway-system`, license `licensing.licenseKey`) / upstream kgateway in community.
   - `gloo-gateway` = **Gloo Gateway** (gloo-ee/gloo 1.21.x, classic Helm repos, ns `gloo-system`,
     license top-level `license_key`). A *different product* from kgateway — do not merge them.
   - `agentgateway` = **enterprise agentgateway** (2.3.x, OCI charts `enterprise-agentgateway[-crds]`,
     ns `agentgateway-system`, license `licensing.licenseKey`).
   - `gloo-mesh` = optional Gloo Mesh Enterprise mgmt plane. Repo unverified (TODO); not used
     by any default scenario. Distinct from the Gloo Operator above.
2. **Edition** — `enterprise` (default) or `community`. A helmfile *environment*.
   Selects chart repos and whether license keys apply.
3. **Istio mode** — `ambient` (default) or `sidecar`. Passed as `ISTIO_MODE` env,
   selects which `values/istio/<mode>/values.yaml` overlay loads and whether
   CNI+ztunnel are installed.

### Composition flow (single cluster)

`solomog stack PRODUCTS="..." CLUSTER=..." ` → [scripts/stack.sh](scripts/stack.sh):
1. `vind-create.sh` — create the cluster (docker driver, default config) + connect.
2. `gen-certs.sh` — only if `istio` or `gloo-mesh` is requested.
3. For each product in **`CANONICAL_ORDER`** (`istio gloo-mesh kgateway
   gloo-gateway agentgateway`), if requested, `helmfile sync -f products/<p>.yaml
   -e $EDITION --kube-context vcluster-docker_$CLUSTER`. `stack.sh` also exports
   `SOLO_CONTEXT` so helmfile hooks (e.g. gloo-gateway's Gateway API CRD bootstrap)
   target the right cluster.

Single-product tasks (`istio:*:single`, `kgateway`, `agentgateway`, etc.) are thin
shortcuts that call `stack.sh` with a fixed product list.

### Multi-cluster

Cross-cluster Istio is orchestrated by [scripts/mesh.sh](scripts/mesh.sh), which
**reuses the `istio` product module** — it creates the clusters, generates one
shared root CA across all of them (`gen-certs.sh`), wires flat pod routing
(`networking.sh`) when applicable, then runs the istio module against each cluster
context with per-cluster `SOLO_CLUSTER` / `SOLO_NETWORK` / `ISTIO_VERSION`.
- `flat` topology → all clusters share network `solomog` (relies on networking.sh).
- `gateway` topology → per-cluster network; **east-west gateway + endpoint discovery
  wiring is not yet automated** (TODO — see the multi-network steps in the docs).
- Per-cluster Istio version overrides (`ISTIO_VERSION_CLUSTER_TWO`, `_THREE`) give
  mixed-version meshes; mesh.sh maps `cluster-two` → `ISTIO_VERSION_CLUSTER_TWO`.

## Conventions

- **kube context = `vcluster-docker_<cluster-name>`** everywhere (the docker
  driver's naming). The Docker *network* is `vcluster.<name>` — different; only
  networking.sh uses the network name.
- **`CLUSTER` and `CLUSTERS` are interchangeable aliases** across all tasks. Single
  tasks resolve `{{.CLUSTER | default .CLUSTERS | default "<def>" | splitList " " | first}}`
  (first name); multi tasks resolve `{{.CLUSTERS | default .CLUSTER | default "<defs>"}}`
  (whole list). New cluster-scoped tasks should follow the same pattern so the
  singular/plural slip stays harmless.
- **License resolution** is centralized in
  [helmfiles/environments/default.yaml](helmfiles/environments/default.yaml):
  `<product>_license_key` = product-specific env var `| default SOLO_LICENSE_KEY`.
  Never re-implement this per module — just reference the resolved value.
- **Shared environments** live in [helmfiles/commons.yaml](helmfiles/commons.yaml);
  product modules pull them in via `bases: [../commons.yaml]`. Define new
  environment overlays there, not per-module.
- **Versions** are pinned in [versions.env](versions.env), surfaced into helmfiles
  as `.Values.<product>_version`. Per-cluster Istio overrides
  (`ISTIO_VERSION_CLUSTER_TWO/THREE`) enable mixed-version testing.
- Helmfile env values files are **gotmpl-rendered before YAML parsing** — nested
  quotes like `"{{ env "X" }}"` are fine there (but NOT in plain YAML).

## How to extend

### Add a new product
1. Create `helmfiles/products/<name>.yaml` with `bases: [../commons.yaml]`, a
   `repositories:` block (gate enterprise/community with
   `{{ if eq .Environment.Name "enterprise" }}`), and `releases:`.
2. Add license resolution to `default.yaml` if it needs a key; reference
   `.Values.<name>_license_key`.
3. Add the chart repo URLs to `enterprise.yaml` / `community.yaml`.
4. Add `<name>` to `CANONICAL_ORDER` in [scripts/stack.sh](scripts/stack.sh) in the
   correct dependency position.
5. Optionally add a shortcut task in [Taskfile.yaml](Taskfile.yaml).
6. Add a `values/<name>/values.yaml` for tunables.

### Add a new scenario
Add a task in `Taskfile.yaml`. For single-cluster combos, delegate to `stack.sh`.
For new cross-cluster topologies, write a dedicated helmfile.

## Gotchas (learned the hard way)

- **Scripts must stay bash 3.2 compatible.** macOS ships bash 3.2.57, and Taskfile
  runs scripts via `bash scripts/...` which resolves to it. Avoid bash 4+ features:
  no `mapfile`/`readarray` (use `while IFS= read -r`), no `${var,,}`/`${var^^}`
  (use `[[ "$x" =~ ^[Yy] ]]` or `tr`), and guard empty arrays before `"${a[@]}"`
  under `set -u`.
- **Teardown only destroys solomog-created clusters.** `vind-create.sh` records each
  cluster it creates in `.solomog/clusters` (gitignored); `vind-teardown.sh` with no
  args only targets those that still exist, so hand-made clusters are never nuked.
  Explicit `CLUSTER=<name>` overrides this.
- **Taskfile is plain YAML, not gotmpl.** A flow sequence containing a template,
  e.g. `cmds: [bash x.sh {{.VAR}}]`, breaks the YAML parser because `{{` opens an
  inline mapping. Use block style:
  ```yaml
  cmds:
    - bash x.sh {{.VAR}}
  ```
- **Helmfiles and env-values files that use templating MUST end in `.gotmpl`.**
  Helmfile v1 does not template plain `.yaml` (it parses them as literal YAML, so
  `{{ env "X" }}` both fails to render and breaks parsing via nested quotes). All
  `helmfiles/products/*.yaml.gotmpl` and the templated env files
  (`default.yaml.gotmpl`, `community.yaml.gotmpl`) carry the extension; static files
  (`enterprise.yaml`, `commons.yaml`, `apps/*.yaml`) stay `.yaml`. Scripts reference
  modules by their full `.yaml.gotmpl` name.
- **`bases:` env-values paths resolve relative to the *consuming* helmfile**, not the
  base file. That's why `commons.yaml` uses `../environments/...` (the modules live
  in `helmfiles/products/`).
- **OCI repo URLs must be scheme-less when `oci: true`** — helmfile prepends `oci://`
  itself, so an `oci://` in the URL produces `oci://oci://...`. Classic HTTP Helm
  repos (Gloo Gateway) keep their `https://`.
- **vcluster docker driver: defaults only, and `connect` registers the context.**
  vcluster 0.35 removed the `controlPlane.distro.k3s` config (k8s is the embedded
  default) — passing it fails with `unknown field "k3s"` and the create retries for
  ~3 min before dying. So vind-create.sh passes **no config file**. Also
  `vcluster create --connect=false` does NOT add a kube context; you must run
  `vcluster connect <name>` afterward (it writes `vcluster-docker_<name>` and
  switches the active context). Custom pod/service CIDRs aren't available on this
  driver (they need `privateNodes.enabled`).
- **Images must be multi-arch (arm64).** The clusters run on Apple Silicon, so
  amd64-only images crash with `exec format error` in a crash loop. The original
  `kennethreitz/httpbin` is amd64-only — replaced with `mccutchen/go-httpbin` (Go,
  multi-arch, listens on 8080 → Service maps 80→8080). Vet any new image for an
  arm64 variant (`docker manifest inspect <img> | grep arm64`).
- **nftables rules are ephemeral** — they vanish on Docker Desktop restart. Flat
  multi-cluster networking must be re-applied.
- **Certs must exist before Istio installs.** `stack.sh` and `mesh.sh` order
  `gen-certs` first; preserve that ordering. One shared root CA is reused across all
  clusters in a mesh — delete `certs/` to rotate.
- **`gloo-mesh` in community mode is a no-op** (Gloo Mesh Enterprise has no OSS
  build) — the module emits `releases: []`. Don't add community repos for it.
- Chart coordinates **verified** against docs for both editions:
  - `istio` — enterprise: gloo-operator 0.5.2 / istio 1.30.x; community: upstream
    charts (istio-release), ambient profile, ~1.26.x.
  - `kgateway` — enterprise 2.2.x (`us-docker.pkg.dev/.../enterprise-kgateway`);
    community 2.3.x (`cr.kgateway.dev/kgateway-dev/charts`).
  - `agentgateway` — enterprise 2.3.x (`.../enterprise-agentgateway`); community
    1.3.x (`cr.agentgateway.dev/charts`). Both editions ship a `-crds` chart.
  - `gloo-gateway` — 1.21.x (classic Helm repos).
  Only the `gloo-mesh` mgmt-plane repo remains an unverified `TODO`.
- Enterprise and community are on **different version lines** for kgateway and
  agentgateway. `community.yaml` overrides `kgateway_version`/`agentgateway_version`
  from `*_COMMUNITY_VERSION` env vars — don't assume one version fits both editions.
- All Gateway-API-based products (istio, kgateway, agentgateway) install the
  **upstream Gateway API CRDs** via a `presync` hook (`kubectl apply --server-side`,
  version from `gateway_api_version`). This is separate from each product's own
  `-crds` chart.
- `kgateway` (enterprise kgateway) vs `gloo-gateway` (Gloo Gateway) are **distinct
  products** with different charts, namespaces, and license value paths. An earlier
  draft conflated them — keep them separate.
- The **Gloo Operator** (part of the `istio` product) vs **Gloo Mesh Enterprise**
  (`gloo-mesh` mgmt-plane product) are also distinct — both happen to use the
  `gloo-mesh` namespace. Don't conflate them.
- Enterprise Istio is operator-managed, so there are **no istio base/istiod/cni/
  ztunnel Helm releases** in that path — the `ServiceMeshController` CR drives it.
  Only the community path installs those charts directly.

## Validating changes without a cluster

- YAML-lint the Taskfile (it's pure YAML):
  `ruby -ryaml -e "YAML.load_stream(File.read('Taskfile.yaml'))"`
- **Fast module check (no cluster, no chart pull)** — validates templating, env
  resolution, and repo/chart construction:
  ```bash
  set -a; source versions.env; set +a
  export SOLO_CONTEXT=vcluster-docker_cluster-one SOLO_CLUSTER=cluster-one ISTIO_MODE=ambient
  helmfile -e community -f helmfiles/products/<mod>.yaml.gotmpl build
  ```
  (`build` resolves everything but does not pull; `template` additionally pulls and
  renders the charts — use it to confirm chart names/versions actually exist.)
- A plain YAML parser will (correctly) reject the unrendered `{{ }}` in `.gotmpl`
  files — use `helmfile build`, not a YAML linter, for those.

## Status / open questions

- **Multi-network (`gateway`) east-west wiring** is not automated — `mesh.sh` sets
  per-cluster networks but does not create east-west gateways or endpoint discovery.
  Finish from https://docs.solo.io/istio/1.30.x/quickstart/multi/.
- **`gloo-mesh` mgmt-plane repo** is the last unverified chart coordinate.
- Confirm whether enterprise products use **distinct** license keys or one shared
  Gloo license (design supports both; per-product env vars fall back to SOLO_LICENSE_KEY).
- vcluster config (`clusters/*.yaml`) k3s `extraArgs` format should be checked
  against the installed vcluster version (the schema changed across 0.19+).
- Community/upstream chart versions differ from enterprise version lines
  (kgateway, istio) — `versions.env` is pinned to enterprise values by default.
