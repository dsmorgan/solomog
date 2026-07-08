# agw-okta-mcp — Okta JWT validation at the agentgateway edge

Step 1 of the MCP POV (see [`agentgateway-mcp-pov-plan.md`](agentgateway-mcp-pov-plan.md)):
prove that **agentgateway validates a real Okta-issued JWT** in front of an MCP backend. A
valid Okta token reaches the MCP tools; anything else is rejected 401 at the gateway edge.

This is the identity spine the later POV work (OBO delegation, per-backend token exchange,
Snowflake/DealCloud) sits on top of — get Okta trusted here first.

| Route | Backend | Policy |
|-------|---------|--------|
| `/mcp` | in-cluster `mcp-website-fetcher` (reused from `mcp-in-cluster`) | `okta-mcp-jwt` → JWT `mode: Strict` against Okta's `/oauth2/default` |

**How it works.** `50-okta-jwt.sh` applies two objects generated from your `.env`:
- `okta-jwks` (`AgentgatewayBackend`) — points at your Okta org on `:443`. `spec.policies.tls: {}`
  makes the gateway do verified HTTPS with the system CA bundle + auto-SNI, so Okta's public
  cert works with no cert config.
- `okta-mcp-jwt` (`EnterpriseAgentgatewayPolicy`) — `traffic.jwtAuthentication` on the `mcp`
  HTTPRoute, validating `iss` (`https://<domain>/oauth2/default`) + `aud` (`api://default`)
  and the signature against Okta's JWKS (fetched via `okta-jwks`, cached 5m).

No secrets are applied to the cluster — the gateway only needs Okta's **public** JWKS to
*validate* tokens. The client id/secret are used only by the tests to *fetch* a token.

> **Version note.** This bundle is built and verified against **enterprise agentgateway
> `2026.6.3`** (CalVer), which is what cluster `a8` runs — a deliberate departure from
> solomog's default `2.3.x` stable pin, for this POV. The JWT/backend field shapes above were
> confirmed against that CRD.

## Okta setup (one-time, in your dev org)

> **Full recreate runbook:** [`OKTA-SETUP.md`](OKTA-SETUP.md) — every Okta console step in
> order (both apps, scope, access policy, the DPoP + `may_act` gotchas) plus the resulting
> `.env` block. The summary below covers just App A (edge JWT); the runbook has everything.

Using Okta's custom **"default" authorization server** (`/oauth2/default`) — it issues real
JWT access tokens with a JWKS endpoint, which is what edge validation needs.

1. **App** — Admin console → *Applications → Create App Integration → API Services*
   (machine-to-machine, client-credentials). Note its **Client ID** and **Client secret**.
2. **Scope** — *Security → API → Authorization Servers → `default` → Scopes → Add Scope*,
   e.g. `mcp.access`. Client-credentials tokens require a granted scope.
3. **Grant the scope to the app** — on the `default` AS, ensure an access policy/rule allows
   the client-credentials grant for your app + that scope (the default AS ships with a
   "Default Policy" you can add a rule to).
4. **Domain** — your org host, e.g. `dev-1234567.okta.com` (no `https://`). Confirm the
   issuer resolves: `https://<domain>/oauth2/default/.well-known/openid-configuration`.

Put the values in `.env` (see `.env.example` for the block):

```
OKTA_DOMAIN=dev-1234567.okta.com
OKTA_CLIENT_ID=0oa...
OKTA_CLIENT_SECRET=...
OKTA_SCOPE=mcp.access
# OKTA_AUDIENCE defaults to api://default
```

## Apply (cluster `a8` already up, agentgateway installed)

```
solomog expose apply BUNDLE=agw-okta-mcp CLUSTER=a8
```

`expose` creates the Gateway + `/etc/hosts` entry (once per cluster); `apply` lays down the
MCP backend/route and runs the `50-okta-jwt.sh` hook. Re-running is safe (kubectl apply +
idempotent hook).

> The Okta config is applied by a `.sh` hook, so `DRY_RUN=true` **skips** it (hooks aren't
> dry-run safe) — the MCP manifests still validate, but the JWT policy won't.

## Verify

```
solomog test BUNDLE=agw-okta-mcp CLUSTER=a8
```

- `10-mcp-401` — unauthenticated request to `/mcp` is rejected (401).
- `20-mcp-okta-authenticated` — fetches a client-credentials token from Okta and completes a
  real MCP handshake through `/mcp` carrying it (lists tools). A 200 here + the 401 above is
  the whole proof: Okta tokens in, everything else out.

## OBO / identity-propagation (Auth Code + PKCE → STS token exchange)

Client-credentials proves edge validation, but its `sub` is the *client*, not a human. The
OBO leg carries a real **user** identity to the tool. Two routes now hit the same MCP backend:

| Route | Token it requires | Policy |
|-------|-------------------|--------|
| `/mcp` | a raw Okta token (edge validation) | `okta-mcp-jwt` (issuer = Okta) |
| `/obo/mcp` | an **STS-issued** OBO token | `obo-mcp-jwt` (issuer = the `:7777` STS) — file 72 |

Flow: a user logs in via **Auth Code + PKCE** (`helpers/okta-pkce-login.sh`) → the STS
validates that Okta token against Okta's JWKS and re-mints a downscoped OBO token → only that
STS token is accepted on `/obo/mcp` (a raw Okta token 401s). The STS's subject validator is
pointed at Okta via `TOKEN_EXCHANGE_JWKS_URL`.

**Enable + run:**
```
# 1. Point the STS's subject validator at Okta, in .env:
#    TOKEN_EXCHANGE_JWKS_URL=https://<domain>/oauth2/default/v1/keys
# 2. Enable the STS (CLI-only flag; restarts the agw proxy):
solomog agentgateway TOKEN_EXCHANGE=true CLUSTER=a8
# 3. Apply the bundle (adds the sts-jwks backend, /obo/mcp route + policy):
solomog apply BUNDLE=agw-okta-mcp CLUSTER=a8
# 4. Log in as a user (browser, one-time per token lifetime):
bash bundles/agw-okta-mcp/helpers/okta-pkce-login.sh
# 5. Verify:
solomog test BUNDLE=agw-okta-mcp CLUSTER=a8
```

OBO tests: `30-obo-mcp-rejects-raw-okta` (raw Okta token → 401 on `/obo/mcp`),
`32-obo-mcp-impersonation` (exchange the user token → OBO token → MCP handshake succeeds).
Both need the STS enabled and a cached user token; they fail with guidance if either is missing.

### Delegation (subject + actor → `sub`=user, `act`=agent) — ⚠️ blocked natively by Okta

Impersonation carries only the user. **Delegation** also carries the *agent* identity (`act`),
so a downstream tool sees the full chain (who acted, on whose behalf). Files 80/82 add an
`obo-agent` ServiceAccount + a pod running as it; the pod's k8s SA token is the `actor_token`.

The STS won't mint a delegated token unless the **user token authorizes that agent** via a
`may_act` claim (verified live: without it the STS returns *"delegation not authorized:
subject token does not contain may_act claim"*). So Okta would need to emit:
```
may_act: {"sub": "system:serviceaccount:agentgateway-system:obo-agent", "iss": "https://kubernetes.default.svc.cluster.local"}
```

**Finding (why delegation is NOT enabled here):** Okta **reserves `may_act`** and rejects it as
a custom claim — the Add-Claim UI errors with *"may_act is reserved and cannot be used."* The
root cause is that Okta has its **own** native RFC 8693 token-exchange that consumes `may_act`,
so it's a system claim, not a naming collision. Consequences:
- **Impersonation is the working Okta OBO mode** (test 32) — it needs no `may_act` and
  propagates the user identity. That is the PoV's identity-propagation proof.
- The agentgateway **STS delegation machinery itself works** — the live probe validated the
  subject + actor and only then failed the `may_act` policy check. Everything is in place
  *except* the claim Okta won't emit.

**To enable delegation with Okta anyway** (if the customer specifically needs the `act` claim),
`may_act` must be injected outside a normal custom claim:
- a **Token Inline Hook** (Okta calls a public HTTPS endpoint during token minting to add the
  claim — uncertain Okta permits a reserved claim even via hook, and needs an internet-reachable
  endpoint), or
- an **ext-auth shim** that injects `may_act` before the STS sees the token (the customer's
  known workaround pattern, per the plan doc §2 Leidos note).

Files 80/82 + `tests/40-del-delegation-flow.sh` are **staged and ready**: test 40 SKIPs (green)
when `may_act` is absent, and runs the full end-to-end delegation proof (asserts `sub`=user AND
`act`=agent, accepted on `/obo/mcp`) the moment a token carries `may_act`.

## Backends

- **Snowflake elicitation — ✅ WORKING (2026-07-07).** Per-user browser OAuth consent to Snowflake's
  managed MCP server (Cortex Analyst over a TPC-H semantic view). `90-snowflake.sh` + SNOWFLAKE-SETUP.md.
  End-to-end proven: Okta identity → elicitation consent → per-user Snowflake token stored → replayed
  with `Authorization: Bearer` → Cortex Analyst tool answers. **Key config:** the elicitation policy
  must **omit `mode`** (do NOT use `mode: ElicitationOnly` — that mode is documented as "elicit, don't
  exchange/inject", so it never attaches the token; omit `mode` → default = both. See
  ELICITATION-MODE-NOTES.md), and needs the `X-Snowflake-Authorization-Token-Type: OAUTH`
  transformation header. Runs on agentgateway 2026.6.3.
- **Mock DealCloud — TODO.** Represents a SaaS we can't get a test account for; will be a mock
  client-credentials / `ExchangeOnly` backend (no browser consent). Not built yet.
- **Atlassian — MOVED OUT** to the `bundles/agw-atlassian-mcp` bundle (2026-07-07). It needs the
  eager-auth OAuth issuer infra that this Snowflake demo doesn't, so it lives on its own with a
  "how to complete" reference.

## Next (per the POV plan)

Build the mock DealCloud client-credentials backend (§5) — `ExchangeOnly`/static-cred, no browser flow.
