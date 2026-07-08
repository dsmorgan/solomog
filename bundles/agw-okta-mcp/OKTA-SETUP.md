# Okta setup — recreate runbook (agw-okta-mcp)

Everything configured on the **Okta side** for this bundle, in order, so the identity setup can
be rebuilt from scratch in any Okta org. Written generic; the example values in `[...]` are the
dev org this was first built against (`integrator-5185242.okta.com`).

> **Secrets:** client IDs are fine to record; **client secrets are NOT in this doc** — they go
> straight into `.env` (gitignored). See the `.env` block at the bottom for what to capture.

All of this uses Okta's built-in **custom "default" authorization server** (`/oauth2/default`)
— it mints real JWT access tokens with a JWKS endpoint and a configurable `aud`. The *org*
authorization server (`https://<domain>/`) is NOT used (its tokens are for Okta's own APIs).

---

## 0. Prerequisites

- An Okta org with admin access (free developer org is fine: developer.okta.com).
- Note your **org domain** (no scheme), e.g. `dev-1234567.okta.com` — top-right account menu,
  drop any `-admin`. `[integrator-5185242.okta.com]`
- Confirm the default AS resolves:
  `https://<domain>/oauth2/default/.well-known/openid-configuration`

---

## 1. Custom scope on the default authorization server

**Security → API → Authorization Servers → `default` → Scopes → Add Scope**
- Name: `mcp.access`  (any name; must match `OKTA_SCOPE` / the PKCE `OKTA_USER_SCOPES`)
- Leave the rest default. Save.

Client-credentials **requires** a granted scope (the OIDC defaults like `openid`/`profile`
don't apply to machine-to-machine). This scope is also requested by the user PKCE flow.

---

## 2. App A — API Services (machine-to-machine) — for edge JWT + client-credentials tests

**Applications → Create App Integration → API Services** → create.
- Record **Client ID**  `[0oa14x0odzo3BaaU0698]` and **Client secret** → into `.env`.
- **General → General Settings → Client Credentials:** ensure **Client authentication =
  "Client secret"** (NOT public key / private key) — the tests use `client_id:client_secret`
  HTTP Basic auth.
- ⚠️ **General → General Settings → Proof of possession:** **UNCHECK** *"Require Demonstrating
  Proof of Possession (DPoP) header in token requests."*
  API Services apps default this ON, which makes a plain client-credentials call fail
  `400 invalid_dpop_proof`. We want a plain Bearer token, so turn it off.

---

## 3. App B — Native OIDC (public + PKCE) — for the user Auth Code + PKCE login

**Applications → Create App Integration → OIDC - OpenID Connect → Native Application** → next.
- **Grant type:** Authorization Code (PKCE is required automatically for Native; no secret).
- **Sign-in redirect URI:** `http://localhost:8888/callback`
  ⚠️ The Native template pre-fills a mobile custom-scheme URI (`com.okta.<org>:/`). Replace/add
  the loopback `http://localhost:8888/callback` (loopback HTTP is allowed for Native per
  RFC 8252) — it must match `OKTA_REDIRECT_URI` and the helper's listener.
- **Sign-out redirect URI:** unused by us; leave the default or clear it.
- **Assignments → Controlled access:** *Allow everyone in your organization to access* (so you
  can log in as yourself). Federation Broker Mode may stay on (auth-only; doesn't affect tokens).
- Record **Client ID** `[0oa14x7ep8ufzL7kU698]` → `.env` as `OKTA_USER_CLIENT_ID`.

---

## 4. Access policy rules on the default authorization server

**Security → API → Authorization Servers → `default` → Access Policies.** Ensure a policy
applies to these apps (the shipped "Default Policy" covers *All clients*, or scope it to Apps
A + B), and add rule(s) allowing:
- **Grant type: Client Credentials** — for App A.
- **Grant type: Authorization Code** — for App B.
- **Scopes:** either *Any scopes*, or the explicit set including `mcp.access` (and `openid`
  for the user flow). NOTE: the OIDC default scopes shown in a new rule (`openid`, `profile`,
  …) do **not** include `mcp.access` — add it or choose *Any scopes*, else token requests for
  `mcp.access` are denied.

Both grants can live in one rule (check both boxes) or two separate rules.

---

## 5. Claims — the `may_act` limitation (delegation)

We attempted to add a `may_act` claim (needed for OBO **delegation** — the agentgateway STS
requires it to authorize the agent actor):

**Security → API → Authorization Servers → `default` → Claims → Add Claim** → name `may_act`.

➡️ **Okta REJECTS this:** *"may_act is reserved and cannot be used."* Okta reserves `may_act`
for its own native RFC 8693 token-exchange (it's a system claim). So **native Okta delegation
is not possible** — see README "Delegation". Impersonation needs no `may_act` and works.
No claim is created here; this step is recorded so the limitation isn't rediscovered.

(If delegation is ever required: inject `may_act` via a Token Inline Hook or an ext-auth shim
— details in the README.)

---

## 6. Solo UI OIDC — two apps to log the UI in as an Okta identity (for elicitation)

> **Why:** browser-consent **elicitation** (e.g. Snowflake) stores the elicited SaaS token keyed
> by the user's `sub`. The Solo UI drives that consent, so it must authenticate the user as the
> **same Okta identity** as the MCP-request JWT — otherwise the token lands under the UI's dev
> "autoauth" identity and is never found on replay. Per Solo's elicitation docs, the UI is wired
> to the **same IdP** (this Okta default AS) as the route JWT and the STS `apiValidator`. This is
> only needed for the visible elicitation e2e; the edge-JWT and OBO steps above don't require it.

The `management` chart wants **two** OIDC clients — a confidential **backend** and a public
**frontend** (chart keys `ui.backend.oidc.clientId` / `ui.frontend.oidc.clientId`).

### 6a. App C — UI backend — OIDC **Web** (confidential)
**Applications → Create App Integration → OIDC - OpenID Connect → Web Application** → next.
- **Grant type:** Authorization Code.
- **Sign-in redirect URI:** the UI's OIDC callback on the UI host. ⚠️ **Exact path not yet
  confirmed** — see 6c for how to capture it. Start with `https://ui.agw.<cluster>.test/callback`
  (`[https://ui.agw.a8.test/callback]`); you'll correct it in 6c if Okta rejects it.
- **Assignments:** allow your user (see 6c).
- Record **Client ID** → `.env` `SOLO_UI_OIDC_BACKEND_CLIENT_ID`, **Client secret** → `.env`
  `SOLO_UI_OIDC_BACKEND_CLIENT_SECRET` (secret never leaves `.env`).

### 6b. App D — UI frontend — OIDC **SPA** (public / PKCE)
**Applications → Create App Integration → OIDC - OpenID Connect → Single-Page Application** → next.
- **Grant type:** Authorization Code (PKCE; no secret).
- **Sign-in redirect URI:** the frontend's callback on the same UI host — same caveat as 6a; use
  the same value you settle on there unless the network trace (6c) shows a distinct frontend path.
- Record **Client ID** → `.env` `SOLO_UI_OIDC_FRONTEND_CLIENT_ID`.

### 6c. Assignments, redirect-URI discovery, and (optional) groups
- **Assignments (both apps):** **Assignments → Assign → People / Groups** → add yourself
  (`david.morgan@solo.io`), or *Allow everyone in your organization*. Without an assignment Okta
  returns `access_denied` on login.
- **Pin the exact redirect URI (do this once the UI is running):** browse to
  `https://ui.agw.<cluster>.test`; the UI bounces you to Okta. If the redirect URI is wrong Okta
  shows *"The 'redirect_uri' parameter must be a Login redirect URI…"* and the browser URL contains
  the exact `redirect_uri=…` it sent — **copy that value verbatim** into the app's Sign-in redirect
  URIs (backend and, if different, frontend). This is the same class of issue that bit the
  eager-auth lab; register the *actual* callback rather than guessing.
- **Roles (optional):** the PoV default grants every authenticated user `global.Admin`
  (`SOLO_UI_OIDC_ROLE_MAPPER=["global.Admin"]`, the bundle default). For group-based roles instead:
  add a **Groups** claim on the default AS (Claims → Add Claim → name `Groups`, value e.g.
  `Groups`/a filter), add `groups` to `SOLO_UI_OIDC_ADDITIONAL_SCOPES`, and set
  `SOLO_UI_OIDC_ROLE_MAPPER` to the chart default `claims.Groups.transformList(i, v, v in rolesMap, rolesMap[v])`.

Apply with `solomog agentgateway:ui CLUSTER=<cluster>` (re-runs the management chart with OIDC).
After it rolls, the UI login should redirect to **Okta**, not autoauth.

---

## 7. Resulting `.env` values

After the above, capture these (block is in `.env.example`):

```
# App A (API Services / m2m) + scope + default-AS audience
OKTA_DOMAIN=<your-domain>                 # [integrator-5185242.okta.com]
OKTA_CLIENT_ID=<App A client id>
OKTA_CLIENT_SECRET=<App A client secret>
OKTA_SCOPE=mcp.access
OKTA_AUDIENCE=                            # blank → defaults to api://default

# App B (Native OIDC / PKCE) for the user login helper
OKTA_USER_CLIENT_ID=<App B client id>
OKTA_USER_CLIENT_SECRET=                  # blank for Native/public
OKTA_REDIRECT_URI=                        # blank → http://localhost:8888/callback
OKTA_USER_SCOPES=                         # blank → "openid profile email mcp.access"

# agentgateway STS subject validator points at this same default AS's JWKS
TOKEN_EXCHANGE_JWKS_URL=https://<your-domain>/oauth2/default/v1/keys

# Elicitation: apiValidator also validates against this same Okta JWKS (defaults to
# TOKEN_EXCHANGE_JWKS_URL when remote) — the UI signs its STS calls with Okta tokens once
# OIDC'd. Set API_VALIDATOR=remote to turn it on.
TOKEN_EXCHANGE_API_VALIDATOR=remote

# App C (UI backend, Web/confidential) + App D (UI frontend, SPA/public) — Solo UI → Okta OIDC
SOLO_UI_OIDC_ISSUER=https://<your-domain>/oauth2/default   # same AS as the route JWT
SOLO_UI_OIDC_BACKEND_CLIENT_ID=<App C client id>
SOLO_UI_OIDC_BACKEND_CLIENT_SECRET=<App C client secret>
SOLO_UI_OIDC_FRONTEND_CLIENT_ID=<App D client id>
SOLO_UI_OIDC_ADDITIONAL_SCOPES=                          # blank → ["profile","email"]
SOLO_UI_OIDC_ROLE_MAPPER=                                # blank → ["global.Admin"] (all users admin)
```

Verify the whole chain by fetching a token and running the bundle tests (README "Verify").

---

## Gotchas recap (all bit us at least once)

| Symptom | Cause | Fix |
|---|---|---|
| `400 invalid_dpop_proof` on client-credentials | API Services app defaults to requiring DPoP | Uncheck Proof of Possession on App A (step 2) |
| Token request denied / missing `mcp.access` | new access-policy rule lists only OIDC default scopes | Add `mcp.access` or pick *Any scopes* (step 4) |
| No copyable client secret on App A | app created with public/private key auth | Switch Client authentication to "Client secret" (step 2) |
| Okta rejects `may_act` claim | `may_act` is a reserved system claim | Native delegation not possible; use inline hook/ext-auth (step 5) |
| PKCE redirect rejected | Native template used a mobile custom-scheme redirect | Set sign-in redirect to `http://localhost:8888/callback` (step 3) |
| Elicitation completes but UI shows "No elicitations" / token not replayed | UI logged in via dev **autoauth**, so its `sub` ≠ the Okta `sub` on the MCP JWT — token stored under wrong identity | Wire the UI to Okta OIDC (step 6): two Okta apps + `SOLO_UI_OIDC_*` in `.env` |
| UI login → Okta `access_denied` | user/group not assigned to the UI app | Assign yourself (or "everyone") on Apps C **and** D (step 6c) |
| UI login → *"redirect_uri must be a Login redirect URI"* | registered redirect ≠ the UI's actual callback | Copy the exact `redirect_uri=…` from the Okta error/browser URL into the app (step 6c) |
