# example bundle

A dependency-free demo of the bundle mechanics — safe to apply to any cluster. Copy it
as a starting point, then delete it (or leave it as living documentation).

Shows:
- **ordering** via zero-padded numeric prefixes (`01-` → `10-` → `20-`)
- a plain manifest (`01-namespace.yaml`, applied verbatim)
- a **templated** manifest (`10-config.yaml.tmpl`, `%%TOKEN%%` rendered before apply)
- an **executable hook** (`20-demo-secret.sh`, run — not applied — for imperative
  steps like a Secret from `.env`; skipped under `DRY_RUN=true`)

And `tests/` showcases every test feature (run with `solomog test BUNDLE=example CLUSTER=…`):
- `01-namespace.sh` — exit-code pass/fail via a `kubectl` check
- `10-substitution.sh` — `$CLUSTER`/`$GATEWAY`/`$HOST` substitution (and verifies the
  bundle's `%%TOKEN%%` templating round-trips)
- `20-secret.sh` — validating hook output
- `30-curl-pattern.sh` — the portable `curl --fail-with-body` style (self-skips here since
  the example has no endpoint; see `bundles/agw-dr/tests` for a live, no-cost curl)

```bash
solomog bundles:show BUNDLE=example
solomog apply BUNDLE=example CLUSTER=<cluster>
solomog test  BUNDLE=example CLUSTER=<cluster>
kubectl --context vcluster-docker_<cluster> get cm,secret -n solomog-example
```
