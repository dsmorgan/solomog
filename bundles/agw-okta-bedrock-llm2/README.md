# agw-okta-bedrock-llm2 — one endpoint, tier chosen by Okta group

A variant of [`agw-okta-bedrock-llm`](../agw-okta-bedrock-llm/) that answers the question raised
in that bundle's Lab 6: *can the gateway discover a user's group and route accordingly, instead
of making the user know their tier and pick a path?*

**Bundle 1 (per-path):** the user must call `/bedrock/standard` or `/bedrock/premium` — they have
to know their entitlement and choose the right URL.

**Bundle 2 (this one, claim-routed):** everyone calls **one path, `/bedrock`**. A `PreRouting`
transformation reads the Okta `groups` claim and sets an `x-llm-tier` header *before* route
selection; two HTTPRoutes on `/bedrock` match that header and send the caller to the tier they're
entitled to. The user never knows or picks a tier.

```
                         ┌─ PreRouting policy (on the Gateway) ──────────────┐
POST /bedrock  ──JWT──▶  │ validate Okta JWT (Strict)                        │
  Authorization: Bearer  │ set x-llm-tier = premium | standard | none  (CEL) │
                         └───────────────────────┬───────────────────────────┘
                                                 ▼  (header set, THEN route match)
               x-llm-tier: premium ─▶ HTTPRoute bedrock-premium  ─▶ Sonnet backend
               x-llm-tier: standard ─▶ HTTPRoute bedrock-standard ─▶ Haiku backend
               x-llm-tier: none ─────▶ (no matching route) ───────▶ 404  = deny
```

Precedence: **premium beats standard** (in both → premium). Neither group → `none` → no route →
404. That 404 is the "deny if neither" — no fallback route is defined on purpose.

## What's reused vs new (vs bundle 1)

Reused **verbatim**, so the two bundles share external setup:
- Okta config (App E device-flow app, `groups` claim, `llm-standard`/`llm-premium` groups) —
  [`OKTA-SETUP.md`](OKTA-SETUP.md), same `.env` (`OKTA_DOMAIN`/`OKTA_AUDIENCE`/`OKTA_DEVICE_CLIENT_ID`).
- Bedrock backends + secret: `01-bedrock-secret.sh`, `10-bedrock-standard-backend.yaml` (Haiku),
  `11-bedrock-premium-backend.yaml` (Sonnet). Each **pins its model**, so the served model reflects
  the tier regardless of what the client requested.
- Token helpers: `helpers/okta-device-login.sh`, `helpers/ag-token.sh`.

New / changed:
- `20-bedrock-routes.yaml` — two HTTPRoutes on the single `/bedrock` path, header-matched.
- `50-okta-tier-routing.sh` — the `PreRouting` JWT + claim→`x-llm-tier` transformation, plus the
  premium rate-limit. (Replaces bundle 1's per-route JWT/authz policies.)
- `tests/` — `10-unauth-401`, `20-tier-routing` (core: same path, asserts the served model matches
  the token's tier), `30-no-group-denied`, `40-ratelimit-premium`.

## Status

**Built, NOT yet run — to be validated e2e on a fresh cluster.** The pattern is adapted from the
workshop lab `security/jwt-auth-with-rbac.md` ("Claims Based Routing using JWT Auth and
Transformations"), which proves PreRouting claim→header→route. Unknowns to confirm live (see the
header of `50-okta-tier-routing.sh`):
1. `transformation.request.set` `value` accepts a **CEL ternary** + `has()`/`in` over `jwt.groups`
   (the workshop only shows simple `jwt['team']` and `default(json(...))` values).
2. `PreRouting` fires before route match for a **Gateway-targeted** policy on this CalVer build.
3. Each pinned backend forces its model, so the served model reflects the tier (checked by `20-`).

## Install (fresh cluster, e2e)

```
solomog agentgateway expose CLUSTER=<name>
solomog aws:refresh
solomog apply BUNDLE=agw-okta-bedrock-llm2 CLUSTER=<name>
bash bundles/agw-okta-bedrock-llm2/helpers/okta-device-login.sh   # cache a token
solomog test BUNDLE=agw-okta-bedrock-llm2 CLUSTER=<name>
```

⚠️ The `PreRouting` JWT policy targets the **Gateway**, so it applies to *every* route on that
gateway — use a cluster dedicated to this bundle (don't co-locate with routes that shouldn't
require the Okta JWT).

## Prerequisites

Same as bundle 1: `agentgateway` installed + `expose`d; AWS SSO Bedrock access (`solomog aws:refresh`);
Okta Lab 1 done (`OKTA-SETUP.md`); and **Anthropic model access granted in all `us.` destination
regions** (us-east-1, us-east-2, us-west-2). The backends (`10-`/`11-`) use the `us.` inference
profile (required — on-demand rejects the bare model ID) with `region: us-west-2` to match the
working `llmroute-bedrock`. See bundle 1's README "Bedrock model access" for the full explanation.
