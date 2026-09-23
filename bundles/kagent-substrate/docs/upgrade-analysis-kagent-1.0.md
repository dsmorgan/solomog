# Upgrade analysis: kagent 0.10.1 to 1.0.0-alpha1

Read from the published charts, CRDs and source on 2026-09-22. Nothing here was run against a
cluster.

**Verdict: this is a rewrite of the bundle's agent layer, not a version bump.** The CRD the
bundle is built on no longer exists, the REST API its tests and Substrate Scope depend on is
gone, and the substrate line it pairs with cannot be installed by helm alone. Budget a day,
not an hour, and do not start until you want the 0.2 substrate line for its own sake.

## What the bundle pins today

| | Pinned | Set in |
|---|---|---|
| kagent | 0.10.1 | `20-kagent.sh`, `SUBSTRATE_KAGENT_VERSION` |
| substrate | 0.0.9 | `10-substrate.sh` and `20-kagent.sh`, `SUBSTRATE_VERSION` |
| substrate-scope | commit 5d27549 | `helpers/scope.sh`, `SCOPE_REF` |

kagent 1.0.0-alpha1 vendors `kagent-dev/substrate v0.2.0-beta4`, so moving kagent moves
substrate with it. The two cannot be upgraded separately.

## The object model changed shape

This is the part that costs the day. Every kagent CRD moved to `v1alpha3`, and the agent
kinds were reorganized:

| 0.10.1 | 1.0.0-alpha1 |
|---|---|
| `Agent`, `SandboxAgent` | `AgentTemplate` |
| `AgentHarness` | `Harness` |
| `Memory`, `ToolServer` | removed |
| `ModelConfig`, `ModelProviderConfig`, `RemoteMCPServer` | kept, now `v1alpha3` |

A `SandboxAgent` used to be one object: an agent definition plus `spec.substrate`. That
splits in two.

- **`AgentTemplate`** holds only the agent: `systemPrompt`, `modelConfig`, `tools`, `skills`,
  `plugins`. It has no substrate block, no runtime, no image.
- **`Harness`** holds the runtime. `spec.substrate` and `spec.workload` are both **required**,
  `spec.workload.image` must be a digest-pinned OCI reference, and a CEL rule enforces exactly
  one adapter from `kagent`, `codex`, `claude` or `byo`. A Harness admits templates through
  `spec.allowedAgentTemplates.selector`, and admits none when that is omitted.

**The density story survives.** The controller's reconcile unit is an
`AgentTemplateHarnessPair` (`go/core/internal/controller/reconciler.go`): each pair compiles
to one ActorTemplate revision. Four AgentTemplates admitted by one Harness still produce four
ActorTemplates and four actors, so slide 3's "4 agents, 0 pods" claim holds. Placement is now
revision-based, with a digest and a revision garbage collector.

## What breaks, file by file

| File | What breaks | Fails how |
|---|---|---|
| `30-sandboxagents.yaml` | `SandboxAgent` does not exist. Needs rewriting as one `Harness` plus four `AgentTemplate` objects at `v1alpha3` | loud: `no matches for kind` |
| `10-substrate.sh` | substrate 0.2.0-beta4 needs six secrets no chart template creates; the valkey health gate is meaningless because postgres replaced valkey | loud, then a wrong gate |
| `20-kagent.sh` | `substrateWorkerPool.ateomImage` renamed to `workerImage` | loud: helm `fail` names the value |
| `20-kagent.sh` | `controller.substrate.ateApiInsecure` removed, along with `ateApiTokenFile`, `ateApiTokenAudience`, `ateApiTokenExpirationSeconds` and `ateApiServer.*` | **silent**: `--set` on an unknown key is accepted and ignored |
| `tests/20-substrate-platform.sh` | asserts `valkey-cluster-0` and `cluster_state:ok` | loud, but for the wrong reason |
| `tests/40-golden-snapshots.sh` | queries `sandboxagents.kagent.dev` | loud |
| `tests/50-substrate-status.sh` | `/api/substrate/status` is gone. The whole `internal/httpserver` REST layer is gone except auth helpers | loud |
| `tests/60-chat-and-restore.sh` | `/api/a2a-sandboxes/<ns>/<name>/` is gone; A2A moved behind `internal/a2agateway` | loud |
| `helpers/scope.sh` | see below | quiet and worse |

The silent one is the trap. `helm --set controller.substrate.ateApiInsecure=true` against
1.0.0-alpha1 sets a value nothing reads, so the install succeeds and the controller talks to
ate-api under whatever the new default is. Those removed values line up with substrate 0.2
dropping `auth.mode: jwt` for the PodCertificate path, so the credential model changed
underneath. Verify the controller actually reaches ate-api before trusting a green install.

## Substrate Scope is the real casualty

Scope's high-fidelity `kagent` source reads three things from the controller, and
1.0.0-alpha1 removes all three: `/api/substrate/status`, the sessions API it folds into the
drawer, and `/api/a2a-sandboxes/...` for SURGE, the drawer chat box and `stimulate.mjs`.

Scope does not error. It falls back to its `crd` source and draws WorkerPools, worker pods and
ActorTemplates with no actor placement, no chat, no traffic generation. `tests/50-` exists to
catch exactly this, and it would.

Scope also reads `item.spec.ateomImage` from the WorkerPool (`server.mjs:465`), which becomes
`workerImage`. Cosmetic next to the rest.

**Nothing in the bundle can fix this.** Either the REST surface returns upstream, or scope
gains a gRPC or direct-ateapi adapter. Scope's own README already asks for the latter.

## Substrate 0.2.0-beta4 needs a bootstrap the chart does not do

Rendering the chart shows six secrets that are mounted but never created:

```
service-dns-ca-pool      pod-identity-ca-pool     (podcertificate-controller)
actor-id-ca-pool         actor-id-jwt-pool        (ate-api-server)
actor-id-ca-certs        egress-mitm-ca-pool      (atenet-egress)
```

They come from `kubectl ate admin make-ca-pool` and `make-jwt-pool` in the upstream
`hack/install-ate.sh`, plus one derived cert-only secret. `kubectl-ate` is published as a
darwin-arm64 binary on the `kagent-dev/substrate` releases, so this is a new root hook that
downloads a binary and runs six commands, not a Go build. It is work, but it is bounded.

Note that `atenet-egress` deploys by default at 0.2, so `egress-mitm-ca-pool` is not optional
the way it was on the 0.0.x line.

## What improves, and what does not

Worth having:

- **postgres replaces valkey.** The fragility that killed a cluster in the reference lab, and
  that `10-substrate.sh` still gates against, goes away.
- **`atenet-egress`** adds a second agentgateway doing HTTPS interception on actor egress with
  Kubernetes-Secret-backed credential injection. An actor calls an upstream API without ever
  holding the key. That is a genuinely better demo than anything in the bundle today.
- **Revision-based placement** with a digest and a GC, which should make rollouts legible.

Not fixed:

- **The MTU defect persists.** `cmd/ateom-gvisor/` still contains no MTU handling at the
  upstream HEAD of 2026-09-18, while `cmd/ateom-microvm/net.go` still propagates the actor
  veth MTU. The MSS clamp in `helpers/vcluster-substrate.yaml` stays necessary, and
  `docs/issue-ateom-gvisor-mtu.md` stays worth filing. That answers one item on its
  pre-filing checklist: re-tested on the 0.2 line, still absent.

## One correction worth recording

The ghcr tags-list API truncates. Listing tags for `ateom-gvisor` returns nothing above
`v0.0.26`, which reads as "the worker image has no 0.2 build" and is wrong. A direct manifest
request for `ateom-gvisor:v0.2.0-beta4` returns 200, as do all six other component images the
0.2 chart renders. Check manifests, not tag lists, before reporting a missing image.

## Recommendation

Stay on kagent 0.10.1 and substrate 0.0.9. The upgrade costs a rewrite of the agent manifests,
a new bootstrap hook, four rewritten tests, and the loss of most of what makes the demo worth
showing, in exchange for an egress story we are not demonstrating yet.

Revisit when both are true:

1. Scope can see actor state on the new kagent, whether through a restored REST path or a new
   adapter. Without it the board is half dead and the demo is not worth giving.
2. The 1.0.0 line is out of alpha, or a customer conversation needs the `atenet-egress`
   credential-injection story specifically.

If you want the 0.2 substrate line before either is true, the cheaper path is a **second
bundle** that pins the new pair and demonstrates egress credential injection, leaving this one
on the working pins. The two would share a cluster config and nothing else.
