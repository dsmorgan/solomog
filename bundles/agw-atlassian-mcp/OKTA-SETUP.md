# Okta setup — recreate runbook (agw-atlassian-mcp)

Everything configured on the **Okta side** for this bundle. This bundle reuses the same eager-auth setup (Apps A & B) from agw-okta-mcp's Phase 1, plus UI OIDC apps (Apps C & D) for elicitation approval — all working against the default authorization server.

> **Secrets:** client IDs are fine to record; **client secrets are NOT in this doc** — they go straight into `.env` (gitignored). See the `.env` block at the bottom for what to capture.

---

## 0. Prerequisites

- An Okta org with admin access (free developer org is fine: developer.okta.com).
- Note your **org domain** (no scheme), e.g. `dev-1234567.okta.com` — top-right account menu, drop any `-admin`. `[integrator-5185242.okta.com]`
- Confirm the default AS resolves:
  `https://<domain>/oauth2/default/.well-known/openid-configuration`

---

## 1. Custom scope on the default authorization server

**Security → API → Authorization Servers → `default` → Scopes → Add Scope**
- Name: `mcp.access`  (must match `OKTA_AUDIENCE` in the gateway config)
- Leave the rest default. Save.

Required for both eager-auth (Phase 1) and client-credentials tests.

---

## 2. App A — API Services (machine-to-machine) — eager-auth broker credential

**Applications → Create App Integration → API Services** → create.
- Record **Client ID** `[0oa14x0odzo3BaaU0698]` and **Client secret** → into `.env`.
- **General → General Settings → Client Credentials:** ensure **Client authentication = "Client secret"** (NOT public key / private key).
- ⚠️ **General → General Settings → Proof of possession:** **UNCHECK** *"Require Demonstrating Proof of Possession (DPoP) header in token requests."*
  API Services apps default this ON, which makes a plain client-credentials call fail `400 invalid_dpop_proof`. We want a plain Bearer token, so turn it off.

---

## 3. App B — Web app (confidential) — eager-auth downstream OAuth callback

**Applications → Create App Integration → OIDC - OpenID Connect → Web Application** → next.
- **Grant type:** Authorization Code.
- **Sign-in redirect URIs:** both of these (eager-auth needs two callback paths):
  - `https://agw.<cluster>.test/oauth-issuer/callback/downstream`
  - `https://agw.<cluster>.test/oauth-issuer/callback/upstream`
  ⚠️ Replace `<cluster>` with your actual cluster name (e.g. `a9`, `a10`).
- **Assignments → Controlled access:** *Allow everyone in your organization to access* (so you can log in).
- Record **Client ID** `[0oa14x7ep8ufzL7kU698]` → `.env` as `OAUTH_ISSUER_CLIENT_ID`, **Client secret** → `.env` as `OAUTH_ISSUER_CLIENT_SECRET`.

---

## 4. Access policy rules on the default authorization server

**Security → API → Authorization Servers → `default` → Access Policies.** Ensure a policy applies to Apps A and B (the shipped "Default Policy" covers *All clients*), and add rule(s) allowing:
- **Grant type: Client Credentials** — for App A.
- **Grant type: Authorization Code** — for App B.
- **Scopes:** either *Any scopes*, or the explicit set including `mcp.access`.

---

## 5. Solo UI OIDC — two apps to log the UI in as an Okta identity (Phase 2 elicitation approval)

Browser-consent **elicitation** stores the elicited Atlassian token keyed by the user's `sub`. The Solo UI must authenticate as the **same Okta identity** as the MCP-request JWT — so it needs two OIDC apps.

### 5a. App C — UI backend — OIDC **Web** (confidential)

**Applications → Create App Integration → OIDC - OpenID Connect → Web Application** → next.
- **Grant type:** Authorization Code.
- **Sign-in redirect URI:** `https://ui.agw.<cluster>.test/oauth/callback` (replace `<cluster>`)
- **Assignments:** add yourself (`david.morgan@solo.io`), or *Allow everyone in your organization*.
- Record **Client ID** → `.env` `SOLO_UI_OIDC_BACKEND_CLIENT_ID`, **Client secret** → `.env` `SOLO_UI_OIDC_BACKEND_CLIENT_SECRET`.

### 5b. App D — UI frontend — OIDC **SPA** (public / PKCE)

**Applications → Create App Integration → OIDC - OpenID Connect → Single-Page Application** → next.
- **Grant type:** Authorization Code (PKCE; no secret).
- **Sign-in redirect URI:** same as 5a, `https://ui.agw.<cluster>.test/oauth/callback`.
- **Assignments:** add yourself (or *Allow everyone*).
- Record **Client ID** → `.env` `SOLO_UI_OIDC_FRONTEND_CLIENT_ID`.

### 5c. Redirect-URI discovery (once the UI is running)

Browse to `https://ui.agw.<cluster>.test`; the UI bounces you to Okta. If the redirect URI is wrong Okta shows *"The 'redirect_uri' parameter must be a Login redirect URI…"* — the browser URL contains the exact `redirect_uri=…` it sent. **Copy that value verbatim** into both App C and App D's Sign-in redirect URIs.

---

## 6. Resulting `.env` values

After the above, capture these (block is in `.env.example`):

```
# Phase 1: Eager-auth issuer (App A + B)
OKTA_DOMAIN=<your-domain>                         # [integrator-5185242.okta.com]
OKTA_AUDIENCE=api://default                       # default AS audience
OAUTH_ISSUER_CLIENT_ID=<App B client id>          # Web app for eager-auth
OAUTH_ISSUER_CLIENT_SECRET=<App B client secret>

# Phase 2: Solo UI OIDC + elicitation (Apps C & D)
SOLO_UI_OIDC_ISSUER=https://<your-domain>/oauth2/default
SOLO_UI_OIDC_BACKEND_CLIENT_ID=<App C client id>
SOLO_UI_OIDC_BACKEND_CLIENT_SECRET=<App C client secret>
SOLO_UI_OIDC_FRONTEND_CLIENT_ID=<App D client id>
SOLO_UI_OIDC_ADDITIONAL_SCOPES=["profile","email"]
SOLO_UI_OIDC_ROLE_MAPPER=["global.Admin"]         # all users are admin

# STS (Phase 2) validates Okta tokens
TOKEN_EXCHANGE_JWKS_URL=https://<your-domain>/oauth2/default/v1/keys
TOKEN_EXCHANGE_API_VALIDATOR=remote               # UI's STS calls validated against Okta JWKS
```

Verify by running the README's Phase 1 test (MCP Inspector) and Phase 2 flow (UI approval → curl retry).

---

## Gotchas recap

| Symptom | Cause | Fix |
|---|---|---|
| `400 invalid_dpop_proof` on client-credentials | API Services app defaults to requiring DPoP | Uncheck Proof of Possession on App A (step 2) |
| Eager-auth login redirects to Okta but fails | Web app's redirect URIs don't match — both paths required | Register both `*/callback/downstream` and `*/callback/upstream` in App B (step 3) |
| Phase 1 test (MCP Inspector) hangs or 404s | `OAUTH_ISSUER=true` not set on the controller | Run `solomog agentgateway OAUTH_ISSUER=true CLUSTER=<cluster>` (see README step 1) |
| UI login → Okta `access_denied` | user/group not assigned to the UI apps | Assign yourself on Apps C **and** D (step 5a/b) |
| UI login → *"redirect_uri must be a Login redirect URI"* | registered redirect ≠ the UI's actual callback | Copy the exact `redirect_uri=…` from the Okta error into Apps C & D (step 5c) |
| Phase 2 elicitation completes but token not replayed | Token stored under wrong identity (UI logged in as dev autoauth, not the Okta `sub` from the MCP JWT) | Ensure `TOKEN_EXCHANGE_API_VALIDATOR=remote` and UI is logged in as the same Okta user as the test |
