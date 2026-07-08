# Atlassian setup — recreate runbook (agw-atlassian-mcp bundle)

Atlassian's hosted remote MCP (`mcp.atlassian.com`, Jira/Confluence) as an elicitation backend. This is
Solo's documented consent-screen example. **Status: incomplete — see [README.md](README.md).** The
backend/route/policy/secret apply fine, but the browser consent is a no-op until the eager-auth OAuth
issuer is enabled (Atlassian uses discovery/DCR, which needs it). This doc covers the Atlassian-side
setup; README covers the gateway-side "how to complete".

Atlassian uses the elicitation secret's **discovery mode** (`base_url` + upstream OAuth discovery +
**Dynamic Client Registration**) — so, unlike Snowflake's explicit-URL secret, there are **no client
creds** to configure (the gateway registers itself dynamically once the issuer is enabled).

> **No secrets.** Because Atlassian uses DCR, there is **no OAuth app to create and no client
> id/secret** — nothing goes in `.env`. The gateway registers itself dynamically during the flow.

---

## 0. Prerequisites (already done on cluster a8)
- `agw-okta-mcp` applied with the Okta frontend (`50-okta-jwt.sh` → `okta-jwks` backend) and the STS
  enabled: `solomog agentgateway:ui CLUSTER=a8 TOKEN_EXCHANGE=true` (with `TOKEN_EXCHANGE_API_VALIDATOR=remote`).
- Solo UI wired to Okta OIDC (so the elicitation consent keys to your Okta `sub`) — see OKTA-SETUP §6.
- Proxy `STS_URI` wired (`88-snowflake-proxy-sts.sh`).
These are the same pieces the Snowflake flow uses; nothing new here.

## 1. Create a free Atlassian Cloud site
- Go to https://www.atlassian.com/software/jira/free (or Confluence free) and create a site, e.g.
  `your-name.atlassian.net`. Free tier is fine.
- Add a little data so tools have something to return: create one **Jira project + a couple of issues**
  and/or a **Confluence space + a page**. (Cortex-analyst-equivalent: the MCP tools read Jira/Confluence.)
- You log in as your Atlassian account during the browser consent — that account's access is what the
  elicited token represents.

## 2. OAuth app? — NOT needed
Atlassian's remote MCP server uses **Dynamic Client Registration** (RFC 7591). The agentgateway proxy
walks `mcp.atlassian.com/.well-known/oauth-authorization-server`, registers itself on the fly, and
stores the resulting credentials. So you do **not** create an OAuth 2.0 (3LO) app in the Atlassian
developer console for this flow. (That's the whole point of the discovery-mode elicitation secret.)

The **redirect** used during DCR/consent is the Solo UI's `https://ui.agw.<cluster>.test/age/elicitations`
(the global `CALLBACK_URL` already set for Snowflake) — DCR registers it automatically; nothing to
pre-register on the Atlassian side.

## 3. Scopes
Default (in `10-atlassian.sh`, override via `ATLASSIAN_SCOPES`):
`read:jira-work read:confluence-content.summary offline_access`
(`offline_access` → refresh token, matching Solo's documented example). Read-only, safe for a PoV.

## 4. Endpoint path gotcha
The bundle points the backend at `https://mcp.atlassian.com/v1/mcp` (StreamableHTTP).
- `/v1/sse` is the deprecated SSE endpoint (support ends ~Jun 2026) — don't use it.
- If the MCP handshake 404s or errors on connect, try the alternate path
  `ATLASSIAN_MCP_PATH=/v1/mcp/authv2` in `.env` and re-apply. (Atlassian docs reference both forms;
  we default to `/v1/mcp`.)

## 5. Apply + test
```
solomog apply BUNDLE=agw-okta-mcp     CLUSTER=a8   # foundation: Okta JWT + STS + okta-jwks (apply first)
solomog apply BUNDLE=agw-atlassian-mcp CLUSTER=a8   # this bundle (10-atlassian.sh)
```
> ⚠️ Consent will no-op until the eager-auth issuer is enabled (README "How to complete"). The steps
> below are the target flow once that's done.

Then, like Snowflake:
1. Mint a fresh Okta user token: `bash ../agw-okta-mcp/helpers/okta-pkce-login.sh` → `jq -r .access_token .solomog/okta-user-token.json`.
2. Point MCP Inspector at `https://agw.a8.test/atlassian/mcp` with `Authorization: Bearer <okta-token>`,
   call a tool → it should return an elicitation.
3. Open `https://ui.agw.a8.test/age/elicitations` → a pending **Atlassian** elicitation should appear →
   authorize → Atlassian browser consent (log in to your Atlassian site) → redirect back → token stored.
4. Retry the tool call → gateway replays the Atlassian token → a Jira/Confluence tool answers.

## 6. What this proves
- **Elicitation appears + consent completes + token stored** → the identity/elicitation half works
  (already proven with Snowflake too).
- **The retried tool call succeeds (a Jira/Confluence tool returns data)** → the gateway DID attach
  `Authorization: Bearer` to the Atlassian upstream → the Bearer-attach works here → the Snowflake
  failure is Snowflake-specific (config or Snowflake-side), NOT a general elicitation bug.
- **The retry still 401s with no upstream Bearer** (check `RUST_LOG=agentgateway=trace` on the proxy,
  look at the outbound `client sending request → *.atlassian.com` headers) → confirms the general
  attachment gap on a second, Solo-documented backend → strong evidence for the Solo bug report.

Trace recipe (same as the Snowflake investigation): patch `agentgateway-config`
EnterpriseAgentgatewayParameters `spec.env` to add `RUST_LOG=info,agentgateway=trace` (re-patch AFTER
any `solomog apply`, since `88-snowflake-proxy-sts.sh` rewrites that CR), retrigger, then grep the proxy
logs for the outbound `client sending request` line to `*.atlassian.com` and check for an `authorization` header.
