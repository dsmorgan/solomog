# Architecture spec: vSphere/k3s homelab provisioner (`vsphere:*`)

**Status:** approved for implementation · **Branch:** `vsphere-k3s-provisioner` · **Date:** 2026-08-09

Adds a third cluster provisioner to solomog — alongside vind (local) and EKS — that
builds k3s clusters on a homelab vCenter 7.0.3, then registers them so every existing
solomog task works against them unchanged via `CLUSTER=<name>`.

## Decisions record

| # | Decision | Choice |
|---|---|---|
| 1 | VM provisioning engine | **OpenTofu** (`tofu`), vsphere provider, one workspace per cluster |
| 2 | OS + distro | **Ubuntu 24.04 cloud image + cloud-init + k3s** (pinned `K3S_VERSION`) |
| 3 | IPs / LB / DNS | **Static IP pool from `.env` + MetalLB (L2) + `/etc/hosts`** (expose unchanged) |
| 4 | v1 cluster shape | **1 server + N agents**, default `NODES=2`, no HA |
| 5 | init gating | `vsphere:create` **hard-fails** if `vsphere:init` hasn't been run |
| 6 | Snapshots | **Opt-in** (`SNAPSHOT=true` on create; `vsphere:reset` reverts) |
| 7 | Isolation | **No runtime feature flag** — structural isolation (see below); zero new prerequisites for non-vsphere users |
| 8 | Workflow | All work on branch `vsphere-k3s-provisioner`, incremental commits at least per phase |

## Goals / non-goals

**Goals**
- `solomog vsphere:create CLUSTER=hl1` → working k3s cluster on vCenter, registered in
  `.solomog/contexts`, so `stack` / `expose` / `apply` / `monitoring` / `graph` / `routes`
  work verbatim (`solomog agentgateway:ui expose apply BUNDLE=… ROUTE=true CLUSTER=hl1`).
- Clean, state-based teardown (`vsphere:delete`) that can never touch non-solomog VMs.
- Zero impact on existing vind/EKS users: no new setup.sh prerequisites, no behavior
  change to any existing task, additive-only touches to shared files.

**Non-goals (v1)**
- HA control plane, kube-vip, homelab-DNS integration, RKE2/Talos, flat-network
  multi-cluster pod routing (flannel CIDRs aren't routable across VMs — multi-cluster
  mesh on vsphere uses the existing `gateway` topology, later phase).
- Multi-vCenter / multi-datastore / multi-portgroup selection. One of each, from `.env`.

## Isolation design (decision 7 rationale)

A runtime feature flag is **not needed**. The capability is gated naturally by three
things that are all absent on a work machine, each failing fast with guidance:

1. **Tooling is lazy-checked, never a setup prerequisite** — the established EKS
   precedent: `eksctl` is not in setup.sh's brew list; `eks-create.sh` checks
   `command -v eksctl` at run time. Same rule here: `setup.sh` is **not modified**;
   `scripts/lib/vsphere.sh` preflights `tofu` (and `kubectl`, `ssh`/`scp`) and fails
   with `brew install opentofu` guidance.
2. **Config presence is the switch** — every `vsphere:*` task preflights the
   `VSPHERE_*` vars; unset (the state of any non-homelab `.env`) → immediate, clear
   error naming this as the homelab provisioner. An explicit `VSPHERE_ENABLED` flag
   would be a second switch that can drift from the real gate (creds+tooling); the
   preflight *is* the flag.
3. **Physical containment** — all vsphere logic lives in files that don't exist today:

   ```
   taskfiles/vsphere.yaml          # ALL vsphere:* tasks (go-task include)
   scripts/vsphere-create.sh
   scripts/vsphere-delete.sh
   scripts/vsphere-init.sh
   scripts/vsphere-snapshot.sh     # phase 4
   scripts/lib/vsphere.sh          # preflight + ip allocator + shared helpers
   terraform/vsphere-init/         # tofu root: content library + template (global state)
   terraform/vsphere-k3s/          # tofu root: cluster VMs (workspace per cluster)
   helmfiles/addons/metallb.yaml.gotmpl
   ```

   The **only** shared-file touches, all additive:
   - `Taskfile.yaml` — one `includes:` block:
     ```yaml
     includes:
       vsphere:
         taskfile: taskfiles/vsphere.yaml
         optional: true          # file absent → solomog behaves exactly as today
     ```
     Tasks inside the include are named `init`/`create`/`delete`/… and surface as
     `vsphere:init` etc. — same colon convention as `eks:create`, but later vsphere-only
     phases edit `taskfiles/vsphere.yaml`, so a YAML typo there can never break the
     shared Taskfile / vind flows. (Phase 1 verifies the include sees root `dotenv`
     and the wrapper's help/audit paths; if included tasks don't inherit dotenv, the
     include file declares its own `dotenv:` — still zero shared-file impact.)
   - `.env.example` — one new commented section (all keys use the `=""  # comment`
     empty-value convention, so `env:sync` on a work Mac adds inert keys only).
   - `versions.env` — `K3S_VERSION`, `METALLB_VERSION`, `UBUNTU_OVA_URL` pins.
   - `.gitignore` — tofu state/dirs (see below).
   - `scripts/clusters.sh` (phase 4, optional) — label registry entries created by
     vsphere as `vsphere` in `cluster:list` (additive display only).

   Explicitly **untouched**: `setup.sh`, `stack.sh`, `expose.sh`, `mesh.sh`,
   `networking.sh`, `lib/target.sh`, all product/app helmfiles.

4. **Per-phase regression guard** — every phase's acceptance criteria include:
   Taskfile YAML lint (`ruby -ryaml …`), bare `solomog` listing works, `solomog help
   <existing task>` works, and `helmfile build` passes for an existing product module.
   Phase 3 additionally runs a full vind smoke (`solomog agentgateway expose
   apps:utils ROUTE=true CLUSTER=…` locally) to prove the existing path end-to-end.

## Architecture

The registry seam does all the work. `eks:create` proved the pattern: provision
out-of-band, then `solomog_register_context <cluster> <context>` — downstream tasks
resolve `CLUSTER=` through `solomog_context` and treat the cluster as external
(install-only; never vind-create/teardown/network it).

```
solomog vsphere:create CLUSTER=hl1 [NODES=2] [SNAPSHOT=true]
  │
  ├─ preflight (lib/vsphere.sh): tofu present · VSPHERE_* set · init state exists
  ├─ IP allocation: N+1 addresses from the pool → .solomog/vsphere/ippool
  ├─ tofu -chdir=terraform/vsphere-k3s: workspace select -or-create hl1 → apply
  │     clone template → 1 server + N agent VMs
  │     per-VM cloud-init via guestinfo: static IP, ssh key, k3s install
  │        server: k3s server --disable traefik --disable servicelb --tls-san <ip>
  │        agents: k3s agent → https://<server-ip>:6443, shared token (tofu random_password)
  ├─ wait for SSH on server → scp /etc/rancher/k3s/k3s.yaml → rewrite 127.0.0.1→<server-ip>
  │     → merge into ~/.kube/config as context  vsphere_hl1
  ├─ wait for N+1 Ready nodes
  ├─ MetalLB: helmfile sync addons/metallb + apply IPAddressPool/L2Advertisement
  │     rendered from VSPHERE_LB_POOL
  ├─ [SNAPSHOT=true] snapshot every VM as "solomog-baseline"
  └─ solomog_register_context hl1 vsphere_hl1
        → CLUSTER=hl1 now works everywhere, exactly like a registered EKS cluster
```

`expose` needs nothing: MetalLB satisfies the LoadBalancer Service, the Gateway's
`status.addresses[0]` carries a real routable IP from `VSPHERE_LB_POOL`, mkcert + 
`/etc/hosts` behave exactly as with vind.

## Component contracts

### `scripts/lib/vsphere.sh`

- `vsphere_preflight <task-label>` — checks in order, first failure exits 1 with fix
  guidance: `tofu` on PATH (→ `brew install opentofu`); required `VSPHERE_*` vars
  non-empty (→ names the missing keys, points at `.env.example` section, states this
  is the homelab provisioner); for create/delete: init state present
  (`tofu -chdir=terraform/vsphere-init output` succeeds → else
  `run: solomog vsphere:init first`). **This satisfies decision 5.**
- `vsphere_alloc_ips <cluster> <count>` / `vsphere_release_ips <cluster>` — sequential
  scan of `VSPHERE_NODE_POOL_START` + `VSPHERE_NODE_POOL_SIZE`, records
  `<cluster>\t<ip>\t<server|agent-N>` lines in `.solomog/vsphere/ippool` (gitignored);
  release drops the cluster's lines. Single-user tool — no locking.
- Follows repo rules: bash 3.2 compatible, sourced like `lib/target.sh`.

### `terraform/vsphere-init/` (run by `vsphere:init`)

One global state (in-root, gitignored). Resources: `vsphere_content_library` +
`vsphere_content_library_item` pulling `UBUNTU_OVA_URL` (Ubuntu 24.04 server
cloudimage OVA). Idempotent — re-running is a no-op apply. Output: template item id/name
(consumed by preflight and the k3s root via `terraform_remote_state` or data source).
Fallback if the vCenter can't reach the internet: `VSPHERE_OVA_LOCAL_PATH` var switches
the item to a local-file upload.

### `terraform/vsphere-k3s/` (run by `vsphere:create`/`delete`; workspace = cluster)

| Inputs (var) | Source |
|---|---|
| `cluster`, `node_count` | CLI (`CLUSTER`, `NODES`) |
| `server_ip`, `agent_ips` | allocator |
| `cpus`, `memory_gb`, `disk_gb` | `VSPHERE_NODE_CPUS/MEM_GB/DISK_GB` |
| `net_gateway`, `net_dns`, `net_prefix`, `network`, `datastore`, `compute_cluster`, `datacenter` | `.env` |
| `ssh_pubkey` | file(`VSPHERE_SSH_PUBKEY_PATH`) |
| `k3s_version` | `versions.env` |

Internals: `random_password.k3s_token` (state-held); per-VM `vsphere_virtual_machine`
cloned from the template with `extra_config` guestinfo keys
(`guestinfo.metadata` = network v2 + hostname, `guestinfo.userdata` = cloud-init,
both `gzip+base64`); agents `depends_on` the server. cloud-init templates
(`server.yaml.tftpl`, `agent.yaml.tftpl`) create user `solomog` with the ssh key and
run the pinned k3s installer (`INSTALL_K3S_VERSION`). Outputs: `server_ip`, `node_ips`.

VM naming: `solomog-<cluster>-server`, `solomog-<cluster>-agent-<n>` — prefix makes
solomog-owned VMs obvious in vCenter, but ownership truth is tofu state, not the name.

### `scripts/vsphere-create.sh` / `vsphere-delete.sh`

Mirror `eks-create.sh` in shape (Env: header, `CLUSTER` required with no default,
idempotent re-run just re-registers). Create: the flow diagrammed above; readiness
polls with timeouts and a clear failure message naming the phase that stalled.
Delete: **prompt first** (teardown ethos) → `tofu destroy` on the workspace → delete
workspace → `vsphere_release_ips` → `kubectl config delete-context vsphere_<cluster>`
(+ cluster/user entries) → `solomog_deregister_context`. Never enumerates vCenter by
name — only state-tracked resources are destroyed.

### MetalLB addon

`helmfiles/addons/metallb.yaml.gotmpl` (edition-agnostic, like monitoring), ns
`metallb-system`, version `METALLB_VERSION`. Installed by `vsphere-create.sh`, **not**
`stack.sh` — it's cluster infrastructure, not a product; vind/EKS clusters never get it.
Pool + L2Advertisement CRs are applied by the script after sync (rendered from
`VSPHERE_LB_POOL`), since they're config-from-`.env`, not chart values.

### Snapshots (opt-in) — phase 4

- `vsphere:create … SNAPSHOT=true` → after Ready + MetalLB, snapshot all cluster VMs
  as `solomog-baseline` (via tofu-invoked provisioner or govc-free API script — 
  implementation picks; no new required tooling).
- `solomog vsphere:reset CLUSTER=hl1` → revert all VMs to `solomog-baseline`, power on,
  wait Ready. ~30s clean cluster; errors clearly if no baseline exists. Baselines are
  memory-less, so revert is a clean cold boot of the snapshot's disk state — no
  suspend-image clock jump; the discarded running state needs no graceful stop.
- `vsphere:stop` / `vsphere:start` (added post-bring-up) → pause/resume: graceful
  guest shutdown of all node VMs (hard-off fallback) freeing host CPU/RAM, then
  power-on + wait Ready. State-preserving, unlike reset's restore-to-baseline.

### Taskfile include (`taskfiles/vsphere.yaml`)

Tasks: `init`, `create`, `delete`, `reset`, `snapshot` — each framed through
`scripts/run.sh` like other leaf tasks, each with `summary:` blocks (respecting the
`Variables:` not `vars:` rule), and **every script knob wired through the task `env:`
block** (`NODES`, `SNAPSHOT`, `VSPHERE_*` passthroughs) per the CLAUDE.md rule.

## `.env.example` additions

```bash
# ── vSphere homelab provisioner (optional — leave empty unless using vsphere:*) ──
VSPHERE_SERVER=""            # vCenter FQDN/IP
VSPHERE_USER=""              # e.g. administrator@vsphere.local
VSPHERE_PASSWORD=""
VSPHERE_ALLOW_UNVERIFIED_SSL=""   # "true" for homelab self-signed vCenter certs
VSPHERE_DATACENTER=""
VSPHERE_COMPUTE_CLUSTER=""
VSPHERE_DATASTORE=""
VSPHERE_NETWORK=""           # portgroup name
VSPHERE_NODE_POOL_START=""   # first node IP, e.g. 10.0.20.50
VSPHERE_NODE_POOL_SIZE=""    # e.g. 20
VSPHERE_LB_POOL=""           # MetalLB range, e.g. 10.0.20.200-10.0.20.219
VSPHERE_NET_GATEWAY=""
VSPHERE_NET_DNS=""
VSPHERE_NET_PREFIX=""        # e.g. 24
VSPHERE_NODE_CPUS=""         # default 4
VSPHERE_NODE_MEM_GB=""       # default 8
VSPHERE_NODE_DISK_GB=""      # default 40
VSPHERE_SSH_PUBKEY_PATH=""   # default ~/.ssh/id_ed25519.pub
VSPHERE_OVA_LOCAL_PATH=""    # fallback when vCenter can't fetch UBUNTU_OVA_URL
```

`versions.env`: `K3S_VERSION` (e.g. `v1.33.4+k3s1`), `METALLB_VERSION`,
`UBUNTU_OVA_URL` (pinned release URL). `.gitignore` adds `terraform/**/.terraform/`,
`terraform/**/terraform.tfstate*`, and `terraform/**/terraform.tfstate.d/`;
the `.terraform.lock.hcl` files are **committed** (they pin provider versions).

## Phases, commits, acceptance criteria

All on branch `vsphere-k3s-provisioner`; ≥1 commit per phase (more where natural).

| Phase | Deliverable | Acceptance |
|---|---|---|
| **0** | This spec | committed (this commit) |
| **1 — rails** | `includes:` block, `taskfiles/vsphere.yaml` with preflight-only task bodies, `lib/vsphere.sh` (preflight + allocator + unit-ish test à la `test-envfile.sh`), `.env.example` section, `versions.env` pins, `.gitignore` | On a machine with no tofu/config: `solomog vsphere:create CLUSTER=x` fails fast with guidance. Regression guard passes (lint, bare `solomog`, `help`, `helmfile build`). Include verified against wrapper help/audit + dotenv. |
| **2 — init** | `terraform/vsphere-init/`, `vsphere-init.sh`, task | Template lands in vCenter; re-run idempotent; `vsphere:create` without init fails with "run vsphere:init first" (decision 5 proven). |
| **3 — cluster** | `terraform/vsphere-k3s/`, `vsphere-create.sh`/`-delete.sh`, MetalLB addon, registration | `solomog vsphere:create CLUSTER=hl1` → `solomog agentgateway expose apps:utils ROUTE=true CLUSTER=hl1` passes the `/httpbin` smoke test. `vsphere:delete` leaves no VMs, no context, no registry/ippool entries. Full vind smoke still green. |
| **4 — QoL** | opt-in `SNAPSHOT=true`, `vsphere:reset`, `cluster:list` vsphere labels, README + CLAUDE.md docs | reset → Ready cluster in well under create time; docs follow existing structure. |
| **5 — mesh (stretch)** | 2× vsphere clusters + `gateway`-topology Istio mesh (existing `mesh-eastwest.sh`; **no** networking.sh analog needed — east-west gateways get real MetalLB IPs) | `istioctl multicluster check` green across two hl clusters. |

## Addendum (2026-08-10): Phase 6 — real DNS + real certs (`DNS=real`)

Post-bring-up decision: `/etc/hosts` + mkcert stays the **default** (`DNS=local` —
zero network dependencies, works anywhere), and a per-run **toggle** adds
network-wide resolution + publicly-trusted TLS for homelab clusters:
`solomog expose CLUSTER=s1 DNS=real`. Rationale: EKS never needed hosts-file
hacks (public LB hostname); vsphere shouldn't either once real DNS exists — and
the homelab already runs the two services this needs.

### Decisions

| # | Decision | Choice |
|---|---|---|
| 9  | DNS authority | **OPNsense** (dnsmasq) holds the records. **REVISED with the `sm.tnkr.fun` zone choice**: since the zone is no longer under the already-forwarded apex delegation, Pi-hole needs ONE one-time zone forward (`server=/sm.tnkr.fun/<opns1>` — same pattern as the apex exception); OPNsense-direct hosts need nothing. expose prints both lines when the name doesn't resolve. Public tnkr.fun (Cloudflare) stays untouched — NXDOMAIN publicly; the zone exists there only for Certwarden's DNS-01. |
| 10 | Record management | **REVISED (2026-08-11): automated via the OPNsense API.** The original "manual line, printed by solomog" trade was rejected by David once real; flat naming reduced the need to an exact-name **Dnsmasq host override**, which `expose DNS=real` now upserts idempotently through `lib/opnsense.sh` (search_host → add/set_host → reconfigure; dedicated low-priv API user; creds `OPNSENSE_URL/_API_KEY/_API_SECRET` in .env), then verifies with `dig @opns1`. Printed manual instructions remain the fallback when creds are absent or the API errors. The one-time-ever Pi-hole zone forward (`server=/sm.tnkr.fun/<opns1>`) stays manual by choice. external-dns still deferred. |
| 11 | Certificates | **Build on Certwarden** (operational, prod LE via Cloudflare DNS-01) — solomog becomes another pull client, same `X-API-Key` pattern as the existing synology/pihole/unifi pull scripts. No cert-manager, no per-cluster ACME. |
| 12 | Cert shape | **REVISED at implementation (2026-08-10, David's call): one wildcard, zero maintenance.** DNS=real hostnames are **FLAT** — `<gw>-<cluster>.<domain>` (e.g. `agw-s1.sm.tnkr.fun`) — so a single Certwarden cert with SAN `*.<domain>` covers every cluster/gateway forever (wildcards match one label). No per-cluster SANs, no reissues; `.env` carries two API keys. Supersedes the original dotted-name/per-cluster-SAN plan; when sub-host UIs later join DNS=real they flatten the same way (`ui-agw-s1.<domain>`, still one label — each such sub-host then needs its own dnsmasq line, the trade accepted for cert-zero-touch). Domain chosen: `sm.tnkr.fun`. |
| 13 | VIP stability | **Name-sticky deterministic VIPs** — the allocator also assigns each (cluster, gateway) a VIP from `VSPHERE_LB_POOL` (recorded in ippool as `lb-agw`/`lb-kgw` roles); expose pins it via the Gateway's `spec.infrastructure.annotations` → `metallb.io/loadBalancerIPs` (fallback: annotate the LB Service). `vsphere:delete` keeps `lb-*` allocations by default so the DNS record survives recreate cycles; `PURGE_LB=true` releases them. |
| 14 | mkcert default | Unchanged. `DNS=local` remains the default everywhere; `DNS=real` requires a vsphere target (a vind LB IP is Mac-local — unreachable from other devices, so real DNS is pointless there). |

### `DNS=real` expose flow (replaces steps 3–4 of the local flow)

1. Guard: vsphere cluster + `SOLOMOG_DOMAIN` + `CERTWARDEN_*` set (else fail with guidance).
2. `HOST = <gw>.<cluster>.${SOLOMOG_DOMAIN}` (e.g. `agw.s1.lab.apex.district11.net`).
3. Pin the gateway VIP from the allocator's `lb-<gw>` record.
4. Fetch cert + key from Certwarden (`X-API-Key` per object; endpoint paths verified
   against `~/code/tls-automation/scripts/` at implementation) → `kubectl create
   secret tls` (same `SECRET` name the Gateway already references).
5. Create the Gateway (unchanged emit).
6. **No `/etc/hosts`.** Instead `dig +short $HOST` — resolves to the pinned VIP → done;
   else print the exact one-time OPNsense line:
   `address=/<gw>.<cluster>.${SOLOMOG_DOMAIN}/<VIP>` (and where to put it).
7. Renewal: Certwarden renews centrally; the in-cluster secret refreshes on any
   `expose DNS=real` re-run (LE's 90 days ≫ typical cluster lifetime; an optional
   `certs:refresh` task is a stretch item).

`route-host.sh` (UI/Grafana sub-hosts) becomes DNS-mode aware: in real mode it skips
`/etc/hosts` — the subtree record + `*.agw.<cluster>` SAN already cover sub-hosts.

### `.env` additions

```bash
SOLOMOG_DOMAIN=""            # e.g. lab.apex.district11.net — presence enables DNS=real
CERTWARDEN_URL=""            # e.g. https://certwarden.apex.district11.net:4055
CERTWARDEN_CERT_APIKEY=""    # API key of the shared solomog cert object
CERTWARDEN_KEY_APIKEY=""     # API key of its private-key object
```

### Sub-phases & acceptance

- **6a — VIP pinning** (prereq, useful on its own): allocator `lb-*` roles + expose
  pinning + sticky-on-delete. Accept: recreate cycle keeps the same VIP; `DNS=local`
  behavior otherwise unchanged.
- **6b — `DNS=real`**: flow above. Accept: from a device that is NOT the Mac (phone,
  another laptop — no mkcert CA installed), `https://agw.s1.<domain>/httpbin/get`
  returns httpbin JSON with a green-lock LE cert.
  **IMPLEMENTED (2026-08-10)** in expose.sh (knob `DNS=local|real`, guards, Certwarden
  pull via the verified `/certwarden/api/v1/download/{certificates,privatekeys}/<name>`
  endpoints, SAN `-checkhost` warning, dig check + printed dnsmasq record). v1 scope
  note: **sub-host UIs (route-host.sh — `<x>:ui`, monitoring `ROUTE=true`) still use
  DNS=local** (.test + /etc/hosts); extending them to the real domain is a follow-up.
  Live acceptance pending David's one-timers: zone choice → `SOLOMOG_DOMAIN`, the
  Certwarden cert object (+SANs) and two API keys, the dnsmasq record.
- **Deferred (recorded, not planned)**: OPNsense API / external-dns automation of the
  per-cluster record (would need the BIND plugin + RFC2136 or API coupling — revisit
  only if per-cluster manual lines become real toil); EKS unification (Certwarden
  cert instead of self-signed mkcert on the cloud path).

### Phase-6 open items (verify at implementation)

- **Zone choice is deliberately open** — David wants short, memorable fqdns and may
  use a subdomain of his other TLD `tnkr.fun` (e.g. `s1.lab.tnkr.fun`) instead of
  nesting under `apex.district11.net`. Both TLDs are Cloudflare-managed publicly;
  Certwarden's Cloudflare DNS-01 covers either. `SOLOMOG_DOMAIN` stays the single
  knob either way — the only zone-dependent step is where the internal dnsmasq
  records/delegation live. **Cloudflare is NOT touched directly in this phase**;
  driving public Cloudflare records from solomog is a possible future enhancement
  (most useful for EKS deployments).
- OPNsense: confirm dnsmasq (not Unbound) serves the apex zone, and the wildcard
  `address=/…/` syntax/placement in its config UI.
- ~~`Gateway.spec.infrastructure.annotations` propagation to the LB Service~~
  **VERIFIED live (2026-08-10)**: agentgateway propagates it and MetalLB honors the
  pin — with a reconcile delay on re-expose, which expose handles via a 60s settle
  wait. Also verified live: snapshot/reset (revert → cold boot → Ready → same VIP →
  HTTP 200) and stop/start (graceful shutdown → resume → HTTP 200, VIP re-announced
  ~20s after Ready). kgateway propagation still unverified.
- Exact Certwarden download endpoints + object naming (from tls-automation scripts).
- LE rate limits are a non-issue with the single shared cert (reissues only on SAN
  changes), but note it if per-cluster certs are ever revisited.

## Risks / open items

- **cloud-init datasource precedence**: Ubuntu OVAs default to the OVF datasource,
  which can win over guestinfo. Mitigation order: (a) guestinfo keys + disable vApp
  OVF transport on the clone; (b) fall back to the OVA's native vApp `user-data`
  property. Settle empirically in phase 3; both are template-level, no interface change.
- **vCenter 7.0.3 + current vsphere provider**: provider supports 7.0.x, but pin the
  provider version in the lock file and note the tested pair in README.
- **OpenTofu registry**: `hashicorp/vsphere` resolves via the OpenTofu registry —
  verify at phase 1 `tofu init` time.
- **Arm/amd64**: homelab vSphere is amd64 — the amd64 OVA is correct here (unlike the
  arm64 rule for vind images). Note it in CLAUDE.md gotchas when documenting.
- **Pool exhaustion / overlap with DHCP**: allocator errors when the pool is exhausted;
  keeping the pool + `VSPHERE_LB_POOL` outside the homelab DHCP scope is the user's
  fixed assumption (documented in `.env.example` comments).
