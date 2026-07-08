# agw-atlassian-mcp — Atlassian (Jira/Confluence) remote-MCP elicitation

Per-user browser-consent (elicitation) to Atlassian's hosted remote MCP server (`mcp.atlassian.com`),
brokered by agentgateway. Split out of `agw-okta-mcp` (2026-07-07) because Atlassian needs infrastructure
(the eager-auth OAuth issuer) that the Snowflake demo doesn't. Kept as a documented starting point.

## Status: ⚠️ INCOMPLETE (blocked on the eager-auth issuer)
- ✅ Backend / route / policy / elicitation secret apply cleanly (`10-atlassian.sh`).
- ✅ The `mode`-omission fix is in place (the same fix that made Snowflake work — see
  agw-okta-mcp and memory `snowflake-mcp-oauth-token-type-header`).
- ✅ The elicitation *record* materializes in the Solo UI (Pending, resource `atlassian-mcp-backend`).
- ❌ Clicking **Authorize** is a **no-op**. Atlassian uses the elicitation secret's **discovery mode**
  (`base_url` + upstream `.well-known/oauth-authorization-server` + **Dynamic Client Registration**),
  and building that consent URL requires the controller's **eager-auth OAuth issuer handler**, which is
  not enabled. Proof in the controller log: `KGW_OAUTH_ISSUER_CONFIG is not set, OAuth issuer handler
  will not be registered`.

Contrast: Snowflake works minimally because it uses **explicit-mode** elicitation (hardcoded
`authorize_url`/`access_token_url` + `client_id`/`secret`), which needs no issuer handler.

## Prerequisites
This bundle is **not standalone** — apply it on a cluster that already has the `agw-okta-mcp` foundation:
- `okta-jwks` AgentgatewayBackend (agw-okta-mcp/50-okta-jwt.sh) — the frontend JWT policy references it.
- STS enabled: `solomog agentgateway:ui CLUSTER=<c> TOKEN_EXCHANGE=true` with `TOKEN_EXCHANGE_API_VALIDATOR=remote`.
- Proxy `STS_URI` wired (agw-okta-mcp/88-snowflake-proxy-sts.sh).
- Solo UI wired to Okta OIDC (so consent keys to your Okta `sub`) — agw-okta-mcp OKTA-SETUP §6.
- A free Atlassian Cloud site with some Jira/Confluence data — see [ATLASSIAN-SETUP.md](ATLASSIAN-SETUP.md).
  No Atlassian OAuth app needed (DCR).

Apply: `solomog apply BUNDLE=agw-atlassian-mcp CLUSTER=<c>` (after agw-okta-mcp).

## How to complete it (the remaining work)
Enable the **eager-auth OAuth issuer** so discovery/DCR consent can run. Reference implementation:
`~/code/fe-enterprise-agentgateway-workshop/labs/mcp/mcp-eager-auth-okta.md` (Steps 3–8). In solomog terms:
1. **Controller `KGW_OAUTH_ISSUER_CONFIG`** — add via the agentgateway helmfile `controller.extraEnv`
   (gateway_config.base_url = `https://<gw-host>/oauth-issuer`; client_config.clients = a pre-registered
   Okta client_id/secret; downstream_server → Okta authorize/token URLs).
2. **A database for OAuth flow state** — Postgres, or SQLite in-memory (omit the DB block). The workshop
   uses `tokenExchange.database`.
3. **`/oauth-issuer` HTTPRoute** → the `enterprise-agentgateway` controller service on `:7777`.
4. **A confidential Okta app** with **both** callbacks registered:
   `https://<gw-host>/oauth-issuer/callback/downstream` and `.../callback/upstream`.
5. **Switch this bundle's frontend to eager-auth** — replace the `traffic.jwtAuthentication` block in
   `10-atlassian.sh` with `backend.mcp.authentication` (issuer=Okta, jwks=okta-jwks) +
   `resourceMetadata.agentgateway.dev/issuer-proxy` → `:7777/oauth-issuer`, and add the
   `/.well-known/oauth-protected-resource/atlassian/mcp` + `/.well-known/oauth-authorization-server/atlassian/mcp`
   route matches (with a CORS filter allowing `mcp-protocol-version` + `Authorization`).

⚠️ Open question for Solo (worth confirming before building): does discovery-mode *elicitation*
specifically require `KGW_OAUTH_ISSUER_CONFIG`, or only the frontend eager-auth? The controller log
ties them, but it's unverified whether the issuer is needed purely for the outbound DCR to Atlassian.

## Test (once complete)
Fresh Okta token → MCP Inspector at `https://agw.<c>.test/atlassian/mcp` → connect (eager-auth OAuth to
Okta) → call a tool → elicitation → **Authorize** now redirects to Atlassian's consent → log into your
Atlassian site → redirect back → retry → a Jira/Confluence tool returns data. Trace the outbound
`→ *.atlassian.com` request (helpers `trace.sh` in agw-okta-mcp) to confirm `Authorization: Bearer` is attached.
