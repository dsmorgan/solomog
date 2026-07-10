# Lab 6 — Scaling authorization (implemented here)

Where [`agw-okta-bedrock-llm`](../agw-okta-bedrock-llm/AUTHZ-PATTERNS.md) *described* the scaling
patterns, this bundle *implements* the key one: **the gateway derives the user's tier from their
Okta group and routes accordingly, on a single endpoint.** The user never picks a tier.

The three ownership domains still hold — onboarding a user is an **Okta group assignment**, never a
gateway change:

| Domain | Answers | Changes | Owner |
|--------|---------|---------|-------|
| Okta groups | who / what tier | daily (joiner/leaver) | IdP / IT |
| AG policy (CEL) | tier→model mapping, budgets | rarely, in git | platform team |
| AWS credentials | Bedrock creds | never exposed to users | gateway backend auth only |

## How the routing is realized

The mechanism (see `50-okta-tier-routing.sh` + `20-bedrock-routes.yaml`):

1. A **`PreRouting`** policy on the Gateway validates the Okta JWT, then sets a header from the
   groups claim via a CEL ternary — `premium` > `standard` > `none`:
   ```
   x-llm-tier = (has(jwt.groups) && 'llm-premium' in jwt.groups) ? 'premium'
              : (has(jwt.groups) && 'llm-standard' in jwt.groups) ? 'standard' : 'none'
   ```
2. Because the transformation runs **before route selection**, two HTTPRoutes on the shared
   `/bedrock` path match on `x-llm-tier` and forward to the tier's backend.
3. `none` matches no route → **404 = deny**.

Adding a tier = add a group, a CEL branch, a header-matched route, and a model backend.

## CEL rule examples (for other/added tiers)

```cel
'llm-premium'  in jwt.groups                                    # premium
'llm-standard' in jwt.groups                                    # standard
'contractors'  in jwt.groups && timestamp(request.time).getHours() >= 13   # time-boxed
'llm-standard' in jwt.groups && !('contractors' in jwt.groups)  # exclude contractors off-hours
```

## Enforcement points

1. **The route pins the model — gate the route, not the model name.** Each tier backend (10/11)
   pins its model, so the served model follows the route the header chose, not any client-supplied
   model field. `tests/20-tier-routing.sh` proves this by reading `.model` from the response.
2. **Multi-model tiers:** add more header-matched routes/backends; keep "which group → which
   header value → which route" the single control point.
3. **Quotas at fleet scale:** tier-wide budget via `rateLimit.local` (premium here, a
   deliberately small 1k tokens/min so the limit is testable); per-developer quota across
   replicas via `rateLimit.remote` keyed on `jwt.sub`.

## Audit trail

Every Bedrock invocation AG logs carries `jwt.sub` (and the Solo UI traces surface it as User ID),
so per-developer cost/usage reporting comes straight from the logs — no extra plumbing.

## Caveat

The `PreRouting` JWT policy targets the **Gateway**, so it applies to every route on that gateway.
Use a dedicated cluster/gateway for this bundle (see README).
