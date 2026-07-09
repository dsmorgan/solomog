# agw-atlassian-mcp — eager-auth OAuth issuer + per-user Atlassian MCP elicitation (WIP)

A **standalone** bundle (no dependency on `agw-okta-mcp`) with two independent proofs on one
cluster: agentgateway's **eager-auth OAuth issuer** (Phase 1 — the gateway becomes the OAuth
Authorization Server MCP clients see, does "fake DCR", brokers the auth-code flow to Okta), and
**per-user discovery/DCR elicitation** against Atlassian's remote MCP server (Phase 2 — a *separate*,
simpler architecture; see below for why they don't share a frontend).

Phase 1 built from the workshop lab `~/code/fe-enterprise-agentgateway-workshop/labs/mcp/mcp-eager-auth-okta.md`.
Phase 2 built from Solo's own **validated** reference,
`agentgateway-enterprise/dev-docs/tokenexchange/elicitation/test-elicitation-guide-mcp.md`.

## Two phases (both apply to the same cluster — independent, not combined)

**Phase 1 — ✅ PROVEN (a9, 2026-07-08) — the eager-auth issuer**, against an in-cluster reference MCP
server (`@modelcontextprotocol/server-everything`). No Atlassian, no Solo UI. An MCP client connecting
to `/mcp` discovers the gateway as its OAuth AS, DCRs against `/oauth-issuer/register`, and is
redirected to Okta to log in. Verified: a real Okta user completed the full auth-code flow and
`POST /mcp initialize` returned 200.

**Phase 2 — Atlassian elicitation**, as a SEPARATE backend/route/policy at `/atlassian/mcp`
(matching Snowflake's `/snowflake/mcp` convention in `agw-okta-mcp`) — a **plain Strict Okta JWT
frontend** (reusing Phase 1's `okta-jwks` backend) + `backend.tokenExchange.elicitation` against a
discovery-mode secret (DCR against Atlassian). Additive — `/mcp` (Phase 1) keeps working unchanged.
See [ATLASSIAN-SETUP.md](ATLASSIAN-SETUP.md) for the full runbook.

> ⚠️ **Phase 2 deliberately does NOT use eager-auth as its frontend — corrected 2026-07-08 after
> checking Solo's own validated reference.** An earlier version combined `backend.mcp.authentication`
> (eager-auth) with `backend.tokenExchange.elicitation` on one policy, tested with Claude Code (which
> got all the way to a real Atlassian consent screen — DCR genuinely worked). But every attempt then
> hit the same failure: a real token got minted (`code exchange succeeded ... has_access_token:true`
> in the controller logs), yet the very next token-*serve* check reused a **different**, stale DCR
> client id and 400'd — reproducibly, even across a clean controller restart. Root cause, confirmed
> in source (`ent-controller/internal/issuer/flow_upstream.go` line ~320, the code's own comment):
> *"This codepath does not support multiple concurrent upstream clients for one resource."* Once
> `backend.mcp.authentication` is set, the controller's "dual OAuth agent flow" machinery
> (`flow_select.go`'s `mcpAuthResources` index) takes over the *entire* flow, including its own
> DCR-caching path — which isn't safe against a real MCP client's automatic retries racing it.
>
> Checking against Solo's docs settled it: `test-elicitation-guide-mcp.md` ("Status: VALIDATED") is
> the tested reference for exactly this scenario (per-user OAuth to a remote MCP API, GitHub in
> their example) — and its elicitation trigger returns a URL to the **Solo UI**'s `/age/elicitations`
> queue, not a direct provider authorize URL. Ours returned the latter — proof we were on the
> untested eager-auth-agent-flow path instead of the validated, UI-mediated one. That doc's own
> comparison table states plainly: *"Setup: Requires Keycloak + enterprise UI."* Fixed by dropping
> `backend.mcp.authentication` from `50-atlassian.sh` entirely, matching Snowflake's `90-snowflake.sh`
> shape in `agw-okta-mcp`. **Consequence:** this route gives no OAuth-discovery hints, so
> Inspector/Claude Code's auto-login won't work against it — testing is curl (or Inspector with a
> manually-pasted Bearer header) using a token from `../agw-okta-mcp/helpers/okta-pkce-login.sh`,
> exactly as the validated doc itself tests (see ATLASSIAN-SETUP.md).

## What it applies

| File | Kind | Phase | Purpose |
|---|---|---|---|
| `10-mcp-everything.yaml` | Deployment/Service/Backend/HTTPRoute | 1 | in-cluster test MCP server + `/mcp` + the two `.well-known/oauth-*/mcp` discovery paths (with a CORS filter for `mcp-protocol-version`) |
| `20-oauth-issuer-route.yaml` | HTTPRoute | 1 | `/oauth-issuer` → controller `:7777` (the AS + STS endpoints) |
| `30-proxy-sts.sh` | Params + GatewayClass | 1 | point the proxy at the in-cluster STS (`STS_URI`) |
| `40-eager-auth.sh` | Backend/Secret/Policy | 1 | `okta-jwks`, the issuer's `elicitation-secret` (→ Okta), and the `mcp.authentication` + `issuer-proxy` policy |
| `50-atlassian.sh` | Secret/Backend/HTTPRoute/Policy | 2 | `atlassian-elicitation` (discovery secret), `atlassian-mcp-backend`/route at `/atlassian/mcp`, and a policy pairing a plain Strict Okta JWT frontend (reusing `okta-jwks`) with `backend.tokenExchange.elicitation` |

## Okta prerequisite (one-time)

Eager-auth needs a **confidential Authorization Code** Okta app with **both** of these redirect URIs
registered:

```
https://agw.a9.test/oauth-issuer/callback/downstream
https://agw.a9.test/oauth-issuer/callback/upstream
```

Registering only one → Okta `The 'redirect_uri' parameter must be a Login redirect URI` after login.
Confirm the app has the Authorization Code grant enabled and your user is assigned to it.

> ⚠️ This is **not** the API-Services (machine-to-machine) app that `OKTA_CLIENT_ID` points at for the
> agw-okta-mcp tests — that grant can't do the browser flow. Simplest: **create one dedicated Okta
> Web app** (OIDC → Web Application → Authorization Code) with the two redirect URIs above, assign
> your user, and set `OAUTH_ISSUER_CLIENT_ID` / `OAUTH_ISSUER_CLIENT_SECRET` in `.env` to its
> id/secret. (You *can* instead reuse an existing confidential app — e.g. your Solo UI backend app,
> `SOLO_UI_OIDC_BACKEND_*` — by adding the two URIs to it. Leaving the vars blank falls back to
> `OKTA_CLIENT_ID`/`SECRET`, which only works if that's already a confidential Auth-Code app.)

`.env` values used: `OKTA_DOMAIN`, `OAUTH_ISSUER_CLIENT_ID`/`_SECRET` (or `OKTA_CLIENT_ID`/`_SECRET`
fallback), `OKTA_AUTH_SERVER_ID` (default `default`), `OKTA_AUDIENCE` (default `api://default`), and
`TOKEN_EXCHANGE_JWKS_URL` (→ `https://<domain>/oauth2/<as-id>/v1/keys`).

## Ground-up bring-up on a fresh cluster (a9)

```bash
# 1. Cluster + agentgateway WITH the STS and the eager-auth issuer enabled (CLI-only flags).
#    OAUTH_ISSUER_HOST defaults to agw.a9.test.
solomog agentgateway CLUSTER=a9 TOKEN_EXCHANGE=true OAUTH_ISSUER=true

# 2. Gateway + TLS + /etc/hosts (mkcert wildcard *.agw.a9.test).
solomog expose CLUSTER=a9

# 3. Apply this bundle.
solomog apply BUNDLE=agw-atlassian-mcp CLUSTER=a9

# 4. Smoke tests (unauth 401 + AS-metadata served by the gateway).
solomog test BUNDLE=agw-atlassian-mcp CLUSTER=a9
```

> State store is **SQLite in-memory** (no Postgres) — fine for a PoV, but OAuth flow/client state is
> lost if the controller restarts (re-consent). Add a `tokenExchange.database` block to the helmfile
> for Postgres-backed state (lab Step 3).

## Verify with MCP Inspector (the interactive proof)

```bash
# trust the self-signed... it's mkcert here, so just:
NODE_TLS_REJECT_UNAUTHORIZED=0 npx @modelcontextprotocol/inspector
```
- Transport `Streamable HTTP`, URL `https://agw.a9.test/mcp`, **Connect**.
- Inspector follows discovery → redirects to **Okta** (URL bar shows `${OKTA_DOMAIN}`, not the
  gateway → confirms the issuer delegated downstream) → log in → back to Inspector → **Connected**.
- **Tools → List Tools** renders (`echo`, `add`, …); run `echo` → a result, not a 401.

| Observation | Proves |
|---|---|
| `test 20` passes / discovery `registration_endpoint` = gateway `/oauth-issuer/register` | issuer serves its own AS metadata (fake-DCR) |
| Redirect lands on `${OKTA_DOMAIN}` | issuer brokered the auth-code flow to Okta |
| Tools list without 401 | Okta JWT validated against Okta JWKS at the backend |

## Phase 2 bring-up (on top of a running Phase 1)

`OAUTH_ISSUER=true` is still required at the controller level even though this route's frontend
doesn't use eager-auth — discovery/DCR elicitation depends on the controller's issuer infra
(`KGW_OAUTH_ISSUER_CONFIG`) regardless of frontend type. **Always keep `TOKEN_EXCHANGE=true
OAUTH_ISSUER=true` on every command that touches the agentgateway install** — dropping either
silently tears down Phase 1's config.

Bring up the Solo UI too — per the validated doc, elicitation approval is mediated there
(`/age/elicitations`), not by the MCP client itself:

```bash
solomog agentgateway:ui expose ROUTE=true CLUSTER=a9 \
  TOKEN_EXCHANGE=true OAUTH_ISSUER=true TOKEN_EXCHANGE_API_VALIDATOR=remote
solomog apply BUNDLE=agw-atlassian-mcp CLUSTER=a9   # picks up 50-atlassian.sh; Phase 1 files reapply as no-ops
solomog test  BUNDLE=agw-atlassian-mcp CLUSTER=a9   # tests 10/20 (Phase 1) + 30/40 (Phase 2) all run
```

Test 40 needs a cached Okta user token — mint one first:
```bash
bash bundles/agw-okta-mcp/helpers/okta-pkce-login.sh
```

**⚠️ One Atlassian-side admin step, unrelated to solomog:** Atlassian enforces an org-level redirect-URL
allowlist for OAuth apps (their DCR flow still needs the callback domain approved). If consent shows
*"Your organization admin must authorize access from this redirect URL"*, go to
**admin.atlassian.com → Apps → AI settings → Rovo MCP server** and add `agw.a9.test` to the domain
allowlist (self-service; Atlassian only recently added this — previously a hard block).

Full interactive walkthrough (Atlassian site setup, scopes, what each observation proves) is in
[ATLASSIAN-SETUP.md](ATLASSIAN-SETUP.md).

## Troubleshooting
- **`/oauth-issuer/register` 404** (Phase 1) → `OAUTH_ISSUER=true` didn't take, or the `oauth-issuer`
  route is missing. Check controller logs for `KGW_OAUTH_ISSUER_CONFIG is not set` and
  `kubectl get httproute -n agentgateway-system oauth-issuer`.
- **`GET /mcp` returns 406 not 401** (Phase 1) → the policy is `PartiallyValid`, almost always a
  leading slash on `jwksPath`. `40-eager-auth.sh` uses `oauth2/<as-id>/v1/keys` (no leading slash).
- **Controller CrashLoopBackOff `unsupported validator type`** → the tokenExchange block needs all
  three validators (subject/actor/api). The helmfile sets them; ensure `TOKEN_EXCHANGE=true`.
- **`secret not found: agentgateway-system/elicitation-secret`** → `40-eager-auth.sh` didn't apply;
  re-run `solomog apply`.
- **Atlassian elicitation returns a direct provider authorize URL instead of a Solo UI link** → the
  policy has `backend.mcp.authentication` on it somewhere; `50-atlassian.sh` must NOT set that field
  (see the README callout above for why).
- Trace the proxy: `bash ../agw-okta-mcp/helpers/trace.sh on a9` (re-run after any `solomog apply`,
  since `30-proxy-sts.sh` rewrites the params CR and clears `RUST_LOG`).
