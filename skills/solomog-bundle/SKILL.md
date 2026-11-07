---
name: solomog-bundle
description: "How to work with solomog bundles (bundles/<name>/ or bundles/private/<name>/) — both creating one (the root/tests/docs/custref/helpers layout, public vs private) and operating an existing one (discover, apply, test, refresh credentials, export for hand-off). Load this whenever creating, restructuring, reviewing, or auditing a bundle; when deciding where a new customer repro should live; or when running/debugging apply and test against a cluster. Triggers on: 'new bundle', 'create a bundle', 'bundle layout', 'bundle structure', 'private bundle', 'customer repro', 'does this bundle comply', 'audit the bundles', 'run the bundle', 'test the bundle', 'apply the bundle', 'solomog apply/test BUNDLE='."
---

# solomog bundles

A bundle is solomog's escape hatch: a directory of manifests applied in order to a cluster with
`solomog apply BUNDLE=<name> CLUSTER=<c>`, and validated with `solomog test BUNDLE=<name> CLUSTER=<c>`.
Use one for bespoke or customer-repro config not worth generalizing into a product or app.

The repo-wide rules in solomog's `AGENTS.md` still apply (bash 3.2, `.env` hygiene, `%%TOKEN%%`
templating, no secrets in git). This skill covers what is specific to bundles: **operating** an
existing one below, then **authoring** a new one.

## Who runs the commands

**Hand `solomog` commands back to David rather than running them yourself** — apply, test,
teardown, credential refresh, anything that touches a cluster or `.env`. He is the one driving
the tool, including mid-debug. Give him the exact line to paste and say what you expect to see;
read-only inspection of repo files is yours to do freely.

## Operating an existing bundle

The normal loop is discover → make sure creds are fresh → apply → test → read the capture.

```bash
solomog bundles:list                          # every bundle, one line each (its README line 1)
solomog bundles:list FILTER=okta              # names containing a substring (case-insensitive)
solomog bundles:show BUNDLE=agw-okta-mcp      # print that bundle's whole README + apply order

solomog apply BUNDLE=<name> CLUSTER=<c>                    # apply root files in sort order
solomog apply BUNDLE=<name> CLUSTER=<c> DRY_RUN=true       # server-side validate; hooks skipped
solomog apply BUNDLES="llmroute-vertex llmroute-bbr" CLUSTER=<c>   # several, left-to-right

solomog test BUNDLE=<name> CLUSTER=<c>                     # all tests/, sorted
solomog test BUNDLE=<name> CLUSTER=<c> TESTS="54"          # ONE test — the iteration knob
solomog test BUNDLE=<name> CLUSTER=<c> TESTS="54 56"       # a few, by filename prefix
```

`BUNDLE`/`BUNDLES` and `CLUSTER`/`CLUSTERS` are interchangeable aliases; either may name several.
Bundles run left-to-right and stop on the first error. `bundles:list`/`show`/`export` need no cluster.

**`TESTS=<prefix>` is the knob to reach for when iterating.** Re-running a 20-test suite to
check one fix wastes minutes and buries the signal. A prefix matching nothing warns rather than
failing, so a typo looks like a pass — check the runner actually said it ran your test.

**Chain tasks in one call.** The wrapper runs each task as its own `task` invocation, so a whole
environment comes up in one line and dotenv is re-read between tasks:

```bash
solomog agentgateway:ui expose apply BUNDLE=<name> ROUTE=true CLUSTER=<c>
```

**Refresh short-lived credentials first, in the same chain.** `gcp:refresh` and `aws:refresh`
write only `.env`; the following `apply` is what pushes the value into the cluster secret, and it
sees the new value only because of that per-task dotenv re-read:

```bash
solomog gcp:refresh apply BUNDLE=llmroute-vertex CLUSTER=<c>     # GCP token, ~1h
solomog aws:refresh apply BUNDLE=llmroute-bedrock CLUSTER=<c>    # AWS SSO creds, <=12h
```

A backend that worked yesterday and now 401/403s is nearly always an expired token, not the
bundle. The `agentcore` CLI is the opposite posture — it runs in David's own shell, which never
reads `.env`, so it wants the SSO profile: `eval "$(solomog agentcore:env NAME=<project>)"`.

**Every test run is captured** to `.solomog/test-runs/<bundle>-<timestamp>/` (gitignored): one
`<test>.log` per test with its output and exit code, plus a `summary`. That directory is the
artifact to read when a test fails and the evidence to attach to a ticket.

**Hand-off:** `solomog export BUNDLE=<name>` writes a portable, secret-safe package to
`.solomog/exports/<bundle>-<ts>/` for someone not using solomog — declarative manifests rendered
into `manifests/`, `.sh` hooks copied to `manual-steps/` **unexecuted** and listed in the package
README, plus `env.example` and `PREREQUISITES.md`. A backstop redacts any real `.env` value that
leaked in. Cluster-free, single-bundle.

### When a test fails, rule these out before blaming the product

- **An expired credential** — see the refresh commands above.
- **The MCP SDK major.** `mcp` 2.0.0 renamed `streamablehttp_client`, so a test using bare
  `--with mcp` breaks on import with nothing in the bundle changed. Pin `--with 'mcp<2'`. The repo
  is mid-migration — `grep -rl -- "--with mcp" bundles/` finds the unpinned ones.
- **TLS against the mkcert gateway.** uv-managed Python uses certifi, not the macOS keychain, so
  HTTPS fails `CERTIFICATE_VERIFY_FAILED` without `--with truststore` plus
  `import truststore; truststore.inject_into_ssl()`.
- **A stale `AWS_CREDENTIAL_EXPIRATION` exported in the shell**, which `.env` never carries. It
  poisons otherwise-fresh creds and every AWS call reports "expired" while `.env` looks perfect.
- **The bundle was never applied to *this* cluster**, or was applied to a different one. `apply`
  is idempotent — re-running it is cheap and is the right first move.

## Authoring a bundle

### The five directories

Everything except the root is optional. **A missing subdirectory is not a defect** — add one when
it has something to hold.

| Location | Holds | Applied? |
|---|---|---|
| **root** | configure/install: the manifests and hooks that build the scenario | yes, in sort order |
| **`tests/`** | test cases that validate the bundle | no — run by `solomog test` |
| **`docs/`** | supporting documentation: demo scripts, findings, internal notes | no |
| **`custref/`** | customer-supplied config references, usually for a re-create | no |
| **`helpers/`** | scripts to log in, authenticate, prep, or change the system under test | no |

Only the root is applied. `apply-bundle.sh` lists top-level entries and keeps names ending in
`.yaml` / `.yml` / `.yaml.tmpl` / `.sh`, so subdirectories are never applied — which is what makes
`helpers/` safe to fill with scripts that must not run at apply time.

### README.md

Every bundle has one, and it is a **CLI surface, not a document** — `bundles.sh` reads it two ways:

- `solomog bundles:list` prints the **first non-blank line**, with leading `#`s stripped, as the
  bundle's one-line description.
- `solomog bundles:show BUNDLE=<name>` prints the **entire file**, indented, with no truncation.

So length is the whole constraint.

**A README is a title, a short description, and the commands to run it. Nothing else.** It is
roughly 10-20 lines, so `show` fits one screen with room to spare. Everything else goes in
`docs/` (see below), linked from the README by a single line.

**Line 1 is a heading giving the bundle's purpose in one line.** Write it to fit a `bundles:list`
row, because that is where it is read — a short noun phrase, not a sentence that wraps:

```markdown
# agw-okta-mcp — Okta edge JWT + OBO impersonation to an MCP backend
```

**The rest is exactly three things, in order:**

1. **A high-level description**: two to four sentences saying what the bundle demonstrates or
   reproduces and the one prerequisite a reader must know (for example "needs `OPENAI_API_KEY`
   in `.env` for the real leg").
2. **A sample command block** to apply and test it, as `solomog` commands to copy, with any
   variable the bundle needs named on the command line.
3. **One pointer line** to the docs page, such as `Status, tests, gotchas: [docs/details.md](docs/details.md).`

**What goes in `docs/` (a `details.md`, or several pages for a big bundle):** the status table
(covers · needs · versions · clash-safe · verified), the file-by-file and test-by-test
reference, findings and their evidence, demo run sheets, source citations, defect write-ups,
gotchas, and history. If it explains *why* or *what else*, rather than how to get running, it is
a `docs/` page. Do not grow the README back; add to `docs/`.

For a private bundle, put a short **Naming** table in `docs/` (not the README) stating that only
the directory carries the customer name, so a later edit does not quietly reintroduce a customer
prefix.

#### Root

- **Numbered, zero-padded prefixes** (`01-`, `10-`, `20-`), sorted `LC_ALL=C`. Padding is what
  keeps `2` from sorting after `10`. Leave gaps to insert later.
- `.yaml` applies verbatim; `.yaml.tmpl` is rendered first (`%%CLUSTER%%`, `%%GATEWAY%%`,
  `%%HOST%%`). A file using a token **must** carry the `.tmpl` extension, and a leftover
  `%%TOKEN%%` is a hard error — so never write a literal `%%WORD%%` in a `.tmpl`, comments included.
- A `.sh` file at the root is a **hook**: run, not applied, at its sorted position. Hooks are the
  place to create Secrets from `.env`, so the value stays in `.env` and the file stays committable.
  Hooks get `CONTEXT` / `CLUSTER` / `GATEWAY` / `HOST` / `SOLOMOG_LIB`, run with cwd = the bundle
  directory, and are skipped under `DRY_RUN`.

#### tests/

A test is just the commands; the runner judges pass/fail by exit code. Tests get
`CONTEXT` / `CLUSTER` / `GATEWAY` / `HOST` plus `.env`, so use plain `$HOST` — no `%%TOKEN%%`.

Three habits that pay for themselves:

- **Self-skip, don't fail, on a missing credential.** `exit 0` with a line saying which one and how
  to get it. One absent provider should not stop the other legs.
- **Assert the thing, not the status code.** HTTP 200 proves the request was accepted, not that it
  did what you claim. Assert a canary string that can only come from the path under test.
- **Print how to read a failure.** A test that says "✗ FAIL" costs a debugging session; one that
  says "403 + `aws-marketplace:Subscribe` means no Marketplace subscription" costs a minute.

Order tests so the cheap control runs first: preflight (versions, credentials, object status), then
a minimal known-good path, then the real assertions. A failure in the control is what stops you
reading an environment problem as a product defect.

**Number tests so prefixes are useful.** `TESTS=<prefix>` selects by filename prefix, so a
two-digit padded number plus a specific name (`54-cid-composite.sh`) gives a stable handle to
re-run one test. Leave gaps, as in the root.

**Python tests are a `.sh` that shells out** — the runner only globs `*.sh`. Use
`uv run --with <dep> --python 3.x` (never `pip install`; system Python is PEP 668
externally-managed). Two flags to write in from the start:

```bash
uv run --with 'mcp<2' --with truststore --python 3.12 - <<'PY'
import truststore; truststore.inject_into_ssl()   # mkcert CA lives in the OS trust store
PY
```

`mcp<2` because 2.0.0 renamed `streamablehttp_client`; `truststore` because uv's Python trusts
certifi, not the macOS keychain, so the mkcert gateway otherwise fails `CERTIFICATE_VERIFY_FAILED`.

#### helpers/

Scripts here are run **by hand**, so assume nothing has sourced `.env`. Only go-task's dotenv and
bundle hooks get it — `bash helpers/foo.sh` does not, which makes a freshly refreshed credential
look absent. Load through solomog's own helper rather than reading `.env`:

```bash
. "$SOLOMOG_LIB/target.sh"     # or walk up for scripts/lib/target.sh when run standalone
solomog_aws_preflight "helpers/foo.sh"
```

`solomog_aws_env_load` also unsets `AWS_CREDENTIAL_EXPIRATION`, which `.env` never carries — a
stale one left in the shell poisons otherwise-fresh creds and every AWS call fails as "expired"
while `.env` looks perfect.

Helpers that mutate anything outside the cluster (creating a cloud bucket, registering an IdP app)
should **do one thing, idempotently, and stop**. Don't guess retention, lifecycle, or policy for
someone else's account.

#### Reserved name

`agentcore/` is functional, not decorative: `solomog agentcore:list` / `:env` / `:shell` discover
projects with `find bundles -name agentcore.json -path '*/agentcore/*'`. A bundle holding an AWS
AgentCore project must use that directory name. It is a legitimate exception to the five above.

## Public or private

`bundles/<name>/` is committed to the public solomog repo. `bundles/private/<name>/` is gitignored
there and is its own nested checkout (`dsmorgan/solomog-private`). A private bundle **overrides** a
public one of the same name.

Go **private** if any of these is true:

- it is tied to a named customer, engagement, or ticket
- it carries `custref/` — customer-supplied configuration
- it reproduces one customer's specific issue rather than a product behavior
- its notes quote customer environments, names, or internal findings

Otherwise go **public**: a generic capability demo, a product behavior worth keeping, a reusable
routing or policy pattern.

Neither may contain secrets. Values live in the root `.env`; hooks inject them.

### Working in the private repo

- Run `git` from **inside** `bundles/private/` — from the solomog root it targets the wrong repo
  and these files never appear in `git status`.
- Check the branch before committing; it is often on a bundle feature branch, not `main`.
- Commit messages are `<bundle-short-name>: <lowercase summary>`.
- New bundles land untracked. Mention that so David can commit; don't commit unasked.

### Naming inside a private bundle

**Only the directory may carry the customer name.** Every identifier inside it — object names,
namespaces, route paths, env-var prefixes, IdP app names, synthetic hostnames — is derived from the
*technology*, so the bundle lifts to a reusable one by renaming one directory and nothing else.

Not violations, so don't over-correct: cross-references to sibling bundle *directory* names (those
are real paths), and neutral sample business domains. Synthetic hostnames use `.test`, never
`.local`.

State the convention in the bundle's docs (`docs/details.md`) as a short "Naming" table, so a later edit does not
quietly reintroduce a customer prefix.
