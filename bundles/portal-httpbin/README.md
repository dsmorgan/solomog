# portal-httpbin

Demo of Solo Portal with kgateway: exposes the Solo docs frontend + httpbin as an
ApiProduct in the portal catalog. Mirrors
[Get started with portal](https://docs.solo.io/kgateway/2.3.x/portal/setup/).

## Prerequisites

```bash
solomog kgateway portal expose PRODUCT=kgateway CLUSTER=<cluster>
# PORTAL_LICENSE_KEY (or SOLO_LICENSE_KEY) in .env
```

Uses the starter `Portal` / `PortalParameters` that `solomog portal` already
applied in `portal-system`. Routes attach to the kgateway Gateway from `expose`
(default name `kgw` in `kgateway-system`).

If the cluster also has agentgateway, force the gateway:

```bash
solomog apply BUNDLE=portal-httpbin CLUSTER=<cluster> GATEWAY=kgw
```

## What it applies

| File | Purpose |
|------|---------|
| `10-httpbin.yaml` | go-httpbin workload in `portal-system` |
| `20-frontend.yaml.tmpl` | Solo demo portal UI (`VITE_PORTAL_SERVER_URL` → `https://portal.<HOST>/v1`) |
| `30-routes.yaml.tmpl` | HTTPRoutes: `/v1/` → portal backend, `/` → UI on `portal.<HOST>`; `/httpbin` → httpbin on `api.<HOST>` |
| `40-apidoc.yaml` / `50-apiproduct.yaml` | OpenAPI + ApiProduct for httpbin |
| `60-portal.yaml` | Adds the ApiProduct to `my-portal` |
| `70-hosts.sh` | `/etc/hosts` lines for `portal.<HOST>` and `api.<HOST>` (sudo; no-op if Gateway has no address yet) |

Hosts nest under expose’s wildcard cert (`*.kgw.<cluster>.test`), so TLS is free.
`expose` also backfills those sub-hosts if you re-run it after apply.

## Apply

```bash
solomog apply BUNDLE=portal-httpbin CLUSTER=<cluster>
# or one shot (expose before apply so the Gateway exists for 70-hosts.sh):
solomog kgateway portal expose apply BUNDLE=portal-httpbin PRODUCT=kgateway CLUSTER=<cluster>

open https://portal.kgw.<cluster>.test/     # catalog UI (Login without OIDC → expected error)
curl -sS https://api.kgw.<cluster>.test/httpbin/get
solomog test BUNDLE=portal-httpbin CLUSTER=<cluster>
```
