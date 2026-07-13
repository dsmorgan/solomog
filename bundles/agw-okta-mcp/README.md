# agw-okta-mcp — Okta JWT validation + per-user Snowflake MCP elicitation

Prove that **agentgateway validates real Okta identities** at the edge and exchanges them for per-user backend tokens via OAuth consent. Three phases:
1. **Edge JWT validation** — Okta tokens reach the MCP backend; anything else is rejected 401.
2. **OBO impersonation** — User identity is propagated and re-minted by the STS.
3. **Snowflake elicitation** — Per-user browser OAuth consent, token stored, replayed upstream.

## Prerequisites (one-time, in your dev org)

**Okta setup:** You need two Okta apps, one JWKS endpoint, and one scope grant. Detailed steps in [OKTA-SETUP.md](OKTA-SETUP.md); summary here:

- **API Services app** (machine-to-machine, client-credentials) — for the tests to mint tokens
- **Web app** (Authorization Code + PKCE) — for the user-login helper to prompt a browser
- **`mcp.access` scope** granted to both apps on Okta's `default` authorization server
- `.env` block with: `OKTA_DOMAIN`, `OKTA_CLIENT_ID`, `OKTA_CLIENT_SECRET`, `OKTA_SCOPE`, `OKTA_AUDIENCE` (default `api://default`)

Result: you can fetch a token via `curl --oauth2 --oauth2-bearer` (tests) or `pkce-login.sh` (browser).

**Snowflake setup (for Phase 3):** You need an OAuth security integration, a non-admin role, a semantic view, and an MCP server. Detailed steps in [SNOWFLAKE-SETUP.md](SNOWFLAKE-SETUP.md); summary here:

```sql
-- Run as ACCOUNTADMIN in a SQL file (exact syntax matters):
CREATE SECURITY INTEGRATION IF NOT EXISTS AGW_MCP_OAUTH
  TYPE = OAUTH ENABLED = TRUE OAUTH_CLIENT = CUSTOM
  OAUTH_CLIENT_TYPE = 'CONFIDENTIAL'
  OAUTH_REDIRECT_URI = 'https://ui.agw.<cluster>.test/age/elicitations'
  OAUTH_ISSUE_REFRESH_TOKENS = TRUE OAUTH_REFRESH_TOKEN_VALIDITY = 86400;
SELECT SYSTEM$SHOW_OAUTH_CLIENT_SECRETS('AGW_MCP_OAUTH');   -- client id/secret → .env
```

Put Snowflake's client id/secret and account name in `.env` as `SNOWFLAKE_CLIENT_ID`, `SNOWFLAKE_CLIENT_SECRET`, `SNOWFLAKE_ACCOUNT`.

## Full bring-up sequence

### Step 1: Cluster + agentgateway (with STS enabled)

```bash
# 1. Create cluster (agentgateway already installed by default, but STS is opt-in)
solomog agentgateway TOKEN_EXCHANGE=true CLUSTER=a10

# 2. Expose the gateway (creates /etc/hosts, TLS, LoadBalancer)
solomog expose CLUSTER=a10
```

Verify: `kubectl get httproute -n agentgateway-system` shows a resource.

### Step 2: Apply the bundle (Okta + Snowflake config)

```bash
solomog apply BUNDLE=agw-okta-mcp CLUSTER=a10
```

This applies:
- `10-mcp-everything.yaml` — in-cluster test MCP server (reused from `mcp-in-cluster`)
- `50-okta-jwt.sh` — Okta JWKS backend + edge JWT policy (Phase 1)
- `70-obo-routes.sh` — STS + OBO policy (Phase 2)
- `90-snowflake.sh` — Snowflake backend + elicitation policy (Phase 3)

Verify: `kubectl get enterpriseagentgatewaybackend -n agentgateway-system` shows `okta-jwks`, `sts-jwks`, `snowflake-mcp-backend`.

### Step 3: Phase 1 test — edge JWT validation

```bash
solomog test BUNDLE=agw-okta-mcp CLUSTER=a10
```

Expect:
- `10-mcp-401`: unauthenticated request to `/mcp` → 401 ✓
- `20-mcp-okta-authenticated`: client-credentials token fetched from Okta → MCP handshake succeeds (lists tools) ✓

**Proves:** the gateway accepts Okta tokens and rejects everything else.

### Step 4: Phase 2 setup — OBO impersonation (optional; sets up user identity propagation)

User-based flows need a real Okta user token, not just a machine token. Bring up the Solo UI so you can approve elicitations later:

```bash
# Set OKTA_AUDIENCE in .env, then:
solomog agentgateway:ui expose ROUTE=true CLUSTER=a10 \
  TOKEN_EXCHANGE=true OAUTH_ISSUER=true TOKEN_EXCHANGE_API_VALIDATOR=remote
```

Create a dedicated **Web app** in Okta for the UI (separate from the API Services app):
- Type: OIDC → Web Application → Authorization Code
- Redirect URI: `https://ui.agw.a10.test/oauth/callback` (or whatever your actual UI hostname is)
- Set `SOLO_UI_OIDC_BACKEND_CLIENT_ID` and `_SECRET` in `.env`

Log in as a user via the UI (you'll redirect to Okta), then mint a cached user token:

```bash
bash bundles/agw-okta-mcp/helpers/okta-pkce-login.sh
```

This opens a browser for Okta login (Authorization Code + PKCE) and caches the token to `.solomog/okta-user-token.json`.

Run Phase 2 tests:

```bash
solomog test BUNDLE=agw-okta-mcp CLUSTER=a10
```

Expect (new tests):
- `30-obo-mcp-rejects-raw-okta`: raw Okta token on `/obo/mcp` → 401 (only STS tokens allowed) ✓
- `32-obo-mcp-impersonation`: exchange the user token at the STS → OBO token → MCP handshake succeeds ✓

**Proves:** the gateway propagates user identity and the STS re-mints it.

### Step 5: Phase 3 — Snowflake elicitation (browser OAuth consent → per-user token)

Trigger the elicitation with your cached user token:

```bash
USER_JWT=$(jq -r .access_token .solomog/okta-user-token.json)
curl -sk -X POST https://agw.a10.test/snowflake/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${USER_JWT}" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"1.0"}}}'
```

Expect: a JSON-RPC error with `TokenExchangeInfo.url` pointing to the Solo UI's `/age/elicitations` approval queue — that's the elicitation trigger.

Approve the elicitation in the UI:
```
https://ui.agw.a10.test/age/elicitations
```

You'll be redirected to Snowflake's real OAuth consent (log in as a user with the `AGW_ANALYST` role, or whatever role you set up). Grant the scopes. Once approved, the token is stored in the STS.

Retry the curl call:

```bash
curl -sk -X POST https://agw.a10.test/snowflake/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${USER_JWT}" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"1.0"}}}'
```

Expect: a real MCP `initialize` response (not an error) — the gateway attached your Snowflake token upstream.

**Proves:** end-to-end per-user token exchange works.

## Architecture overview

| Route | Frontend | Backend | Token flow |
|-------|----------|---------|----------|
| `/mcp` | JWT (Okta) | in-cluster test | Okta JWT validated at edge |
| `/obo/mcp` | JWT (STS) | in-cluster test | Okta JWT → STS re-mints → downscoped STS token |
| `/snowflake/mcp` | JWT (Okta) | Snowflake MCP | Okta JWT → STS elicits Snowflake OAuth → per-user token stored → replayed |

**Key files:**
- `10-mcp-everything.yaml` — in-cluster test server + Phase 1 discovery routes
- `50-okta-jwt.sh` — Phase 1: Okta JWKS + JWT policy
- `70-obo-routes.sh` — Phase 2: STS backend + OBO policy
- `90-snowflake.sh` — Phase 3: Snowflake backend + elicitation policy

## Troubleshooting

**"no healthy backends"** (Phase 3) → Snowflake OAuth integration's `OAUTH_REDIRECT_URI` doesn't match. Fix:
```sql
ALTER SECURITY INTEGRATION AGW_MCP_OAUTH SET OAUTH_REDIRECT_URI='https://ui.agw.a10.test/age/elicitations';
```

**Elicitation triggers but token-serve fails** → Check the STS's subject validator is pointed at Okta. In `.env`:
```
TOKEN_EXCHANGE_JWKS_URL=https://<okta-domain>/oauth2/default/v1/keys
```

**"Okta tokens in, everything else out" but tests fail** → The JWT policy may have a malformed `jwksPath`. It should be `oauth2/default/v1/keys` (no leading slash). See `50-okta-jwt.sh`.

**Phase 2 tests fail with "no cached user token"** → Run `bash bundles/agw-okta-mcp/helpers/okta-pkce-login.sh` to mint one.

## References

- [OKTA-SETUP.md](OKTA-SETUP.md) — Detailed Okta console steps
- [SNOWFLAKE-SETUP.md](SNOWFLAKE-SETUP.md) — Detailed Snowflake SQL steps + semantic view / MCP server config
- [ELICITATION-MODE-NOTES.md](ELICITATION-MODE-NOTES.md) — Why `mode` must be omitted for token injection to work
- Plan: `agentgateway-mcp-pov-plan.md`
