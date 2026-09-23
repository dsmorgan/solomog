# Findings — kagent on Agent Substrate

Evidence behind the version pins and the cluster requirement, read from source or from a
published artifact on 2026-09-18 unless a line says it was observed live. Update the
**Status** line as more of it is confirmed.

**Status: partially verified on vind (2026-09-18).** A gate-enabled vind cluster hosts the
substrate platform: a cluster created with the bundle's `VCLUSTER_VALUES` file serves
`PodCertificateRequest`, and substrate 0.0.9 came up complete — ate-api-server,
ate-controller, **atelet**, atenet-router, dns, rustfs and all six valkey-cluster pods
Running, both init jobs Completed. So both of the doubts under "The vind question" below are
answered for the platform: vcluster **does** honour `controlPlane.distro.k8s.*.extraArgs` in
standalone mode, and atelet starts on a vind node. kagent 0.10.1 then installed against it and
generated an ActorTemplate per SandboxAgent.

**The whole thing runs from one command.** Verified 2026-09-18 on a cluster created from
nothing:

```bash
solomog vind:create apply test CLUSTER=kas2 BUNDLE=kagent-substrate \
  VCLUSTER_VALUES=bundles/kagent-substrate/helpers/vcluster-substrate.yaml
```

6/6 tests passed in 2m25s — `vind:create` 23s, `apply` 79s, `test` 43s — with a warm image
cache. A cold cache pays for ~570MB more of pulls in the `apply` step.

Chaining exposes one race that running the steps by hand hides: `apply` starts the moment
`vind:create` returns, and the node can still be joining. The preflight's readiness wait
engaged on this very run (`waiting for a Ready node.`), so without it the chained form would
have failed on `no Ready nodes` while the identical two-command form succeeded. Keep that
wait in place if you rework the preflight.

**gVisor works on vind.** After the `jwks_uri` fix below, tests 10–50 pass: all four
SandboxAgents bake a golden snapshot, which means substrate started each agent container
inside a runsc sandbox on a worker, let it reach ready, and checkpointed it to object
storage. Nothing short of a working gVisor produces that. No kind cluster is needed.

One thing does not work: **actor egress to the public internet** — see "Actor egress
blackholes on an overlay CNI" below. So the platform and the snapshot lifecycle are
demonstrable on vind today; a live LLM turn from inside an actor is not, until the MTU
question is settled.

## kagent ships the integration, not substrate

kagent has substrate support in-tree well back before 0.10 (`docs/substrate-agentharness-lifecycle.md`
and `go/core/pkg/sandboxbackend/substrate/` are present at v0.9.12). What it does **not**
ship is Agent Substrate itself. `helm/kagent/templates/substrate-workerpool.yaml` renders an
`ate.dev/v1alpha1` WorkerPool, which only applies if something else installed the `ate.dev`
CRDs first. So the install is always two charts then kagent:

```
substrate-crds → substrate (ate-system) → kagent (controller.substrate.enabled=true)
```

Substrate is published by the kagent org, not by its upstream: charts at
`oci://ghcr.io/kagent-dev/substrate/helm/{substrate-crds,substrate}`, tags `0.0.3`
through `0.0.30` and `0.2.0-beta1..4`. The upstream repo, `agent-substrate/substrate`,
installs from kustomize manifests via `hack/install-ate.sh` and publishes no charts.

## Why the pins are not "latest"

Two independent constraints pick the same pair.

**1. kagent vendors an exact substrate.** `go/go.mod` carries a replace directive:

| kagent | vendors substrate |
|---|---|
| v0.10.0, v0.10.1 | `kagent-dev/substrate v0.0.9` |
| v1.0.0-alpha1 | `kagent-dev/substrate v0.2.0-beta4` |

The pairing matters more than usual because actor records are stored as protojson and the
schema moved: a 0.0.9 ateapi reading 0.0.8's records fails with

```
while listing actors in db: in protojson.Unmarshal: proto: (line 1:2): unknown field "actorId"
```

which is also why in-place substrate upgrades across 0.0.x are not safe. Rebuild instead.

**2. Substrate 0.0.13+ cannot be installed by helm alone.** Chart `0.0.9` defaults to
`auth.mode: jwt`, and `templates/pod-certificate-controller.yaml` is wrapped in
`{{- if eq .Values.auth.mode "mtls" -}}`, so the PodCertificate path is skipped and
`jwt-bootstrap.yaml` self-bootstraps. From `0.0.13` the `auth` values are gone, the
podcert path is unconditional, and the controller mounts Secrets `service-dns-ca-pool`
and `pod-identity-ca-pool` that **no chart template creates**. Verified still true at
`0.2.0-beta4`: that chart contains no `kind: Secret` at all, and the CA pools are
non-optional projected sources. Without them the controller sits in `ContainerCreating`:

```
MountVolume.SetUp failed for volume "podidentity": credential bundle is not issued yet
```

The bootstrap is four `kubectl ate admin make-{ca,jwt}-pool` calls
(`hack/install-ate.sh`), and `kubectl-ate` **is** published as a binary for darwin-arm64
on the `kagent-dev/substrate` releases, so this is a hook rather than a Go build if we
ever move to the 0.2 line.

## The latest kagent breaks substrate-scope

substrate-scope's `kagent` source — the one with per-actor state, the chat drawer, SURGE
and `stimulate.mjs` — polls the controller's REST endpoint `/api/substrate/status`.

- Present at v0.10.1: `go/core/internal/httpserver/server.go` defines
  `APIPathSubstrateStatus = "/api/substrate/status"`, served by
  `handlers/substrate.go`.
- **Gone at v1.0.0-alpha1**: no `httpserver` substrate handler in the tree, no match for
  the path anywhere. The substrate surface moved to
  `go/core/internal/service/system/substrate.go` (gRPC) with the UI reading it through
  `ui/src/api/hooks/useSubstrate.ts`.

Scope does not error on this; it falls back to its `crd` source and renders a board with
WorkerPools, worker pods and ActorTemplates but no actors. That is roughly half the demo,
and it looks fine. `tests/50-substrate-status.sh` exists to catch it.

Worth raising upstream: either restore the REST path or give scope a gRPC adapter. Scope's
own README already asks for a direct ateapi adapter, which would solve both.

The full cost of moving to that line, including the CRD reshape and the substrate 0.2
bootstrap, is in `docs/upgrade-analysis-kagent-1.0.md`. Short version: the whole
`internal/httpserver` REST layer is gone, `SandboxAgent` no longer exists, and substrate
0.2.0-beta4 needs six secrets the chart does not create.

## agentgateway is already the substrate dataplane

Not a later step — it is in the path at the pinned version. `atenet-router` runs
`cr.agentgateway.dev/agentgateway:v1.3.0-alpha.1` alongside `atenet` started with
`--networking-mode=agentgateway`, and every request into an actor is routed by Host header
`<actor-id>.actors.resources.substrate.ate.dev`.

Substrate 0.2.x goes further: `atenet-egress` adds a second agentgateway doing HTTPS MITM
on actor egress with Kubernetes-Secret-backed credential injection, so an actor can call an
upstream API without ever holding the key. That is a strong story and a reason to revisit
the 0.2 line once the scope dependency is resolved.

A Solo-configured agentgateway in front of kagent — LLM routing, MCP tool RBAC, token
exchange — is a different thing from either of these, and belongs in its own bundle.

## The cluster requirement

Substrate mounts projected PodCertificate volumes and needs three alpha gates plus a
non-default API version:

```yaml
featureGates: { ClusterTrustBundle, ClusterTrustBundleProjection, PodCertificateRequest }
runtimeConfig: { "certificates.k8s.io/v1beta1": "true" }
```

A missing gate does not fail loudly. The projected source is **silently dropped** — helm
warns only `volume "podidentity" (Projected) has no sources provided` — and the first real
symptom arrives much later as

```
FATAL: could not load server certificate file "/run/servicedns.podcert.ate.dev/credential-bundle.pem"
```

with the release timing out on `context deadline exceeded`. The node image must be k8s
1.36+; on 1.35 kubeadm does not recognise `PodCertificateRequest` and drops it, leaving an
apiserver with only `ClusterTrustBundle=true`.

Stock vind clusters do not qualify: they run k8s v1.36.0 already, which is the hard part,
but serve only `certificates.k8s.io/v1`.

## The vind question

vind is closer to kind than it looks. `vcluster create --driver docker` produces a
`ghcr.io/loft-sh/vm-container` running a kubeadm-style control plane in standalone mode
with `privateNodes` — its own kubelet and containerd 2.2.3, node reporting Ubuntu 24.04
and k8s v1.36.0. So the gates should be settable through
`controlPlane.distro.k8s.{apiServer,controllerManager}.extraArgs` and
`privateNodes.kubelet.config.featureGates`, which is what
`helpers/vcluster-substrate.yaml` sets.

Two things could still sink it, in order of likelihood:

1. **vcluster may not pass `distro.k8s.*.extraArgs` through in standalone mode.** The
   helper checks for the PodCertificateRequest API and fails with instructions if not.
2. **gVisor may not run nested.** atelet downloads a gVisor release tarball
   (`gs://gvisor/releases/nightly/...`, pinned in the `gvisor-default` SandboxConfig) and
   extracts runsc on the node. Whether runsc's systrap platform works inside a VM
   container on Docker Desktop's arm64 linuxkit kernel is untested. The first place this
   shows is atelet (`tests/20-`); the decisive one is a golden snapshot that never bakes
   (`tests/40-`).

If either fails, `helpers/create-cluster-kind.sh` is the proven path — it reproduces
substrate's own `hack/create-kind-cluster.sh` config. Record which one it was here.

## Actor egress blackholes on an overlay CNI

The last thing standing between this bundle and a green run on vind, and the more
interesting of the two vind-only findings.

A SandboxAgent turn fails with the task state `failed` and this message:

```
OpenAI chat completion request failed: Post "https://api.openai.com/v1/chat/completions":
  net/http: TLS handshake timeout
```

It is not a credential problem and not a substrate control-plane problem. Isolated by
comparing the two agent kinds on the same cluster, same Secret, same ModelConfig:

| agent | runs as | endpoint | result |
|---|---|---|---|
| `k8s-agent` | ordinary pod | `/api/a2a/kagent/…` | `completed` |
| `explainer` | substrate actor | `/api/a2a-sandboxes/kagent/…` | `failed`, TLS handshake timeout |

Node egress is healthy (`curl https://api.openai.com/v1/models` from the vcluster VM
returns 401 in 0.27s — reached and rejected, which is the correct answer unauthenticated),
and DNS resolves inside pods. So only the actor path is broken.

**The signature says MTU.** DNS resolved, the TCP connect completed, and the stall is at the
first large exchange — the TLS handshake. Small packets pass, big ones vanish. That is a
PMTU blackhole, not a reachability failure.

**The mechanism.** vcluster's node runs flannel in VXLAN mode, so `flannel.1` is MTU 1450
and pods get 1450 (`cat /sys/class/net/eth0/mtu` in any pod). kind's kindnet uses plain
routing at 1500, which is why upstream never hits this. In substrate's source,
`cmd/ateom-microvm/net.go` has an `actorVethMTU()` that reads the actor veth's MTU and
propagates it into the guest via the kata agent — while `cmd/ateom-gvisor/` contains **no
MTU handling at all**. The chart exposes no MTU knob either (`grep -ri mtu` over the 0.0.9
chart returns nothing).

**Status: CONFIRMED 2026-09-18** by a controlled comparison on one cluster, changing nothing
but the MSS clamp:

| TCP MSS clamped on the node | turns attempted | result |
|---|---|---|
| no | 4 | all `failed`, TLS handshake timeout |
| yes | 1 | `completed`, with the agent's real answer |

The clamp is `iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS
--clamp-mss-to-pmtu`, which rewrites the MSS during the handshake so both directions send
segments that fit the 1450-byte path. Nothing else changed between the runs.

**How the bundle handles it.** `helpers/vcluster-substrate.yaml` installs the clamp through
`controlPlane.standalone.joinNode.postJoinCommands`, as a systemd unit rather than a bare
`iptables` call so that it survives a Docker Desktop restart. A bare rule dies with the node,
and the demo then breaks in exactly the silent way this already cost a session to find.

This is a **workaround for a product defect, deliberately placed in the cluster config rather
than in the bundle**, next to a comment saying what it compensates for. The same defect will
hit any overlay CNI — Calico IPIP, Cilium VXLAN, flannel — and a customer meeting it on a real
cluster has no `postJoinCommands` to hide behind.

**Worth filing upstream** against `agent-substrate/substrate`: give `ateom-gvisor` the same
veth-MTU inheritance `ateom-microvm` already implements in `cmd/ateom-microvm/net.go`, where
`actorVethMTU()` reads the actor veth and passes the value to the guest. The report writes
itself — two agent kinds on one cluster, one variable changed, a four-line reproduction.

## substrate-scope is pinned, not vendored

`helpers/scope.sh` clones substrate-scope into `.solomog/substrate-scope` on first run and
checks out a fixed commit, `5d27549` ("kagent 0.10 compatibility + KUBE_CONTEXT pinning").
`SCOPE_REF=main` tracks upstream instead, and `SCOPE_REF=<sha>` takes any other commit.

Pinned because scope belongs to someone else and is under active development: tracking the
tip of `main` means an upstream commit can change the demo between the run you rehearse and
the one you give. Not vendored, for the mirror-image reason — a copy inside this bundle
would fork an actively maintained Apache-2.0 tool, go stale, and become ours to maintain.

The script leaves a checkout with local modifications alone and says so, so a patch you are
testing against scope survives a re-run.

## The A2A reply has no `artifacts` key

Worth knowing before trusting any tooling that reads one. kagent 0.10.1's
`/api/a2a-sandboxes/…` returns a task shaped like this:

```
result.kind            = "task"
result.status.state    = "completed" | "failed"
result.status.message.parts[].text   <- the agent's text, for BOTH outcomes
result.history[]                     <- the turn transcript
result.artifacts                     <- ABSENT
```

The first version of `tests/60-` read `.result.artifacts[].parts[].text` and reported
"completed with no artifact text" for a turn that had actually **failed** with the TLS
timeout above — discarding the one sentence that explained everything and sending the
investigation toward the wrong component. It now reads `status.state` first and falls back
through `status.message` → `history` → `artifacts` for the text.

**What this means for substrate-scope — partly verified, so read the caveat.** scope reads
reply text in three places, and they do not agree:

| Location | Reads | |
| --- | --- | --- |
| `server.mjs:339` sessions ingestion | `status.message` first, then `artifacts` | handles the shape above |
| `server.mjs:406` `chatWithAgent` (SURGE, drawer chat box) | `artifacts` only | would show `(no text)` |
| `stimulate.mjs:114` load generator | `artifacts` only | would show `(no text)` |

That one of the three already prefers `status.message` is suggestive: scope's history has a
`kagent 0.10 compatibility` commit, so the author appears to have met this shape and fixed
the path they were exercising.

**The caveat:** the absent `artifacts` key was observed on a **failed** task. Nobody has
confirmed what a **completed** task returns, because `tests/60-` reads the three fields as a
fallback chain and never reports which one matched. Settle it in one command the next time a
cluster is up, before changing anything in scope:

```bash
kubectl --context <ctx> port-forward -n kagent svc/kagent-controller 8083:8083 &
curl -sS -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":"x","method":"message/send","params":{"message":{"kind":"message","messageId":"x","contextId":"x","role":"user","parts":[{"kind":"text","text":"say PONG"}]}}}' \
  http://127.0.0.1:8083/api/a2a-sandboxes/kagent/explainer/ | jq '.result | keys, .status.state'
```

If `artifacts` is absent from a completed task too, the two direct-A2A paths need the same
treatment the sessions path already has, and the fix belongs upstream rather than in a local
patch.

## vcluster advertises an unreachable `jwks_uri`

The first thing to fail on vind that a kind cluster does not hit. Substrate 0.0.9 runs in
`auth.mode: jwt`: `ate-api-server` gets `--client-jwt-issuer=https://kubernetes.default.svc.cluster.local`,
fetches that issuer's OIDC discovery document, and then fetches the `jwks_uri` it names. On
this cluster the document reads:

```json
{
  "issuer":   "https://kubernetes.default.svc.cluster.local",
  "jwks_uri": "https://127.0.0.1:6443/openid/v1/jwks"
}
```

The issuer is exactly right, which is why a check on the issuer alone passes. The `jwks_uri`
is a loopback address, and inside any pod that means *that pod's own* loopback, so every
token validation dies:

```
while ensuring atespace "ate-golden": rpc error: code = Unauthenticated
  desc = invalid bearer token: while discovering keys from issuer: while fetching JWKS:
  Get "https://127.0.0.1:6443/openid/v1/jwks": dial tcp 127.0.0.1:6443: connect: connection refused
```

**Cause:** when `--service-account-jwks-uri` is unset, Kubernetes derives the advertised URI
from the apiserver's advertise address. On kind that is the node IP, which pods can reach.
A vcluster standalone control plane advertises `127.0.0.1:6443`. Confirmed on the live
cluster: the apiserver carries `--service-account-issuer` but no `--service-account-jwks-uri`.

**Fix**, now in `helpers/vcluster-substrate.yaml`:

```
--service-account-jwks-uri=https://kubernetes.default.svc.cluster.local/openid/v1/jwks
```

`kubernetes.default.svc.cluster.local` is in the apiserver's serving-cert SANs, and RBAC is
already in place — the substrate chart creates an `oidc-discovery-viewer` ClusterRoleBinding
for the `ate-api-server` SA, and `system:service-account-issuer-discovery` is bound to all
service accounts. The endpoint serves anonymously today; nothing else needs changing.

**Why it cost a debugging session, and what now catches it.** Every component reported
healthy: 14/14 substrate pods Running, kagent installed, WorkerPool at 2/2, ActorTemplates
created, SandboxAgents `Accepted=True`. The only visible symptom was
`Ready=False ActorTemplateNotReady: ActorTemplate golden snapshot is not ready` — the
symptom, not the cause — while the real error sat in a third component's logs. It reads
exactly like the gVisor failure this bundle was built to test for.

`00-preflight.sh` and `tests/10-cluster-gates.sh` now both check `jwks_uri` for a loopback
address and name this fix. `tests/40-` no longer blocks silently either: it polls with
progress, and when no ActorTemplate has acquired any status it stops early and prints the
last ate-controller error instead of waiting out its budget.

## Cluster creation belongs to solomog, not to the bundle

The first version of this bundle shipped its own `helpers/create-cluster-vind.sh` that called
`vcluster create` directly, because `scripts/vind-create.sh` had no way to pass a config file.
That was the wrong shape. It duplicated the existence check, the connect and the
`.solomog/clusters` bookkeeping, and — the real cost — it bypassed
`scripts/vind-create-cli.sh` entirely, so it lost the guard that refuses a name already
tracked as an EKS, vSphere or standalone target. A bundle is the escape hatch for *config*;
cluster lifecycle is solomog's job.

Replaced by a `VCLUSTER_VALUES` knob on `vind:create` (`scripts/vind-create.sh`), with the
bundle shipping `helpers/vcluster-substrate.yaml` as data rather than a parallel code path:

```bash
solomog vind:create CLUSTER=kas \
  VCLUSTER_VALUES=bundles/kagent-substrate/helpers/vcluster-substrate.yaml
```

Two properties worth keeping if this is extended. It is **create-time only** — vcluster does
not re-render an existing control plane from a config file — so an already-existing cluster
prints a warning naming the field rather than silently ignoring it. And a path that does not
resolve fails before anything is created, naming the field.

`helpers/create-cluster-kind.sh` stays a script, and that is not the same inconsistency: kind
is not a solomog cluster type at all, so it registers itself through the sanctioned
`.solomog/contexts` seam via `solomog_register_context` and is then addressed as `CLUSTER=`
like any external cluster.

## A bundle knob may not reuse a name from `.env` or `versions.env`

The root Taskfile declares `dotenv: ['.env', 'versions.env']`, so **every** key in either
file is already exported into a bundle hook's environment. A hook default written the
obvious way is therefore dead on arrival:

```bash
KAGENT_VERSION="${KAGENT_VERSION:-0.10.1}"   # resolves to 0.5.6, solomog's ENTERPRISE pin
```

and the install fails on a chart that plainly exists:

```
Error: failed to perform "FetchReference" on source:
  ghcr.io/kagent-dev/kagent/helm/kagent-crds:0.5.6: not found
```

Enterprise kagent is published from a different registry path, so the community line simply
has no 0.5.6. This is the hook-level twin of the rule in `CLAUDE.md` that a task's `env:`
default cannot override a value already in `.env`.

Bundle knobs are therefore namespaced (`SUBSTRATE_KAGENT_VERSION`, `SUBSTRATE_VERSION`,
`SUBSTRATE_WORKER_REPLICAS`, `SUBSTRATE_STATUS_PORT`, `SUBSTRATE_TEST_AGENT`), and
`20-kagent.sh` fails fast if it is handed a 0.5.x-0.9.x version rather than fetching a
nonexistent chart. Two names are shared on purpose — `KAGENT_PROVIDER` and the API keys
mean exactly the same thing to the bundle as to `solomog kagent`, so the bundle follows
them. Audit a new knob with:

```bash
grep -hE "^<VAR>=" .env.example versions.env    # any output means pick another name
```

## Smaller things worth not rediscovering

- **`spec.platform` was removed** from `SandboxAgent` in kagent 0.10.0's `v1alpha2`. It
  was required by CEL validation in 0.9.x; setting it now fails with
  `strict decoding error: unknown field "spec.platform"`. `spec.substrate` alone places
  the agent. `v1alpha2` is the only served version of the CRD at 0.10.1.
- **kagent 0.10.x takes model credentials by Secret reference only.** There is no
  `providers.<p>.apiKey` value, so `--set providers.anthropic.apiKey=…` silently sets
  nothing and the agent fails at its first turn. Create the Secret the chart's
  `apiKeySecretRef` default already names.
- **Two workers, not one.** SandboxAgent rollouts are blue-green: kagent keeps the old
  ActorTemplate serving until the new golden is Ready, so a one-worker pool has nowhere to
  bake the replacement.
- **Substrate rejects rather than queues** when the pool is full. Scope's restore queue is
  rendered from client-side retry reports, not from a substrate-side queue.
- **`kubectl scale` takes field ownership** of `WorkerPool.spec.replicas`, which scope's
  autoscaler uses. A later helm upgrade that manages the pool needs `--force-conflicts`.
- **Docker Desktop's credential helper wedges on ghcr.io.** `helm … oci://ghcr.io/…`
  stalls for minutes while `docker-credential-desktop get` never returns, blowing through
  any `--timeout`. The charts are public, so both hooks pull through an empty
  `DOCKER_CONFIG`. Opt out with `SOLOMOG_HELM_ANON=false`.
- **`kubectl api-resources` lies after a cluster rebuild.** It answers from
  `~/.kube/cache/discovery/<host>_<port>`, and a rebuilt cluster reusing the same port
  serves the previous cluster's document for minutes. Every check here uses
  `kubectl get --raw`.

## Sources

- kagent `examples/substrate-openclaw/README.md` — the canonical install, values and
  generated ActorTemplate shape.
- kagent `design/EP-XXXX-acp-integration.md` — why harness interaction on substrate is
  hard (no SSH, no exec into actors; the only path in is atenet ingress).
- `themsquared/kagent-substrate-demo`, `labs/lab1-kind-substrate.sh` — a rebuilt,
  heavily annotated install with the version archaeology this bundle's pins follow.
- `themsquared/substrate-scope` — `server.mjs` for the source selection and the endpoints
  it depends on.
- `agent-substrate/substrate` — `hack/install-ate.sh` for the CA bootstrap,
  `hack/create-kind-cluster.sh` for the cluster config,
  `manifests/ate-install/sandboxconfig-gvisor.yaml` for how runsc is obtained.
