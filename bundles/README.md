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

## Notes

- **Idempotent.** `kubectl apply` is declarative — re-running a bundle is safe.
- **No prune.** Deleting a file from a bundle does *not* delete the resource (auto-prune
  is too easy to misfire). Tear down by destroying the cluster, or `kubectl delete` by hand.
- **`DRY_RUN=true`** does a server-side dry-run — real API validation, nothing written.
  It needs a live cluster (bespoke YAML can't be meaningfully linted offline).
