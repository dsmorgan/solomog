# Lab 6 — Scaling authorization to 1000 users

How this bundle's two-tier pattern generalizes. The point: **onboarding a user is an Okta group
assignment, never a gateway change.** Three ownership domains stay separate:

| Domain | Answers | Changes | Owner |
|--------|---------|---------|-------|
| **Okta groups** | who is this user, what tier | daily (joiner/leaver) | IdP / IT |
| **AG policy (CEL)** | what each tier reaches, at what budget | rarely, in git | platform team |
| **AWS credentials** | the actual Bedrock creds | never exposed to users | gateway backend auth only |

For 1000 users: define **3–5 tiers** (one route each), each pinning its model(s) and gated by a
single CEL rule on the `groups` claim. This bundle ships 2 (`llm-standard`, `llm-premium`) in
[`50-okta-jwt-authz.sh`](50-okta-jwt-authz.sh) — add more by copying a route+backend+policy trio.

## CEL rule examples

The `authorization.policy.matchExpressions` field takes CEL over the validated JWT (`jwt.*`)
and request (`request.*`):

```cel
'llm-standard' in jwt.groups                                    # basic tier
'llm-premium'  in jwt.groups                                    # premium tier
'contractors'  in jwt.groups && timestamp(request.time).getHours() >= 13   # time-boxed contractors
'llm-standard' in jwt.groups && !('contractors' in jwt.groups)  # exclude contractors off-hours
```

## Enforcement points (get these right)

1. **The route pins the model — gate the route, not the model name.** HTTP-level `authorization`
   runs *before* the LLM body is parsed, so authorize on the `groups` claim and let the route's
   Bedrock backend decide the actual model. Never trust a client-supplied model field for authz.
2. **Multi-model tiers:** give a tier several routes/hostnames, or use the AI policy's model
   aliasing — but keep "which group reaches which route" as the single control point.
3. **Quotas at fleet scale:**
   - **Tier-wide budget** → `rateLimit.local` (per gateway instance). This bundle uses it for the
     premium tier (100k tokens/min).
   - **Per-developer quota across replicas** → `rateLimit.remote` (a shared rate-limit service),
     with descriptors keyed on `jwt.sub` so the budget follows the user, not the pod.

## Audit trail

Every Bedrock invocation AG logs includes `jwt.sub`, so per-developer cost/usage reporting comes
straight from the access logs (and the Solo UI traces surface the same `sub` as User ID) — no
extra plumbing. Cross-reference the trace ID in the logs to jump to the full prompt/completion.

## `action: Allow` semantics

These policies use `action: Allow` with the group check as the whitelist. Whether `Allow` fails
**closed** (default-deny; only matching requests pass) is verified by
[`tests/30-standard-rejected-on-premium.sh`](tests/30-standard-rejected-on-premium.sh) — a
standard-tier token must be *rejected* on the premium route. If a wrong-tier token ever gets
through, switch both policies to `action: Require` and re-test. Confirm before trusting this at
scale — it's the whole enforcement model.
