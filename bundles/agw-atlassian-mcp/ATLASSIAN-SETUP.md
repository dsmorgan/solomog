# Atlassian setup — recreate runbook (Phase 2)

Atlassian's hosted remote MCP (`mcp.atlassian.com`, Jira/Confluence) as a per-user elicitation
backend, at `/atlassian/mcp` on the base host. Applied by `50-atlassian.sh`.

Frontend is a **plain Strict Okta JWT policy** (reusing Phase 1's `okta-jwks` backend) — not
eager-auth. Backend is `backend.tokenExchange.elicitation` against a **discovery-mode** secret
(`base_url` + upstream OAuth discovery + **Dynamic Client Registration**) — unlike Snowflake's
explicit-URL secret, there are **no client creds** to configure; the gateway registers itself
dynamically. This matches Solo's own **validated** reference,
`agentgateway-enterprise/dev-docs/tokenexchange/elicitation/test-elicitation-guide-mcp.md`, almost
exactly (their example is GitHub; same architecture).

> **No Atlassian OAuth app to create.** DCR means the gateway walks
> `mcp.atlassian.com/.well-known/oauth-authorization-server`, registers itself on the fly, and stores
> the resulting credentials. Nothing to pre-register on the Atlassian side.

**Why not eager-auth for this route:** an earlier version combined `backend.mcp.authentication`
(eager-auth) with elicitation on one policy. It got all the way to a real Atlassian consent screen
via Claude Code, but every attempt then hit a reproducible DCR client-id mismatch when serving the
token — root-caused to a documented limitation in the controller's DCR-caching path
(`ent-controller/internal/issuer/flow_upstream.go`: *"This codepath does not support multiple
concurrent upstream clients for one resource"*). Checking Solo's validated doc confirmed the intended
architecture is simpler: plain JWT frontend + UI-mediated elicitation. See the README's callout for
the full account.

---

## 0. Prerequisites
- Phase 1 (10/20/30/40) already applied — reuses its `okta-jwks` backend. (Phase 1's own eager-auth
  issuer machinery is otherwise unrelated to this phase.)
- The **Solo UI**, wired to Okta OIDC — per the validated doc, elicitation approval happens at
  `/age/elicitations`, mediated by a human clicking Authorize once. Bring it up:
  ```bash
  solomog agentgateway:ui expose ROUTE=true CLUSTER=a9 \
    TOKEN_EXCHANGE=true OAUTH_ISSUER=true TOKEN_EXCHANGE_API_VALIDATOR=remote
  ```
  (`OAUTH_ISSUER=true` is still needed at the controller level for DCR — see the README.)
- A cached Okta **user** token — this route has no OAuth-discovery hints, so no MCP client can
  auto-login against it. Mint one out-of-band, the same way agw-okta-mcp's OBO tests do:
  ```bash
  bash bundles/agw-okta-mcp/helpers/okta-pkce-login.sh
  ```
- A free Atlassian Cloud site with a little data (below).
- An Atlassian **organization admin** account for the one-time domain-allowlist step (§5) — if you
  created the site yourself, you already are one.

## 1. Create a free Atlassian Cloud site
- https://www.atlassian.com/software/jira/free (or Confluence free) — e.g. `your-name.atlassian.net`.
- Add a little data so tools have something to return: a **Jira project + a couple of issues** and/or
  a **Confluence space + a page**.
- You log in as this Atlassian account during consent — its access is what the elicited token represents.

## 2. OAuth app? — NOT needed
Dynamic Client Registration (RFC 7591) — see the callout above. The redirect used during DCR/consent
is the Solo UI's `https://ui.agw.a9.test/age/elicitations` — DCR registers it automatically.

## 3. Scopes
Default (override via `ATLASSIAN_SCOPES` in `.env`):
`read:jira-work read:confluence-content.summary offline_access` (`offline_access` → refresh token).
Read-only, safe for a PoV.

## 4. Endpoint path gotcha
Backend targets `https://mcp.atlassian.com/v1/mcp` (StreamableHTTP).
- `/v1/sse` is deprecated (support ends ~Jun 2026) — don't use it.
- If the handshake 404s, try `ATLASSIAN_MCP_PATH=/v1/mcp/authv2` in `.env` and re-apply.

## 5. Apply + test
```bash
solomog apply BUNDLE=agw-atlassian-mcp CLUSTER=a9   # picks up 50-atlassian.sh (additive; Phase 1 untouched)
solomog test  BUNDLE=agw-atlassian-mcp CLUSTER=a9
```

Test 30 checks the unauth 401. Test 40 uses the cached Okta token (§0) and expects the documented
elicitation-trigger shape: a JSON-RPC error whose `TokenExchangeInfo.url` points at the STS, not a
provider authorize URL directly.

## 6. Trigger + approve, following the validated doc's own steps

**Step 1 — trigger** (same curl-based approach the validated doc itself uses — no MCP client
auto-discovery here):
```bash
USER_JWT=$(jq -r .access_token .solomog/okta-user-token.json)
curl -sk -X POST https://agw.a9.test/atlassian/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${USER_JWT}" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl-client","version":"1.0"}}}'
```
Expect a JSON-RPC error containing `TokenExchangeInfo` with a `url` — that's the elicitation trigger.

**Step 2 — approve in the UI.** Open `https://ui.agw.a9.test/age/elicitations` → a pending Atlassian
elicitation should appear for your Okta identity → **Authorize** → Atlassian's real browser consent
(log into your Atlassian site, grant the Jira/Confluence scopes from §3) → redirect back → token stored.

## 7. Atlassian's own admin gate (not a solomog/gateway issue)
Even with DCR, Atlassian enforces an **org-level redirect-URL allowlist**. If consent shows:
> *"Your organization admin must authorize access from this redirect URL to this site..."*

Go to **admin.atlassian.com → Apps → AI settings → Rovo MCP server** and add `agw.a9.test` (or the
full callback URL, if it asks for that instead of a bare domain) to the allowlist. This is a
self-service feature Atlassian added recently — this exact scenario (custom OAuth redirect domain
via a self-hosted client against the remote MCP server) was a hard, unfixable block before that.

## 8. Retry
Re-run Step 1's curl command. This time it should succeed — a real MCP `initialize` response, not
another elicitation trigger.

## 9. What this proves
- **Elicitation triggers with the documented shape (test 40) + approval completes in the UI** →
  discovery/DCR elicitation works with the validated architecture — the piece that was missing
  before Phase 1's issuer infra existed.
- **The retried curl call succeeds with a real MCP response** → the gateway attached
  `Authorization: Bearer` to the Atlassian upstream — confirms the omit-`mode` fix (proven for
  Snowflake) generalizes to a DCR/discovery backend, on the validated (non-eager-auth) architecture.
- **Still failing after UI approval** → trace the proxy (`bash ../agw-okta-mcp/helpers/trace.sh on a9`
  — re-run after any `solomog apply`, since `30-proxy-sts.sh` rewrites the params CR and clears
  `RUST_LOG`) and check the outbound `client sending request → *.atlassian.com` headers for `authorization`.
