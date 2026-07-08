# Elicitation `tokenExchange.mode` — semantics, the gotcha, and docs feedback

**Not a code bug.** The `mode` field behaves exactly as documented. We lost time to it because of a
**docs inconsistency** + the "Both is the default (omit the field)" being non-obvious. This note captures
the accurate story for the PoV record and as tidy feedback for the agentgateway/docs team.

## The modes (as documented + as coded — they agree)
`EnterpriseAgentgatewayPolicy.spec.backend.tokenExchange.mode`:

| `mode` | Elicits (browser consent)? | Injects the token upstream? | Docs description |
|---|---|---|---|
| *(omitted / default)* | ✅ | ✅ | *"whether to elicit, exchange, or **both (default)**"* |
| `ElicitationOnly` | ✅ | ❌ | *"token exchange should **not** be performed, just eliciting the user to do the auth flow"* |
| `ExchangeOnly` | ❌ | ✅ | *"elicitation errors should not be returned to the user"* |

Source of truth: enterprise `schema/config.md` and the Solo API reference
(docs.solo.io/agentgateway/2.3.x/reference/api/solo/). Code: `crates/agentgateway/src/proxy/token_exchange.rs`
`expand_mode()` → ElicitOnly = `(should_exchange=false, should_elicit=true)`; injection in `handle_request()`
is gated on `should_exchange`. So `ElicitationOnly` elicits but never injects — **by design, matching the docs.**

## What bit us
The elicited token was fetched (STS `200 served elicitation token`) but never appeared on the upstream
`Authorization` header → Snowflake `401` / `390146 "Bearer token is missing"`. Root cause: our policy set
`mode: ElicitationOnly`, so injection was intentionally skipped.

**Where we got `ElicitationOnly` from:** the docs' own **consent-screen** example uses it. The **setup**
example omits `mode`. Following consent-screen verbatim → elicit-but-never-inject.

## The fix (correct config)
**Omit `mode`** → default → elicit AND inject:
```yaml
backend:
  tokenExchange:
    elicitation:
      secretName: <secret>      # no `mode:` field
```
Confirmed working: Snowflake Cortex Analyst returns answers; trace shows `Authorization: Bearer` on the
upstream. (`90-snowflake.sh` in this bundle is the working reference.)

## Feedback worth raising with the team (docs/UX, not a code defect)
1. **Docs inconsistency** — the elicitation **consent-screen** page uses `mode: ElicitationOnly` while the
   **setup** page omits `mode`. The consent-screen example, followed literally, elicits but never
   authenticates the backend (401). Suggest: make the consent-screen example omit `mode` too, or add a
   note that `ElicitationOnly` intentionally does not inject.
2. **Discoverability of "Both"** — there's no enum value for the common case (elicit + inject); you get it
   by *omitting* the field. Easy to miss. Suggest either an explicit value (e.g. `ElicitAndExchange`) or a
   prominent callout that the default (unset) is the one you almost always want for backend SaaS elicitation.
3. **`ElicitationOnly`'s purpose is unclear** — "elicit but don't inject" has no obvious standalone use.
   Worth a doc sentence on when you'd actually choose it.

## Related findings (from the same investigation — separate from the above)
- **Discovery-mode elicitation needs the eager-auth issuer.** A discovery-mode secret (`base_url` +
  upstream `.well-known/oauth-authorization-server` + DCR, e.g. Atlassian) can't build a consent URL
  unless the controller has `KGW_OAUTH_ISSUER_CONFIG` (log when missing: *"KGW_OAUTH_ISSUER_CONFIG is not
  set, OAuth issuer handler will not be registered"*). Explicit-mode secrets (Snowflake) work without it.
  Worth confirming whether that coupling is intended/documented. (See the `agw-atlassian-mcp` bundle.)
- **Snowflake REST v2 companion header.** Requires `X-Snowflake-Authorization-Token-Type: OAUTH` alongside
  the Bearer, added via `backend.transformation.request.add` (value is CEL → nested-quote the literal:
  `"'OAUTH'"`). Not agentgateway's issue — a Snowflake requirement + a CEL-quoting gotcha.
