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

1. **Product** — `istio`, `gloo-mesh`, `kgateway`, `agentgateway`. One self-contained
   helmfile module each in [helmfiles/products/](helmfiles/products/).
2. **Edition** — `enterprise` (default) or `community`. A helmfile *environment*.
   Selects chart repos and whether license keys apply.
3. **Istio mode** — `ambient` (default) or `sidecar`. Passed as `ISTIO_MODE` env,
   selects which `values/istio/<mode>/values.yaml` overlay loads and whether
   CNI+ztunnel are installed.

### Composition flow (single cluster)

`solomog stack PRODUCTS="..." CLUSTER=..." ` → [scripts/stack.sh](scripts/stack.sh):
1. `vind-create.sh` — create the cluster (unique CIDRs).
2. `gen-certs.sh` — only if `istio` or `gloo-mesh` is requested.
3. For each product in **`CANONICAL_ORDER`** (`istio gloo-mesh kgateway
   agentgateway`), if requested, `helmfile sync -f products/<p>.yaml -e $EDITION
   --kube-context vcluster.$CLUSTER`.

Single-product tasks (`istio:*:single`, `kgateway`, `agentgateway`, etc.) are thin
shortcuts that call `stack.sh` with a fixed product list.

### Multi-cluster

Cross-cluster Istio scenarios ([helmfiles/istio-multi-flat.yaml](helmfiles/istio-multi-flat.yaml),
`-multi-gateway`, `-multi-3`) are **dedicated** helmfiles, not product modules —
they need per-context releases that share `meshID`/`network` and reference each
other (mgmt server ↔ agents). Don't try to force these into the product-module
shape. Their tasks use the internal `_vind-create` / `_networking` / `_gen-certs`
helpers.

## Conventions

- **kube context = `vcluster.<cluster-name>`** everywhere.
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

- **Taskfile is plain YAML, not gotmpl.** A flow sequence containing a template,
  e.g. `cmds: [bash x.sh {{.VAR}}]`, breaks the YAML parser because `{{` opens an
  inline mapping. Use block style:
  ```yaml
  cmds:
    - bash x.sh {{.VAR}}
  ```
- **nftables rules are ephemeral** — they vanish on Docker Desktop restart. Flat
  multi-cluster networking must be re-applied.
- **Certs must exist before istiod installs.** `stack.sh` and the multi-cluster
  tasks order `gen-certs` first; preserve that ordering.
- **`gloo-mesh` in community mode is a no-op** (Gloo Mesh Enterprise has no OSS
  build) — the module emits `releases: []`. Don't add community repos for it.
- Several enterprise chart names / OCI URLs are marked `TODO` — they were best-effort
  and need verification against real releases before enterprise installs succeed.

## Validating changes without a cluster

- YAML-lint the Taskfile (it's pure YAML):
  `ruby -ryaml -e "YAML.load_stream(File.read('Taskfile.yaml'))"`
- Product modules / scenario helmfiles are gotmpl — lint with
  `helmfile -f <file> -e <env> template` (needs helmfile + chart access), or
  `helmfile -f <file> lint`. A plain YAML parser will (correctly) reject the
  unrendered `{{ }}`.

## Status / open questions

- Confirm whether enterprise products use **distinct** license keys or one shared
  Gloo license (design supports both).
- Verify enterprise chart repos/names/versions against the user's actual versions.
- vcluster config (`clusters/*.yaml`) k3s `extraArgs` format should be checked
  against the installed vcluster version (the schema changed across 0.19+).
