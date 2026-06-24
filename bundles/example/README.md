# example bundle

A dependency-free demo of the bundle mechanics — safe to apply to any cluster. Copy it
as a starting point, then delete it (or leave it as living documentation).

Shows:
- **ordering** via zero-padded numeric prefixes (`01-` → `10-` → `20-`)
- a plain manifest (`01-namespace.yaml`, applied verbatim)
- a **templated** manifest (`10-config.yaml.tmpl`, `%%TOKEN%%` rendered before apply)
- an **executable hook** (`20-demo-secret.sh`, run — not applied — for imperative
  steps like a Secret from `.env`; skipped under `DRY_RUN=true`)

```bash
solomog bundles:show BUNDLE=example
solomog apply BUNDLE=example CLUSTER=<cluster>
kubectl --context vcluster-docker_<cluster> get cm,secret -n solomog-example
```
