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
- `flat` topology → all clusters share network `solomog`; `networking.sh flat` routes the
  whole peer subnets between the Docker bridges (pods talk pod-IP → pod-IP directly).
- `gateway` topology → per-cluster network; `mesh-eastwest.sh` exposes an `istio-eastwest`
  gateway per cluster + links every pair (declarative kubectl, replicating `istioctl
  multicluster expose|link` — no Solo istioctl dependency), and `networking.sh gateway`
  routes **only to each peer's east-west gateway `/32`** (discovered live; tighter than flat,
  faithful to real multi-network). Comes up peered end-to-end.
- **Host routing is ephemeral** (lives in the Docker Desktop VM) — a Docker restart wipes it and
  silently disconnects the mesh, though the clusters/Istio/gateways/certs survive. Recover with
  `solomog net:repair CLUSTERS="…"` (auto-detects flat vs gateway from the live clusters; no
  stored state) — not a full task re-run.
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

### Gateway exposure & app routing
- **`expose`** ([scripts/expose.sh](scripts/expose.sh)) is the product-agnostic gateway
  layer: it creates the `Gateway` (http:8080 + https:443/TLS), an mkcert TLS secret, and
  writes the vcluster LoadBalancer IP into `/etc/hosts` (sudo). vcluster auto-provisions
  the LB as an haproxy container (`vcluster.lb.<cluster>.<gw>.<ns>`) and the Gateway's
  `status.addresses[0].value` is the reachable IP. `PRODUCT` seeds the defaults:
  `agentgateway` → gw `agw` / ns `agentgateway-system` / class `enterprise-agentgateway`;
  `kgateway` → gw `kgw` / ns `kgateway-system` / class `enterprise-kgateway`.
  When `PRODUCT` is unset, expose.sh **auto-detects** it from the cluster's GatewayClasses
  (`enterprise-kgateway` → kgateway, `enterprise-agentgateway` → agentgateway; both/neither
  → agentgateway). The Taskfile must therefore pass `PRODUCT` empty (not a default) so the
  script can detect. NAME/NAMESPACE/CLASS/HOST individually overridable. App `GATEWAY`
  default is `agw` (the agentgateway apps route there) — keep it in sync with the gw name.
  Hostname defaults to `<NAME>.<CLUSTER>.test` — always use **`.test`** (RFC 6761), never
  `.local` (mDNS/Bonjour collision → slow resolution); the cluster component keeps the host
  unique across clusters.
- **App routing is an opt-in `ROUTE` flag**, not a separate task: each app always creates
  its backend, and adds its `HTTPRoute` only when `ROUTE=true`, on a per-app default
  `ROUTE_PATH` (`/openai`, `/mcp`, `/httpbin`). This keeps "gateway + apps + routes" a single
  CLI call via task chaining (`solomog expose apps:a apps:b ROUTE=true`) with no path
  collisions, since each app owns its default path. **Never name the path var `PATH`** — it
  clobbers the shell `$PATH`; use `ROUTE_PATH`.
- **`mock-openai`/`mcp-stripe` are agentgateway-only** (route to an `EnterpriseAgentgatewayBackend`,
  so `GATEWAY` defaults to `agw`). **Workloads live in their own namespace** (`mock-openai`,
  `stripe-mock` — overridable via `APP_NS`), NOT in `agentgateway-system`. The gateway-*config*
  objects (the `EnterpriseAgentgatewayBackend`, schema/secret ConfigMaps, and HTTPRoute) stay in
  `agentgateway-system` with the gateway, so the route→backend ref is same-namespace (no
  ReferenceGrant); the backend reaches the workload by FQDN (`<svc>.<APP_NS>.svc.cluster.local`)
  cross-namespace. Keep new AI/MCP apps on this split. **`apps:utils` routes httpbin as a plain Service backend**,
  so it works on *any* gateway — it auto-detects the gateway name/ns (agw/kgw) like expose,
  and uses a `URLRewrite` filter (ReplacePrefixMatch `/`) so `/httpbin/get` → httpbin's `/get`.
  httpbin is the gateway-agnostic routing smoke test (the only routable sample for kgateway).

### Add-ons (UI & monitoring)
Add-ons are a fourth thing alongside products/apps: cross-cutting helmfile modules in
[helmfiles/addons/](helmfiles/addons/), installed by their own scripts (not `stack.sh`'s
product loop). Two exist:
- **`<product>:ui`** — the Solo UI. It's the **same compound pattern as `kgateway:with-istio`**:
  the task installs the product (`stack.sh`) *then* the UI ([scripts/install-agentgateway-ui.sh](scripts/install-agentgateway-ui.sh)).
  The UI is **one `management` chart** (`helm_repo_solo_enterprise`, ns `agentgateway-system`)
  with per-product toggles — `agentgateway:ui` enables only `products.agentgateway`. A future
  `gloo-mesh:ui` flips `products.mesh` on the *same* chart. **CRDs are bundled** in the chart
  (its `management-crds` subchart, enabled by default) — do NOT add a separate `management-crds`
  release; the workshop's split + `enabled=false` is a long-lived-cluster CRD-lifecycle pattern
  that buys nothing for ephemeral vclusters. **Enterprise only** (no community UI; the script
  rejects `EDITION=community`). The tracing CR (`EnterpriseAgentgatewayPolicy`) is applied by the
  script after sync, targeting the gateway by name (default `agw`) so it attaches once `expose` runs.
- **`monitoring`** — Prometheus + Grafana (kube-prometheus-stack, OSS, **edition-agnostic**),
  ns `monitoring`. Cross-cutting (not under a product) because one stack serves all products.
  [scripts/install-monitoring.sh](scripts/install-monitoring.sh) **auto-detects products** from
  GatewayClasses (like `expose`) and layers on their PodMonitor + Grafana dashboard; override with
  `DASHBOARDS="agentgateway"` / `none`. Dashboards are vendored in [dashboards/](dashboards/) and
  loaded as labeled ConfigMaps the Grafana sidecar picks up. New product dashboards: drop the JSON
  in `dashboards/`, add an `install_<product>_dashboards` branch.

### Host-based routing for UIs (vs path-based for apps)
Apps route **by path** on the shared gateway host (`/openai`, `/httpbin`) — covered by expose's
`*.HOST` wildcard line, no per-app `/etc/hosts` entry. UIs route **by sub-host** at `/`
([scripts/route-host.sh](scripts/route-host.sh)): `ui.agw.<cluster>.test`, `grafana.agw.<cluster>.test`.
Reason: the Solo UI (served under `/age/`) and Grafana both assume they own their base path, so a
prefix-stripping rewrite breaks their assets — give each its own host instead.
- The sub-host is **nested under expose's wildcard cert** (`*.agw.<cluster>.test`), so TLS is free —
  no new cert. The expose Gateway sets no listener `hostname` and allows routes from all namespaces,
  so it accepts any sub-host.
- **`/etc/hosts` has no wildcard support**, so each sub-host needs its own explicit line. Ordering is
  handled both ways: `route-host.sh` adds the line immediately if the gateway already exists, and
  `expose.sh` **backfills** entries for any sub-host HTTPRoute already attached to its gateway (jq over
  `httproute -A`, matching hostnames ending in `.$HOST`). So `agentgateway:ui expose ROUTE=true` works
  regardless of which runs first.
- The HTTPRoute lives in the **Service's** namespace (same-namespace backendRef → no ReferenceGrant),
  while its `parentRef` points at the gateway in `agentgateway-system`.

### Custom config bundles (the escape hatch)
For bespoke / customer-repro config not worth generalizing into a product or app, use a
**bundle**: a directory of manifests under `bundles/<name>/` applied in order by
[scripts/apply-bundle.sh](scripts/apply-bundle.sh) via `solomog apply BUNDLE=<name> CLUSTER=…`.
- **Hybrid git layout**: `bundles/<name>/` is committed; `bundles/private/<name>/` is
  gitignored (sensitive config) and **overrides** a committed bundle of the same name.
- **Ordering**: `LC_ALL=C` byte sort. Zero-pad numeric prefixes (`01-`, `10-`, `20-`) —
  byte sort puts `2` after `10`, so padding (not `sort -V`, which BSD/macOS sort lacks)
  is what guarantees sequence. Leave gaps to insert later.
- **Templating**: files ending `.yaml.tmpl` are rendered with a `sed` allow-list of
  `%%TOKEN%%` placeholders (`%%CLUSTER%%`, `%%GATEWAY%%`, `%%HOST%%`); plain `.yaml` is
  applied verbatim. The `%%TOKEN%%` syntax (NOT `$VAR`/envsubst) is deliberate — it can't
  clash with `$` in manifests and needs no gettext dep. Add new vars to `render()` in
  apply-bundle.sh. A leftover `%%FOO%%` after rendering is a hard error — and the check
  scans the whole file *including comments*, so never write a literal `%%WORD%%` in a
  `.tmpl` unless it's a real token (this bit the example bundle once).
- **Executable hooks**: a `.sh` file is *run* (not applied) at its sorted position —
  the escape hatch for imperative steps, mainly **secrets from `.env`** (e.g.
  `kubectl create secret … --from-literal="…=$CLAUDE_API_KEY" | kubectl apply -f -`). The
  value stays in `.env` (gitignored, auto-sourced), so the hook carries no secret and is
  committable. Hooks inherit the env + `CONTEXT`/`CLUSTER`/`GATEWAY`/`HOST` (cwd = bundle
  dir) and are **skipped under DRY_RUN** (can't assume a script is side-effect free).
  This is why secrets are NOT done as declarative manifests — a Secret with a real value
  can't be committed, and a bundle file would put it in plaintext on disk; the env-sourced
  hook keeps the value only in `.env`.
- **No prune, idempotent**: `kubectl apply` only; removing a file never deletes a resource.
  `DRY_RUN=true` → `--dry-run=server` (real validation; needs a live cluster, and a CR that
  depends on an earlier file's namespace/CRD will fail under dry-run since nothing's written).
- **`BUNDLE` and `BUNDLES` are interchangeable** (like `CLUSTER`/`CLUSTERS`), and either
  may name **several** bundles space-separated — `solomog apply BUNDLES="llmroute-vertex
  llmroute-bbr" CLUSTER=…` applies them left-to-right (stop on first error), same for
  `test`. The Taskfile folds both vars into the `BUNDLE` env (`{{.BUNDLES | default
  .BUNDLE}}`); apply-bundle.sh / test-bundle.sh loop over the list (one run-dir per bundle
  for tests, with a combined tally). `bundles:show` stays single-bundle (discovery).
- `bundles:list` / `bundles:show` (via [scripts/bundles.sh](scripts/bundles.sh)) are
  cluster-free discovery; `apply` is framed through `run.sh` like other leaf tasks.
- **Testing**: a bundle's `tests/` subdir holds `*.sh` tests run by `solomog test BUNDLE=…`
  ([scripts/test-bundle.sh](scripts/test-bundle.sh)) in sorted order. **A test is just the
  command(s)** — no required format/scaffolding; the runner runs the file and judges pass/fail
  by exit code. It exports `CONTEXT/CLUSTER/GATEWAY/HOST` + inherits `.env`, so tests substitute
  with plain shell vars (`$HOST` etc.) — portable/copy-pasteable, no `%%TOKEN%%`. Assertion idiom
  is `curl --fail-with-body` (HTTP ≥400 → non-zero exit). Keep curl tests as one-liners; kubectl
  checks may need a little shell logic. Don't reintroduce response-parsing scaffolding in examples.
  Runs are captured to `.solomog/test-runs/<bundle>-<ts>/` (gitignored). `apply` ignores the
  `tests/` subdir (globs files only), so apply and test stay separate.
  - **Python-based tests**: the runner only globs/execs `*.sh`, so a Python test is a `.sh`
    that shells out. Don't `pip install` (system Python is PEP 668 externally-managed) — run
    via **`uv run --with <dep> --python 3.x`** (ephemeral, cached, isolated deps; `uv` is a
    setup.sh prerequisite). **Gotcha:** uv-managed Python uses certifi, NOT the macOS keychain,
    so HTTPS to the mkcert gateway fails with `CERTIFICATE_VERIFY_FAILED`. Add `--with truststore`
    and `import truststore; truststore.inject_into_ssl()` so TLS uses the OS trust store (where
    `mkcert -install`, run by `expose`, put the CA). See `bundles/mcp-in-cluster/tests/`.
- **Short-lived creds**: `solomog gcp:refresh` ([scripts/gcp-refresh.sh](scripts/gcp-refresh.sh))
  re-fetches a GCP token (`gcloud auth print-access-token`) into `.env` as `GCP_ACCESS_TOKEN`
  (general GCP token, not Vertex-specific) — ONLY updates `.env`; re-run the bundle to push it
  into the cluster secret. `solomog gcp:refresh apply BUNDLE=… CLUSTER=…` works *because the
  wrapper runs each task as its own `task` invocation* and go-task re-reads dotenv per
  invocation, so `apply` sees the freshly written token. (A raw `task gcp:refresh apply` in one
  process reads `.env` once — would miss it.) Token is short-lived (~1h); re-run manually when
  a backend 401s.
  `solomog aws:refresh` ([scripts/aws-refresh.sh](scripts/aws-refresh.sh)) is the **same
  pattern for AWS Bedrock**: SSO issues temporary creds (access key + secret + session token,
  ≤12h), so it runs `aws configure export-credentials` (and `aws sso login` first if the
  session is stale) and writes the three `AWS_*` vars into `.env`. `AWS_PROFILE` (set in
  `.env`) picks the SSO profile; `AWS_SSO_SESSION` (default `SOlo`) names the session for the
  login fallback. Bundle `bundles/llmroute-bedrock/` consumes them via a `policies.auth.aws.secretRef`
  secret (keys `accessKey`/`secretKey`/`sessionToken`). Creds are short-lived (≤12h) — re-run
  manually when a route 401/403s. Same dotenv-reread chaining: `solomog aws:refresh apply BUNDLE=llmroute-bedrock CLUSTER=…`.

### Add a new scenario
Add a task in `Taskfile.yaml`. For single-cluster combos, delegate to `stack.sh`.
For new cross-cluster topologies, write a dedicated helmfile.

**Task variables MUST be wired through the task's `env:` block.** A go-task CLI var
(`solomog x FOO=bar`) is NOT exported to the command's environment unless the task lists
`FOO: '{{.FOO | default ""}}'` in `env:` — so a script that reads `${FOO:-default}` without
that wiring silently ignores the override (this is exactly how `HTTP_PORT`/`GATEWAY_NS` were
dead despite being documented). When a script documents an `Env:` knob, the calling task must
wire it. Use `default ""` and let the script supply the real default, so there's one source
of truth for the default value.

**A task's `env:` default CANNOT override a value already sitting in `.env`.** go-task
resolves the template var `.FOO` from dotenv *before* the task's own `default "..."`
expression ever runs — so if `.env` sets `FOO=true`, then `FOO: '{{.FOO | default "false"}}'`
still yields `true` when no CLI arg is passed (verified empirically). There is no template
trick to make a task "CLI-only" while the same var is also dotenv-sourced. For a setting
that must never silently persist across clusters/sessions (e.g. `TOKEN_EXCHANGE` — enabling
it globally would crash-loop the controller on any *other* cluster lacking Keycloak), the
**only** fix is to not define it in `.env`/`.env.example` at all, and give the task's `env:`
entry a hardcoded default (`default "false"`, no `env "..."` fallback). Settings that are
inert without that master flag (`TOKEN_EXCHANGE_JWKS_URL`, `_API_VALIDATOR`) can still safely
use the `default (env "...")` fallback pattern and persist in `.env`.

**Per-task help (`solomog help <task>`)** surfaces each task's variables/defaults/examples
via go-task's `summary:` field (the wrapper runs `task --summary`). Keep the `summary:` in
sync with the script's `Env:` header when you add/change a knob. ⚠️ **Never expose
`task --summary` output raw** — go-task appends the task's *resolved* `vars:`/`env:` blocks,
which include `.env` SECRET VALUES (license keys, tokens). The `solomog` wrapper strips that
trailer with an awk filter (drops everything from a `^vars:`/`^env:` line until the next
`^task:`); summaries therefore must not begin a line with a bare `vars:`/`env:` (use
`Variables:`). If you change the help path, preserve that filter.

**Framing + timing live at two levels.** The `solomog` wrapper owns the run: it splits
the command line into task names vs `KEY=VALUE` globals, runs each task as its own `task`
invocation (this is why dotenv re-reads between tasks — see gcp:refresh), times each, stops
on first failure, and prints ONE grand-total summary plus start/end 🗿 banter. Leaf tasks
must go through `scripts/run.sh "<title>" <command...>`, which prints a step delimiter only
(timing/summary are the wrapper's job — don't add per-task summaries there). `stack.sh` /
`mesh.sh` frame their own multi-step progress + a content summary (what was built). Don't
call `helmfile`/scripts bare from a task.

**Run audit log.** The wrapper appends one compact line per run to
`.solomog/audit/YYYY-MM.log` (monthly rotation, gitignored, beside `test-runs/`):
`<ISO-ts>  <ok|FAIL>  rc=<n>  dur=<n>s  <tasks + vars>  [per-task=Ns …]`. Secret-looking
var VALUES (name matches KEY/TOKEN/SECRET/PASSWORD/PASS) are redacted to `***`. It's
best-effort — never fails the run — and bare `solomog` (the task list) isn't audited.

## Gotchas (learned the hard way)

- **`.env` inline comments after an EMPTY value are not comments — they become the literal
  value.** go-task's dotenv parser strips a trailing `# comment` only when a real value
  precedes it (`FOO=true    # comment` → `true`, confirmed). But `FOO=    # comment` (empty
  value) yields the literal string `"# comment"` as `$FOO` — this crash-looped the
  agentgateway controller once (`TOKEN_EXCHANGE_JWKS_URL=            # default: http://...`
  became the JWKS URL, producing `unsupported protocol scheme ""`). Fix: quote genuinely-empty
  defaults — `FOO=""    # comment` parses to a true empty string with the comment intact
  (verified). Every `VAR=<empty> # comment` line in `.env.example` uses this `=""` form; keep
  new ones consistent.
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
- **Inter-cluster host routing is ephemeral** — the DOCKER-USER rules live in the Docker Desktop
  VM and vanish on a Docker restart, silently disconnecting any multi-cluster mesh (flat or
  gateway). Re-apply with `solomog net:repair CLUSTERS="…"`. The routing goes in **DOCKER-USER**,
  not a private nft table: an nft table's `accept` can't override Docker's inter-bridge isolation
  `DROP` (both are base chains on the forward hook, DROP wins), but FORWARD hits DOCKER-USER first
  and an ACCEPT there is terminal.
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
    **Enterprise pin is deliberate: v2.3.x is the latest STABLE quarterly release
    (production-recommended). Do NOT bump to the newer CalVer builds (v2026.x) — those
    are NON-STABLE (test/dev). Solo is mid-transition SemVer→CalVer; solomog mirrors
    customer PRODUCTION envs, so it tracks the stable line even though CalVer is
    numerically newer.** ([docs](https://docs.solo.io/agentgateway/2.3.x/reference/versions/#supported-versions))
    Consequence: the `EnterpriseAgentgatewayBackend` CEL rules differ by line — v2026.x
    lets a `policies` block hold just `auth`, but on 2.3.x `policies` must also include a
    non-empty `policies.ai`. Solo workshops are written for the CalVer builds, so their
    AI-backend manifests need a `policies.ai` added to validate on 2.3.x (this is why the
    `bundles/llmroute` backends carry `modelAliases`/`promptCaching`). See versions.env.
  - `gloo-gateway` — 1.21.x (classic Helm repos).
  - `management` (Solo UI add-on) — 0.4.5, `us-docker.pkg.dev/solo-public/solo-enterprise-helm/charts`
    (verified: docs.solo.io/agentgateway/2.3.x/install/ui/setup/). `kube-prometheus-stack` 80.4.2
    (prometheus-community) for the monitoring add-on.
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

- **Multi-network (`gateway`) east-west wiring** is now automated by `mesh-eastwest.sh`
  (expose + link, declarative) + `networking.sh gateway` (routing) — the mesh comes up peered.
  Validated on Docker Desktop / vind with a 2-cluster ambient mesh (`istioctl multicluster
  check` → all ✅). N>2 uses a full remote-peer mesh (every cluster links every other); exercise
  a 3-cluster gateway mesh to confirm.
- **`gloo-mesh` mgmt-plane repo** is the last unverified chart coordinate.
- Confirm whether enterprise products use **distinct** license keys or one shared
  Gloo license (design supports both; per-product env vars fall back to SOLO_LICENSE_KEY).
- vcluster config (`clusters/*.yaml`) k3s `extraArgs` format should be checked
  against the installed vcluster version (the schema changed across 0.19+).
- Community/upstream chart versions differ from enterprise version lines
  (kgateway, istio) — `versions.env` is pinned to enterprise values by default.
