# Okta setup — Lab 1 (agw-okta-bedrock-llm)

This bundle reuses the **same Okta org and default authorization server**
(`/oauth2/default`) already configured for `agw-okta-mcp` — see that bundle's
[`OKTA-SETUP.md`](../agw-okta-mcp/OKTA-SETUP.md) if you're starting from scratch. This doc
only covers the **new** pieces this workshop needs on top of that: a `groups` claim, two
access-tier groups, and a dedicated device-authorization-grant app for the CLI token helper.

> Mirrors the gist's Lab 1 (Okta Setup), adapted to reuse your existing org instead of
> starting a fresh tenant.

---

## 1. Access-tier groups

**Directory → Groups → Add group** (create both):
- `llm-standard` — base tier. Add yourself.
- `llm-premium` — premium tier. Add yourself too (so you can test both routes as one user;
  in a real org this would be a smaller group).

---

## 2. `groups` claim on the default authorization server

**Security → API → Authorization Servers → `default` → Claims → Add Claim**
- Name: `groups` — this is what becomes `jwt.groups` in the gateway's CEL authorization
  rules (Lab 2), so the name must be exactly `groups`.
- Include in token type: **Access Token** — always.
- Value type: **Groups**
- Filter: **Starts with** → `llm-` (keeps the claim scoped to access-tier groups; doesn't
  leak every Okta group you happen to belong to).
- Include in: the same access policy rule(s) you use for the device app below (or *any
  scope* if you're not scoping it).

⚠️ Don't confuse this with `may_act` from the `agw-okta-mcp` setup — that one is reserved
by Okta and rejected. `groups` is a normal, supported claim name.

---

## 3. App E — Native OIDC, Device Authorization Grant (CLI token helper)

A dedicated public client, separate from App B (the PKCE app in `agw-okta-mcp`) — the
device flow doesn't need a loopback redirect listener, which is the point for headless CLI
tools (Claude Code, Cursor, Copilot).

**Applications → Create App Integration → OIDC - OpenID Connect → Native Application**
- **Grant type:** check **Device Authorization**. You can leave Authorization Code checked
  too (Okta's template defaults it on) or uncheck it — this app doesn't use it, and leaving
  it checked is harmless if you're not sure yet.
- No client secret (public client) — the client_id is safe to embed in the helper script.
- **Assignments:** allow yourself (or *Allow everyone in your organization*).
- Record **Client ID** → `.env` as `OKTA_DEVICE_CLIENT_ID`.

---

## 4. Access policy rule for App E

**Security → API → Authorization Servers → `default` → Access Policies** — add a rule (or
extend the existing "Default Policy") allowing:
- **Grant type:** Device Authorization (a.k.a. `urn:ietf:params:oauth:grant-type:device_code`)
- **Scopes:** include `openid`, `profile`, `offline_access` (the device-flow helper requests
  these — `offline_access` gets a refresh token so the CLI doesn't need a fresh device-code
  dance every time it expires) — or *Any scopes*.

---

## 5. Resulting `.env` additions

```
# App E (Native / Device Authorization Grant) — CLI token helper
OKTA_DEVICE_CLIENT_ID=<App E client id>

# Reused from the existing setup (see agw-okta-mcp/.env) — same org, same default AS:
#   OKTA_DOMAIN, OKTA_AUDIENCE
```

No client secret to capture — App E is a public client.

---

## Verify

```
https://<OKTA_DOMAIN>/oauth2/default/v1/device/authorize
```
should be reachable (part of the default AS's well-known config — no separate check needed
beyond the `.well-known/openid-configuration` one from the original setup).

Full end-to-end verification of the claim + groups happens in Lab 3 (token helper) once
Lab 2 (gateway policies) is in place to read `jwt.groups`.
