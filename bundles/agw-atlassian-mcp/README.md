# agw-atlassian-mcp — Okta JWT + per-user Atlassian MCP elicitation

Standalone bundle (independent of agw-okta-mcp) with two proofs:
1. **Eager-auth OAuth issuer** (Phase 1) — the gateway acts as an OAuth Authorization Server for MCP clients, brokers login to Okta
2. **Atlassian per-user elicitation** (Phase 2) — browser OAuth consent to Atlassian, token stored and replayed upstream

This is a simplified alternative to agw-okta-mcp's Snowflake setup: same elicitation backend architecture, but with Atlassian and Phase 1's eager-auth issuer for client auto-discovery.

## Prerequisites (one-time, in your dev org)

**Okta setup:** Two apps (eager-auth needs both a backend app AND a browser-facing app with specific redirect URIs). Detailed steps in [OKTA-SETUP.md](OKTA-SETUP.md); summary:

- **API Services app** (machine-to-machine) — `OAUTH_ISSUER_CLIENT_ID` / `_SECRET`
- **Web app** (Authorization Code) — with both these redirect URIs registered:
  - `https://agw.<cluster>.test/oauth-issuer/callback/downstream`
  - `https://agw.<cluster>.test/oauth-issuer/callback/upstream`
- **`mcp.access` scope** granted to the Web app
- `.env` block with: `OKTA_DOMAIN`, `OAUTH_ISSUER_CLIENT_ID`, `OAUTH_ISSUER_CLIENT_SECRET`, `OKTA_AUDIENCE` (default `api://default`)

**Atlassian setup:** Free Cloud site with a little data (Jira project + issues, or Confluence space + pages). No OAuth app to create — Phase 2 uses Dynamic Client Registration. Detailed steps in [ATLASSIAN-SETUP.md](ATLASSIAN-SETUP.md).

## Full bring-up sequence

### Step 1: Cluster + agentgateway with OAuth issuer enabled

```bash
solomog agentgateway CLUSTER=a10 TOKEN_EXCHANGE=true OAUTH_ISSUER=true
solomog expose CLUSTER=a10
```

The `OAUTH_ISSUER=true` flag enables the controller's OAuth issuer machinery (KGW_OAUTH_ISSUER_CONFIG), which both phases use.

### Step 2: Apply the bundle

```bash
solomog apply BUNDLE=agw-atlassian-mcp CLUSTER=a10
```

This applies:
- `10-mcp-everything.yaml` — in-cluster test MCP server
- `20-oauth-issuer-route.sh` — `/oauth-issuer` route to the controller's STS
- `30-proxy-sts.sh` — STS proxy params
- `40-eager-auth.sh` — Okta JWKS + eager-auth policy (Phase 1)
- `50-atlassian.sh` — Atlassian backend + elicitation policy (Phase 2)

### Step 3: Phase 1 test — eager-auth OAuth issuer (client auto-discovery)

```bash
NODE_TLS_REJECT_UNAUTHORIZED=0 npx @modelcontextprotocol/inspector
```

Transport: **Streamable HTTP**  
URL: `https://agw.a10.test/mcp`  
**Connect**

The gateway's discovery metadata (`/.well-known/oauth-authorization-server`) redirects your client to Okta's real OAuth. You'll be prompted to log in, then redirected back to Inspector. Once connected:
- **Tools → List Tools** renders (proves the Okta JWT reached the backend)
- Running `echo` returns a result (not 401)

**Proves:** Phase 1 works — clients discover the gateway as their OAuth AS, login is transparently brokered to Okta.

Verify resources exist:

```bash
kubectl get httproute -n agentgateway-system | grep mcp
kubectl get enterpriseagentgatewaybackend -n agentgateway-system
kubectl get enterpriseagentgatewaypolicy -n agentgateway-system | grep mcp
```

### Step 4: Phase 2 setup — Atlassian elicitation (browser OAuth consent + token storage)

Phase 1 gives clients OAuth discovery. Phase 2 adds per-user token exchange for Atlassian. You need:
- The **Solo UI** to approve elicitations
- An Okta **user token** (from a real browser login, not machine credentials)

Bring up the UI:

```bash
solomog agentgateway:ui expose ROUTE=true CLUSTER=a10 \
  TOKEN_EXCHANGE=true OAUTH_ISSUER=true TOKEN_EXCHANGE_API_VALIDATOR=remote
```

Create a dedicated **Web app** in Okta for the UI (separate from the eager-auth app):
- Type: OIDC → Web Application → Authorization Code
- Redirect URI: `https://ui.agw.a10.test/oauth/callback`
- Set `SOLO_UI_OIDC_BACKEND_CLIENT_ID` and `_SECRET` in `.env`

Mint a cached user token:

```bash
bash bundles/agw-okta-mcp/helpers/okta-pkce-login.sh
```

This opens a browser for Okta login and caches the token to `.solomog/okta-user-token.json`.

### Step 5: Trigger Atlassian elicitation

Trigger the elicitation with your cached user token (Phase 2 has no OAuth discovery, so it requires manual token attachment):

```bash
USER_JWT=$(jq -r .access_token .solomog/okta-user-token.json)
curl -sk -X POST https://agw.a10.test/atlassian/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${USER_JWT}" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"1.0"}}}'
```

Expect: a JSON-RPC error with `TokenExchangeInfo.url` pointing to the Solo UI's `/age/elicitations` approval queue.

### Step 6: Approve the elicitation in the UI

Open `https://ui.agw.a10.test/age/elicitations`. A pending Atlassian elicitation should appear. Click **Authorize** → Atlassian's real browser consent (log in to your Atlassian site, grant Jira/Confluence scopes). Once approved, the token is stored.

**⚠️ Atlassian org-admin gate:** If consent shows *"Your organization admin must authorize access from this redirect URL"*, go to **admin.atlassian.com → Apps → AI settings → Rovo MCP server** and add `agw.a10.test` to the domain allowlist (self-service feature).

### Step 7: Retry the elicitation

Retry the curl call from Step 5:

```bash
curl -sk -X POST https://agw.a10.test/atlassian/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${USER_JWT}" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"1.0"}}}'
```

Expect: a real MCP `initialize` response (not an error) — the gateway attached your Atlassian token upstream.

**Proves:** end-to-end per-user Atlassian token exchange works.

## Architecture overview

**Phase 1: Eager-auth issuer (client auto-discovery)**

| Route | Frontend | Backend | What it does |
|-------|----------|---------|----------|
| `/mcp` | eager-auth (gateway = OAuth AS) | in-cluster test | Clients discover the gateway's OAuth, login via Okta, access the test server |
| `/.well-known/oauth-*` | serves OAuth metadata | — | Discovery endpoints for clients |

MCP Inspector and other clients see standard OAuth discovery and transparently redirect to Okta for login.

**Phase 2: Atlassian elicitation (per-user token exchange)**

| Route | Frontend | Backend | Token flow |
|-------|----------|---------|----------|
| `/atlassian/mcp` | JWT (plain Okta) | Atlassian MCP | Okta JWT → STS elicits Atlassian OAuth → per-user token stored → replayed |

No OAuth discovery on this route (plain JWT frontend only), so clients can't auto-login. This matches Solo's validated architecture for elicitation without eager-auth.

**Key files:**
- `10-mcp-everything.yaml` — in-cluster test server
- `40-eager-auth.sh` — Phase 1: Okta JWKS + eager-auth policy
- `50-atlassian.sh` — Phase 2: Atlassian backend + elicitation policy

## Phase 1 vs Phase 2: Why they don't share a frontend

**Phase 1 — Eager-auth issuer.** Clients discover standard OAuth metadata on the gateway, transparently redirecting to Okta for login. This is the full user-friendly flow.

**Phase 2 — Atlassian elicitation.** Uses a **plain JWT frontend** (no OAuth discovery) + a separate elicitation backend. This matches Solo's validated reference architecture (`test-elicitation-guide-mcp.md`).

**Why separate?** An earlier attempt combined eager-auth with elicitation on the same policy, hoping clients could do both (OAuth login + consent) transparently. But the controller's eager-auth DCR-caching machinery (`ent-controller/internal/issuer/flow_upstream.go`, line ~320) has a documented limitation: *"does not support multiple concurrent upstream clients for one resource."* Under automatic client retries (e.g., Claude Code's auto-discovery), concurrent DCR calls race and corrupt the cache, causing token-serve to fail with stale client IDs.

Solo's own validated doc achieves elicitation differently: plain JWT frontend (no DCR on the client path) + UI-mediated approval (no auto-discovery). This is simpler and avoids the race. Consequence: `/atlassian/mcp` requires manual token attachment (curl with `Authorization: Bearer`), not browser auto-discovery like Phase 1's `/mcp`.

Both routes coexist on the same cluster: Phase 1 is the user-friendly OAuth discovery model (good UX), Phase 2 is the working elicitation model (working over UX).

## Troubleshooting

**Phase 1 issues:**

- **`/oauth-issuer/register` 404** → `OAUTH_ISSUER=true` didn't take. Check: `kubectl get httproute -n agentgateway-system oauth-issuer` and controller logs for `KGW_OAUTH_ISSUER_CONFIG is not set`.
- **`GET /mcp` returns 406, not 401** → the JWT policy is misconfigured (likely a leading slash on `jwksPath`). `40-eager-auth.sh` should use `oauth2/<as-id>/v1/keys` (no slash).
- **Inspector redirects to Okta but login fails** → the Web app's redirect URIs don't match. Both must be registered in Okta:
  - `https://agw.<cluster>.test/oauth-issuer/callback/downstream`
  - `https://agw.<cluster>.test/oauth-issuer/callback/upstream`

**Phase 2 issues:**

- **Elicitation returns a direct Atlassian authorize URL instead of a Solo UI link** → the policy has `backend.mcp.authentication` on it. The file `50-atlassian.sh` must NOT set this field (see the architecture section above for why).
- **`TokenExchangeInfo.url` points to the wrong Solo UI hostname** → check the `.env` cluster name and ensure `solomog agentgateway:ui expose` was run with the correct `CLUSTER=` value.
- **Atlassian consent shows "org admin must authorize this redirect URL"** → add `agw.<cluster>.test` to admin.atlassian.com → Apps → AI settings → Rovo MCP server allowlist.
- **Token-serve fails with "no healthy backends"** → check the Snowflake `OAUTH_REDIRECT_URI` (if reusing that setup). For Atlassian, this typically means the backend target isn't resolving — run `kubectl get enterpriseagentgatewaybackend -n agentgateway-system` to verify.

**General:**

- Trace the proxy: `bash ../agw-okta-mcp/helpers/trace.sh on <cluster>` (re-run after any `solomog apply`).
- State store is SQLite in-memory, so OAuth state is lost if the controller restarts — re-consent. Add a `tokenExchange.database` block to the helmfile for persistent Postgres state.

## References

- [OKTA-SETUP.md](OKTA-SETUP.md) — Detailed Okta console steps for both apps
- [ATLASSIAN-SETUP.md](ATLASSIAN-SETUP.md) — Atlassian site setup and interactive elicitation walkthrough
- Plan: `agentgateway-mcp-pov-plan.md`
