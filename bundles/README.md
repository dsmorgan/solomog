# Custom config bundles

A **bundle** is a directory of bespoke Kubernetes manifests applied to a cluster in
order — the escape hatch for customer-repro / one-off config that isn't worth
generalizing into a product or app module.

```bash
solomog bundles:list                              # what's available
solomog bundles:list FILTER=example               # names containing a substring
solomog bundles:show BUNDLE=example               # files in apply order
solomog apply BUNDLE=example CLUSTER=aaa           # apply it
solomog apply BUNDLE=example CLUSTER=aaa DRY_RUN=true   # validate only (server-side)

# recreate a whole customer env in one chained call:
solomog agentgateway:ui expose apply BUNDLE=acme ROUTE=true CLUSTER=aaa
```

## Layout

```
bundles/
  <name>/                  # committed — shareable, versioned with the repo
    README.md              # required — see below
    01-namespace.yaml      # root = configure/install, applied in order
    10-route.yaml.tmpl
    tests/                 # test cases that validate the bundle
    docs/                  # supporting documentation
    custref/               # customer-supplied config references (for re-creates)
    helpers/               # scripts to log in, authenticate, prep, or change the SUT
  private/
    <name>/                # GITIGNORED — sensitive/customer-specific config
```

Every subdirectory is optional; a bundle with only a root and `tests/` is normal. Add one when
you have something to put in it.

**Only the root is applied.** `apply-bundle.sh` lists the bundle's top-level entries and keeps
names ending in `.yaml` / `.yml` / `.yaml.tmpl` / `.sh` — a directory never matches, so nothing
under `tests/`, `docs/`, `custref/`, or `helpers/` is ever applied. That is what makes `helpers/`
safe for scripts that must not run at apply time.

`agentcore/` is a reserved sixth name: `solomog agentcore:list` / `:env` / `:shell` discover
projects with `find bundles -name agentcore.json -path '*/agentcore/*'`, so a bundle holding an
AWS AgentCore project must use exactly that directory name.

### Committed or private

Put anything sensitive (internal hostnames, real secrets, customer specifics) under
`bundles/private/<name>/` — that path is gitignored and never committed here. A private
bundle of the same name overrides a committed one.

Go **private** when the bundle is tied to a named customer, engagement, or ticket; carries
`custref/`; reproduces one customer's specific issue rather than a product behavior; or quotes
customer environments and internal findings. Otherwise commit it: generic capability demos,
product behaviors worth keeping, reusable routing or policy patterns.

Neither kind may contain secrets — values live in `.env` and hooks inject them (see below).

In a private bundle, **only the directory carries the customer name**. Object names, namespaces,
route paths, env-var prefixes and synthetic hostnames are all derived from the *technology*, so
the bundle lifts to a reusable one by renaming one directory and nothing else.

### README.md

Required, and it is a **CLI surface rather than a document**:

- `solomog bundles:list` prints the **first non-blank line**, leading `#`s stripped, as the
  bundle's description.
- `solomog bundles:show BUNDLE=<name>` prints the **whole file**, indented, untruncated.

So:

1. **Keep it to about a screen — roughly 60 lines.** `show` dumps all of it, and a README that
   scrolls is one nobody reads. Detail goes in `docs/`, linked from the README.
2. **Line 1 is a heading describing the bundle in one line**, written to fit a `bundles:list`
   row — a short noun phrase, not a sentence that wraps.
3. **The rest covers**, in order: how to deploy and test it as `solomog` commands to copy; the
   few dependency facts worth knowing (credentials needed in `.env`, product version floor,
   whether it is clash-safe alongside other bundles); and pointers to fuller detail in `docs/`.

A compact status table (covers · needs · versions · clash-safe · verified) carries most of item 3
in a few lines. Findings, evidence, run sheets and per-test rationale belong in `docs/`.

```markdown
# agw-okta-mcp — Okta edge JWT + OBO impersonation to an MCP backend
```

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
| `%%BEDROCK_GUARDRAIL_ID%%` | AWS Bedrock guardrail id | `BEDROCK_GUARDRAIL_ID` in `.env` — no default |
| `%%BEDROCK_GUARDRAIL_VERSION%%` | its version, or `DRAFT` | `BEDROCK_GUARDRAIL_VERSION` in `.env` — no default |

The first three always have a value. The `.env`-sourced ones are substituted **only when
non-empty**: an unset var leaves the literal `%%TOKEN%%` in place so it trips the leftover-token
error below, rather than rendering an empty value that the CRD rejects for a less obvious reason.
Most bundles reference neither and are unaffected.

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
- **Python tests are a `.sh` that shells out** — the runner only globs `*.sh`. Use
  `uv run --with <dep> --python 3.x`, not `pip install` (system Python is PEP 668
  externally-managed). Write two flags in from the start: **`--with 'mcp<2'`** (mcp 2.0.0 renamed
  `streamablehttp_client`, so an unpinned test breaks on import one day with nothing changed) and
  **`--with truststore`** plus `import truststore; truststore.inject_into_ssl()` (uv's Python
  trusts certifi, not the macOS keychain, so the mkcert gateway otherwise fails
  `CERTIFICATE_VERIFY_FAILED`). See `bundles/mcp-in-cluster/tests/`.

```bash
solomog test BUNDLE=<name> CLUSTER=aaa              # every test, in order
solomog test BUNDLE=<name> CLUSTER=aaa TESTS="54"   # just the tests whose name starts with 54
solomog test BUNDLE=<name> CLUSTER=aaa TESTS="54 56"
```

`TESTS=` takes space-separated filename **prefixes** — the knob for iterating on one test instead
of re-running the suite. A prefix that matches nothing warns and keeps going, so a typo reads as a
clean run; check the runner reported the test you meant. Number tests with a padded two-digit
prefix (`54-cid-composite.sh`) to keep those handles stable.

The runner reports pass/fail per test plus totals, exits non-zero if any failed, and
**captures every run** to `.solomog/test-runs/<name>-<timestamp>/` (gitignored): a `<test>.log`
per test (output + exit code) and a `summary` — the record of what you validated, to attach
to a ticket or diff over time. `apply` only globs files in the bundle root, so `tests/` — like
every other subdirectory — is never applied, and apply and test stay separate.

Three habits worth keeping:

- **Self-skip rather than fail on a missing credential.** `exit 0` with a line naming which one
  and how to get it; one absent provider shouldn't stop the other legs.
- **Assert the thing, not the status code.** HTTP 200 proves the request was accepted, not that
  it did what you claim — assert a value that can only come from the path under test.
- **Print how to read a failure.** A test that says `✗ FAIL` costs a debugging session; one that
  says what a given error message actually means costs a minute.

Order tests cheap-first: preflight (versions, credentials, object status), then a minimal
known-good path, then the real assertions. A failure in the control is what stops you reading an
environment problem as a product defect.

## Helper scripts (`helpers/`)

Scripts here are run **by hand**, so assume nothing has sourced `.env`. Only go-task's dotenv and
bundle hooks get it — `bash helpers/foo.sh` does not, which makes a freshly refreshed credential
look absent. Load through solomog's own helper rather than reading `.env` yourself:

```bash
. "$SOLOMOG_LIB/target.sh"     # or walk up for scripts/lib/target.sh when run standalone
solomog_aws_preflight "helpers/foo.sh"
```

`solomog_aws_env_load` also unsets `AWS_CREDENTIAL_EXPIRATION`, which `.env` never carries — a
stale one left in the shell poisons otherwise-fresh creds and every AWS call fails as "expired"
while `.env` looks perfect.

A helper that mutates something outside the cluster (creating a cloud bucket, registering an IdP
app) should do one thing, idempotently, and stop. Don't guess retention, lifecycle or policy for
someone else's account.

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
