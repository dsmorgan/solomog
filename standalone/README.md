# Standalone agentgateway configs

Each directory here is one standalone agentgateway config: a single `config.yaml` in the
`LocalConfig` schema, run by `solomog standalone CONFIG=<dir>`.

Standalone agentgateway is one self-contained binary. There is no control plane, no xDS, no
CRDs, and the proxy needs no Kubernetes API access — so solomog runs it as a plain Docker
container. Nothing here touches a cluster.

```
solomog standalone:list                       # instances (name, state, config, URL) + spare configs
solomog standalone:validate CONFIG=llm        # check a config; no cluster, no license
solomog standalone CONFIG=minimal             # start it, print the URLs
solomog standalone:logs CLUSTER=minimal
solomog standalone:stop CLUSTER=minimal       # container goes; config and state stay
solomog standalone:delete CLUSTER=minimal     # the instance stops existing
```

`solomog help standalone` documents every start-time variable.

## Config vs instance

`CONFIG` picks the config directory here. `CLUSTER` names the running instance and defaults
to `CONFIG`, so you can ignore it until you want two at once:

```
solomog standalone CONFIG=minimal                    # instance "minimal"
solomog standalone CONFIG=minimal CLUSTER=scratch    # a second one, same config
```

That is the same split as the cluster tasks — `CLUSTER` is the name you invent and later
address, and `CONFIG` describes what goes in it, the way `PRODUCTS` and `EDITION` do for a
real cluster. The difference is that a standalone instance has no other flavor knobs: the
config file is the whole description. `NAME` and `INSTANCE` are accepted as aliases for
`CONFIG` and `CLUSTER`.

The second instance gets its own copy of the config at `.solomog/standalone/scratch/`, so the
two never fight over one `config.yaml` or `data.db`, and anything you change in the scratch
instance's UI stays out of the repo. Host ports are probed upward, so it lands on the next
free pair rather than colliding. Re-running an existing scratch instance resumes it; delete it
to start again from the source config.

## Stopping vs deleting

The same distinction the cluster tasks make:

| | Container | Config | State | Registry |
| --- | --- | --- | --- | --- |
| `standalone:stop` | removed | kept | kept | kept |
| `standalone:delete` | removed | kept | removed | removed |

So `stop` is a pause — re-run and you are back where you were. `delete` makes the instance
stop existing. It leaves the config under `standalone/<name>/` alone, because that is source,
not state, the same reason tearing down a cluster does not delete your helmfiles; it prints
the `rm -rf` if you want that too.

## It is a first-class target, not an island

Instances are registered, so they show up beside real clusters and obey the same verbs:

```
solomog cluster:list                    # standalone rows alongside vind / eks / vsphere
solomog cluster:show CLUSTER=<name>     # config, ports, UI URL
solomog teardown CLUSTER=<name>         # one delete for any target, whatever its type
```

They are still not clusters, though: `CONTEXT=` means nothing here, and no product, istio,
expose or bundle task can target one.

`solomog standalone:delete` is the type-specific form, matching `vind:delete` / `eks:delete` /
`vsphere:delete`. `teardown` is the type-agnostic one and handles mixed lists.

## What ships here

| Config | What it shows |
| --- | --- |
| `minimal` | One gateway with UI, LLM, and MCP all attached, none configured. Start here. |
| `llm` | Two LLM providers behind one OpenAI-compatible endpoint, keys from `.env`. |
| `mcp` | MCP federation — the gateway serves `/mcp` and `/sse` and relays to a target. |

Add your own by creating `standalone/<name>/config.yaml`, then check it with
`solomog standalone:validate CONFIG=<name>` before starting an instance from it.
`solomog standalone:import` writes one for you from a LiteLLM config.

## Bundles vs standalone

They solve different problems, so keep them apart:

- `bundles/` holds Kubernetes manifests — CRs applied to a cluster with `solomog apply`.
- `standalone/` holds `LocalConfig` files — a config file the binary reads directly.

The same feature is often expressible in both, but the schemas are not the same and neither
converts to the other. A repro that needs a cluster belongs in `bundles/`.

## Things that will bite you

**Secrets are `$VAR` references, expanded from the environment.** The gateway runs
shellexpand over the whole config file before parsing, so put the value in `.env` and write
`apiKey: $OPENAI_API_KEY` in the config. solomog finds the references and passes those
variables into the container.

**An unset `$VAR` aborts the entire config load**, and the gateway's own error does not say
which variable. `solomog standalone:validate` names it. Note this applies to the whole file,
comments included — a regex or CEL expression containing `$WORD` breaks the same way. A
trailing `$` (`^/api/v[0-9]+$`) and a doubled `$$` are both safe, and the gateway strips the
exact `# yaml-language-server: $schema` hint line before expanding, which is the one
`$`-bearing comment that is guaranteed not to matter.

**The UI is the gateway's own, in-process.** Reach it at the UI URL the task prints. It is a
different thing from the Solo Enterprise UI management chart that `solomog agentgateway:ui`
installs onto a cluster — don't conflate the two.

**Editing in the UI rewrites `config.yaml` — and DISCARDS your comments.** With
`config.storage.mode: file` (what these examples use), the config directory is mounted
read-write and your UI edits land back in the file, so they show up in `git diff`. That is
deliberate: it is how you build a config by clicking. But the writer re-emits the file from
the parsed structure, so every comment goes with it (the `# yaml-language-server: $schema`
hint is re-added; nothing else survives). Copy a documented example to a scratch name before
clicking around in it, or expect to restore it. SQLite state (`data.db*`) is gitignored.

**The UI writes a price catalog into the config dir.** Enabling LLM cost tracking downloads
`base-costs.json` (~180 KB) beside your config and adds a `config.modelCatalog` reference to
it. Both are gitignored/omitted from the committed examples because they are generated. A
config whose catalog file is missing is not fatal — the gateway warns `will load when the
files become valid`, watches the path, and serves normally — so a fresh clone works and you
just refresh the catalog in the UI when you want cost data.

**Config changes hot-reload.** The gateway watches the file, so an edit from your editor or
from the UI is live within a second or two — no restart. The log line is
`state_manager loaded config from File(...)`.

**Attach capabilities to a gateway; never give them their own `port`.** `ui`, `llm`, and
`mcp` are each either attached to a gateway (`gateways: <name>`, or omit the field and they
auto-attach to a gateway named `default`) or a listener in their own right on `<section>.port`
— and `llm` defaults to **4000**, `mcp` to **3000**. So `llm.port: 4000` alongside
`gateways.default.port: 4000` fails with `port 4000 is configured by both gateways.default and
llm; binds, llm, and mcp must use unique ports`.

That matters because **the UI's onboarding wizard writes a port instead of attaching**, so
toggling "Enable LLM" on a config whose gateway sits on 4000 fails to save. It is not
solomog's doing — the config the gateway bootstraps for itself (`gateways.default.port: 4000`)
hits it identically, verified 2026-09-01 on 2026.8.2. The examples here all declare all three
capabilities attached, so the wizard has nothing left to toggle.

If you do end up with a top-level `llm.port` or `mcp.port`, `solomog standalone` discovers and
publishes it — but only at start. A port the UI adds while the container is running is not
published yet, so the endpoint is unreachable from your Mac until you re-run
`solomog standalone CONFIG=<name>` (a restart keeps your config and state).

**No `stdio` MCP targets.** The image is distroless — no shell, no node, no `npx` — so the
gateway has nothing to exec. `--validate-only` accepts a stdio target because it only checks
the schema; the failure appears at request time. Run the MCP server on your Mac and point at
`host.docker.internal` instead.

**`host.docker.internal` reaches your Mac.** The container's own localhost is not yours.

**Version pin is `AGENTGATEWAY_STANDALONE_VERSION`**, separate from `AGENTGATEWAY_VERSION`
on purpose. Standalone landed in `2026.8.0` and has no equivalent on the older SemVer line,
so pinning `AGENTGATEWAY_VERSION` back to `v2.3.3` to mirror a customer environment must not
drag standalone back to a release where it does not exist. Note the standalone pin carries no
`v` prefix — it is an image tag, and the image line is unprefixed while the chart line is not.

**Licensing has no grace period.** Standalone needs `AGENTGATEWAY_LICENSE_KEY` in `.env` and
exits rather than starting degraded. It does not fall back to `SOLO_LICENSE_KEY`: the
standalone verifier requires a `product` claim that the generic key does not carry, so the
fallback would fail as a confusing `malformed claims` crash instead of a missing-key message.
