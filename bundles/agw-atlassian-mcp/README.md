# agw-atlassian-mcp — eager-auth OAuth issuer → per-user Atlassian MCP

A **standalone** bundle (no dependency on `agw-okta-mcp`) that stands up agentgateway's
**eager-auth OAuth issuer**: the gateway becomes the OAuth Authorization Server MCP clients see,
does "fake DCR" (hands back a pre-registered Okta client), and brokers the auth-code flow to Okta.
That issuer is the piece the earlier Atlassian attempt was missing — discovery/DCR elicitation to
`mcp.atlassian.com` can't build a consent URL without it.

Built from the workshop lab `~/code/fe-enterprise-agentgateway-workshop/labs/mcp/mcp-eager-auth-okta.md`.

## Two phases

**Phase 1 (this bundle, now) — prove the eager-auth issuer in solomog** against an in-cluster
reference MCP server (`@modelcontextprotocol/server-everything`). No Atlassian, no Solo UI. When an
MCP client connects to `/mcp` it discovers the gateway as its OAuth AS, DCRs against
`/oauth-issuer/register`, and is redirected to Okta to log in. This de-risks the two unknowns before
Atlassian: (a) does the issuer serve its own AS metadata correctly, and (b) does Okta login → JWT
validation at the backend work end-to-end.

**Phase 2 (next) — swap the backend to Atlassian** + add the per-backend discovery elicitation
(`base_url: mcp.atlassian.com`, DCR, **omit `mode`**) so the gateway also elicits a per-user
Atlassian token and replays it upstream. The Phase-1 draft is preserved under
[`phase2/`](phase2/) (`atlassian-backend.sh` + `ATLASSIAN-SETUP.md`) — not applied (subdirs aren't).

## What it applies (Phase 1)

| File | Kind | Purpose |
|---|---|---|
| `10-mcp-everything.yaml` | Deployment/Service/Backend/HTTPRoute | in-cluster test MCP server + `/mcp` + the two `.well-known/oauth-*/mcp` discovery paths (with a CORS filter for `mcp-protocol-version`) |
| `20-oauth-issuer-route.yaml` | HTTPRoute | `/oauth-issuer` → controller `:7777` (the AS + STS endpoints) |
| `30-proxy-sts.sh` | Params + GatewayClass | point the proxy at the in-cluster STS (`STS_URI`) |
| `40-eager-auth.sh` | Backend/Secret/Policy | `okta-jwks`, the issuer's `elicitation-secret` (→ Okta), and the `mcp.authentication` + `issuer-proxy` policy |

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

## Troubleshooting (from the lab)
- **`/oauth-issuer/register` 404** → `OAUTH_ISSUER=true` didn't take, or the `oauth-issuer` route is
  missing. Check controller logs for `KGW_OAUTH_ISSUER_CONFIG is not set` and
  `kubectl get httproute -n agentgateway-system oauth-issuer`.
- **`GET /mcp` returns 406 not 401** → the policy is `PartiallyValid`, almost always a leading slash
  on `jwksPath`. `40-eager-auth.sh` uses `oauth2/<as-id>/v1/keys` (no leading slash).
- **Controller CrashLoopBackOff `unsupported validator type`** → the tokenExchange block needs all
  three validators (subject/actor/api). The helmfile sets them; ensure `TOKEN_EXCHANGE=true`.
- **`secret not found: agentgateway-system/elicitation-secret`** → `40-eager-auth.sh` didn't apply;
  re-run `solomog apply`.
- Trace the proxy: `bash ../agw-okta-mcp/helpers/trace.sh on a9` (re-run after any `solomog apply`,
  since `30-proxy-sts.sh` rewrites the params CR and clears `RUST_LOG`).
