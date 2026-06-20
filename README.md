# solomog

Quickly stand up local vcluster (vind) Kubernetes environments with Solo.io
products and sample apps installed — so you can get to the work that matters.

## Setup

```bash
cp .env.example .env      # add your license key(s)
task setup                # installs prereqs (task, helmfile, helm, jq, step), links `solomog`
solomog                   # list all scenarios
```

## Concepts

- **Products** are composable helmfile modules in [helmfiles/products/](helmfiles/products/):
  `istio`, `gloo-mesh`, `kgateway`, `agentgateway`. Add a new one by dropping in
  a module and appending it to `CANONICAL_ORDER` in [scripts/stack.sh](scripts/stack.sh).
- **Editions** are a helmfile environment dimension: `EDITION=enterprise` (default)
  or `EDITION=community`. Switches chart repos and license handling.
- **Istio mode** is `ISTIO_MODE=ambient` (default) or `sidecar`.

## Single cluster — compose any products

```bash
# General-purpose: any combination on one cluster, installed in dependency order
solomog stack CLUSTER=cluster-one PRODUCTS="istio kgateway agentgateway"
solomog stack PRODUCTS="istio gloo-mesh" ISTIO_MODE=sidecar

# Shortcuts
solomog istio:ambient:single
solomog istio:sidecar:single
solomog gloo-mesh:single                 # istio + Gloo Mesh mgmt plane
solomog kgateway
solomog kgateway:with-istio
solomog agentgateway

# Community editions (no license key needed)
solomog kgateway EDITION=community
```

## Multi-cluster Istio

```bash
solomog istio:ambient:multi-flat         # 2 clusters, flat network
solomog istio:ambient:multi-gateway      # 2 clusters, east-west gateways
solomog istio:ambient:multi-3            # 3 clusters (supports mixed versions)
```

## License keys

Set keys in `.env`. Use one key for everything, or map a specific key per product:

```bash
SOLO_LICENSE_KEY=...              # fallback for any product without its own key
GLOO_MESH_LICENSE_KEY=...         # overrides the fallback for Gloo Mesh
GLOO_GATEWAY_LICENSE_KEY=...      # overrides for kgateway/Gloo Gateway
AGENTGATEWAY_LICENSE_KEY=...      # overrides for agentgateway
```

A product-specific key always wins; otherwise the product falls back to
`SOLO_LICENSE_KEY`. Resolution lives in
[helmfiles/environments/default.yaml](helmfiles/environments/default.yaml).

## Sample apps

```bash
solomog apps:bookinfo CONTEXT=vcluster.cluster-one
solomog apps:online-boutique
solomog apps:utils                       # httpbin, curl, netshoot
```

## Versions & teardown

```bash
solomog versions:show
solomog versions:update                  # check GitHub, optionally bump versions.env
solomog teardown                         # prompts before destroying all clusters
solomog teardown:cluster CLUSTER=cluster-one
```
