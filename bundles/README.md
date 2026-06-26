# Custom config bundles

A **bundle** is a directory of bespoke Kubernetes manifests applied to a cluster in
order — the escape hatch for customer-repro / one-off config that isn't worth
generalizing into a product or app module.

```bash
solomog bundles:list                              # what's available
solomog bundles:show BUNDLE=example               # files in apply order
solomog apply BUNDLE=example CLUSTER=aaa           # apply it
solomog apply BUNDLE=example CLUSTER=aaa DRY_RUN=true   # validate only (server-side)

# recreate a whole customer env in one chained call:
solomog agentgateway:ui expose apply BUNDLE=acme ROUTE=true CLUSTER=aaa
```

## Layout (hybrid: committed + private)

```
bundles/
  <name>/            # committed — shareable, versioned with the repo
    01-namespace.yaml
    10-route.yaml.tmpl
    README.md        # optional: what this recreates, prerequisites
  private/
    <name>/          # GITIGNORED — sensitive/customer-specific config
```

Put anything sensitive (internal hostnames, real secrets, customer specifics) under
`bundles/private/<name>/` — that path is gitignored and never committed. A private
bundle of the same name overrides a committed one.

## Ordering

Files are applied in `LC_ALL=C` (byte) sorted order. Prefix with a **zero-padded
two-digit number** to sequence them:

```
01-namespace.yaml
10-secret.yaml
20-httproute.yaml
30-trafficpolicy.yaml
```

Zero-padding matters: byte sort puts `2` after `10`, but `02` before `10`. Leave gaps
(10/20/30) so you can insert files later without renumbering. Sequence dependencies
yourself — e.g. a CRD (or the product that owns it) must be applied before any custom
resource that uses it. Applying a CR before its CRD exists fails fast (stop-on-error);
fix the order and re-run.

## Templating (optional, per file)

A file ending in **`.yaml.tmpl`** is rendered before apply; plain `.yaml` is applied
verbatim. Templating uses `%%TOKEN%%` placeholders (not `$VAR`) so it can never clash
with a `$` that legitimately appears in a manifest, and needs no extra tooling.

Supported tokens:

| Token | Value | Default |
|---|---|---|
| `%%CLUSTER%%` | bare cluster name | from `CLUSTER=` |
| `%%GATEWAY%%` | gateway name | `agw` (override `GATEWAY=`) |
| `%%HOST%%` | gateway host | `<GATEWAY>.<CLUSTER>.test` (override `HOST=`) |

Any unrecognized `%%FOO%%` left after rendering is a hard error (catches typos). The
check scans the whole rendered file **including comments**, so don't write a literal
`%%WORD%%` in a `.tmpl` unless it's a real token. Need another variable? Add it to the
`render()` allow-list in [../scripts/apply-bundle.sh](../scripts/apply-bundle.sh).

## Executable hooks (`.sh`) — for secrets & imperative steps

A file ending in **`.sh`** is *run* (not applied) at its place in the sorted order.
This is the escape hatch for things that don't fit declarative YAML — most commonly a
**Secret built from a credential in `.env`**:

```bash
# bundles/<name>/05-anthropic-secret.sh
kubectl --context "$CONTEXT" create secret generic anthropic-secret -n agentgateway-system \
  --from-literal="Authorization=$CLAUDE_API_KEY" \
  --dry-run=client -o yaml | kubectl --context "$CONTEXT" apply -f -
```

The pattern for secrets:
1. Put the **value** in `.env` (`CLAUDE_API_KEY=…`) — gitignored, auto-sourced by Taskfile.
2. Reference it as `$CLAUDE_API_KEY` in the hook. The hook carries **no secret**, so it's
   safe to commit; only `.env` stays private.

Hooks inherit the full environment (so `.env` values are present) plus `CONTEXT`,
`CLUSTER`, `GATEWAY`, `HOST`, and run with cwd = the bundle dir. Use `$CONTEXT` to target
the right cluster. Hooks are **skipped under `DRY_RUN=true`** (an arbitrary script can't be
assumed side-effect free). They stop the bundle on non-zero exit, like any other step.

## Copying manifests from Solo docs/workshops

Solo docs present manifests wrapped in a shell heredoc:

```bash
kubectl apply -f - <<EOF
apiVersion: ...
EOF
```

A bundle `.yaml` is applied directly (`kubectl apply -f <file>`), so paste **only the
manifest** — strip the `kubectl apply -f - <<EOF` opener and the closing `EOF`. Leaving
the wrapper in produces `error converting YAML to JSON: ... mapping values are not
allowed in this context` (the parser treats the `kubectl …` line as YAML). The heredoc
form belongs in a `.sh` hook, not a `.yaml`.

## Testing a bundle

A bundle can carry tests in a `tests/` subdir — `*.sh` files run in `LC_ALL=C` order by
`solomog test`. **A test is just the command(s) you'd run or hand a customer** — there's no
required format or assertion scaffolding. The runner runs the file and judges pass/fail by
its **exit code**, and it exports `CONTEXT` / `CLUSTER` / `GATEWAY` / `HOST` plus everything
from `.env`, so you substitute with plain shell vars (the most portable form — a customer
just `export HOST=…` and pastes the curl).

A whole test file can be one curl:

```bash
# bundles/<name>/tests/10-anthropic.sh
# --fail-with-body → HTTP >=400 exits non-zero (test fails) but still prints the body.
curl --fail-with-body -sS https://$HOST/anthropic \
  -H 'content-type: application/json' \
  -d '{"model":"claude","messages":[{"role":"user","content":"Reply with: ok"}]}'
```

- **Pass/fail = exit code.** Add `curl --fail-with-body` (curl ≥7.76) when you want an HTTP
  ≥400 to count as a failure; omit it and the curl is simply captured (always "ran").
- **Substitution = shell vars.** `$HOST` (= `<GATEWAY>.<CLUSTER>.test`), `$CLUSTER`,
  `$CONTEXT`, `$GATEWAY`, and any `.env` var. No custom `%%TOKEN%%` here — keeping the
  commands verbatim-runnable is the point.
- **kubectl checks** are fine too (see `01-routes-programmed.sh`); a local assertion just
  needs a bit of shell logic. Curl smoke tests stay one-liners.

```bash
solomog test BUNDLE=<name> CLUSTER=aaa
```

The runner reports pass/fail per test plus totals, exits non-zero if any failed, and
**captures every run** to `.solomog/test-runs/<name>-<timestamp>/` (gitignored): a `<test>.log`
per test (output + exit code) and a `summary` — the record of what you validated, to attach
to a ticket or diff over time. The `tests/` subdir is ignored by `apply` (it only globs files
in the bundle root), so apply and test stay separate.

## Short-lived credentials (GCP / Vertex)

GCP access tokens expire (~1h), so a Vertex bundle's token goes stale. Refresh it with:

```bash
solomog gcp:refresh                                   # re-fetch GCP_ACCESS_TOKEN into .env
solomog gcp:refresh apply BUNDLE=<vertex> CLUSTER=aaa  # refresh, then re-apply so the hook picks it up
```

`gcp:refresh` only updates `.env`; re-applying the bundle pushes it into the cluster secret.
This sequencing works because solomog runs each task as its own `task` invocation, so `apply`
re-reads `.env` after `gcp:refresh` rewrote it. The token is short-lived (~1h) — re-run this
manually when a GCP-backed backend starts returning 401.

## Notes

- **Idempotent.** `kubectl apply` is declarative — re-running a bundle is safe.
- **No prune.** Deleting a file from a bundle does *not* delete the resource (auto-prune
  is too easy to misfire). Tear down by destroying the cluster, or `kubectl delete` by hand.
- **`DRY_RUN=true`** does a server-side dry-run — real API validation, nothing written.
  It needs a live cluster (bespoke YAML can't be meaningfully linted offline).
