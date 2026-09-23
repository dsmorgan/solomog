# kagent-substrate — kagent SandboxAgents on Agent Substrate, watched with substrate-scope

Agents as snapshot-backed actors in gVisor sandboxes instead of always-on pods. kagent
bakes a golden snapshot per `SandboxAgent`; substrate restores it onto a pre-warmed
worker for each turn and checkpoints it back to object storage. `substrate-scope` is the
visualizer that makes that visible.

**Substrate needs more from the cluster than vind gives by default:** three alpha feature
gates, `certificates.k8s.io/v1beta1`, a non-loopback `jwks_uri`, and a node that can run
gVisor. The first three are a `VCLUSTER_VALUES` file passed to `vind:create`; the last is
still unproven on vind.

## Deploy

```bash
# Cluster, platform and agents in one chain, with the pins spelled out. The whole
# demo from nothing in about 2.5 minutes. The pins are also the committed defaults,
# so you can drop the two env vars unless someone has changed them.
SUBSTRATE_KAGENT_VERSION=0.10.1 SUBSTRATE_VERSION=0.0.9 \
solomog vind:create apply test CLUSTER=kas BUNDLE=kagent-substrate \
  VCLUSTER_VALUES=bundles/kagent-substrate/helpers/vcluster-substrate.yaml

# Or step by step, which is what you want while iterating:
solomog vind:create CLUSTER=kas \
  VCLUSTER_VALUES=bundles/kagent-substrate/helpers/vcluster-substrate.yaml
SUBSTRATE_KAGENT_VERSION=0.10.1 SUBSTRATE_VERSION=0.0.9 \
  solomog apply BUNDLE=kagent-substrate CLUSTER=kas
solomog test BUNDLE=kagent-substrate CLUSTER=kas TESTS=60   # one test, by prefix

# If vind cannot run gVisor on your machine, swap the first step for kind:
bash bundles/kagent-substrate/helpers/create-cluster-kind.sh kas

# Watch it. scope is cloned on demand into .solomog/ and pinned; nothing to install.
bash bundles/kagent-substrate/helpers/scope.sh kas     # http://localhost:8123
bash bundles/kagent-substrate/helpers/scope.sh kas --stimulate   # drive traffic
SCOPE_REF=main bash bundles/kagent-substrate/helpers/scope.sh kas   # try a newer scope
```

## Facts

| | |
|---|---|
| covers | SandboxAgent lifecycle, golden snapshots, suspend/restore, WorkerPool scaling, substrate-scope live mode |
| needs | a key for whatever `KAGENT_PROVIDER` says in `.env` — `OPENAI_API_KEY` by default, `CLAUDE_API_KEY` for anthropic, neither for ollama; node ≥18 for scope; ~570MB of image pulls |
| versions | substrate **0.0.9** (`SUBSTRATE_VERSION`), kagent **0.10.1** (`SUBSTRATE_KAGENT_VERSION`), scope **5d27549** (`SCOPE_REF`). A matched pair, see below |
| clash-safe | no. Owns `ate-system` and `kagent`, and the cluster itself is single-purpose |
| verified | vind 2026-09-18: 6/6 from a fresh cluster, chained, 2m25s (warm image cache). See `docs/findings.md` |

**The pins are not "latest" on purpose.** kagent 0.10.1 vendors substrate 0.0.9, which is
the only recent pairing that installs with helm alone. Substrate 0.0.13+ needs an
out-of-band `kubectl ate admin make-ca-pool` bootstrap, and kagent 1.0.0-alpha1 removed the
`/api/substrate/status` endpoint that substrate-scope's high-fidelity mode polls — on
latest, scope degrades to CRD-only. Override by exporting `SUBSTRATE_VERSION` /
`SUBSTRATE_KAGENT_VERSION` if you want to retest that — **not** `KAGENT_VERSION`, which is
solomog's own enterprise pin and already sits in every hook's environment via
`dotenv: ['.env', 'versions.env']`. Export them as a command prefix, not as `KEY=` arguments:
the wrapper rejects `KEY=` names it does not know. `docs/upgrade-analysis-kagent-1.0.md` is
why the pins are where they are.

**agentgateway is already here.** Substrate's `atenet-router` runs agentgateway
(`--networking-mode=agentgateway`) as the actor dataplane — every request to an actor goes
through it. A *Solo-configured* agentgateway in front of kagent (LLM routing, MCP) is a
separate bundle, not this one.

## Layout

- `00-preflight.sh` — refuses to install onto a cluster that cannot run substrate
- `10-substrate.sh` — substrate-crds + substrate into `ate-system`, gated on valkey health
- `20-kagent.sh` — kagent with `controller.substrate.enabled` and a WorkerPool
- `30-sandboxagents.yaml` — a small fleet, so scope has more than one chip to move
- `helpers/vcluster-substrate.yaml` — the `VCLUSTER_VALUES` file for `vind:create`
- `helpers/` — the kind fallback and the scope runner, both run by hand
- `docs/kagent-substrate-architecture-v0.1.html` / `.pdf` — internal architecture and demo deck
- `docs/findings.md` — version-pairing evidence and every gotcha with its verbatim error
- `docs/upgrade-analysis-kagent-1.0.md` — what a move to kagent 1.0.0-alpha1 would cost
- `docs/demo-runsheet.md` — what to click and say when showing this to someone
