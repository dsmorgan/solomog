# Agentgateway MCP POV — Initial Build-Out Plan

Scope: get a minimally viable environment standing up the two near-term flows the customer asked about, using the solomog vcluster harness as the base. This is not the full north-star (tool registry, guardrails, cost governance, multi-agent isolation, policy-as-code) — it's the identity and connectivity spine those later capabilities will sit on top of.

---

## 1. First — a fit gap to raise with the account team before you build

The requirements list two things that don't compose cleanly today, and it's worth surfacing this early rather than discovering it mid-POV:

- The customer's own clarification says the AgentCore agent is **invoked using Boto3**.
- AWS's own docs are explicit that `invoke_agent_runtime` via Boto3 uses **SigV4 (IAM) auth only**. If the AgentCore Runtime is configured for JWT bearer / OAuth inbound auth instead, you cannot call it with Boto3 at all — you have to drop to a raw HTTPS call and pass the JWT in the `Authorization` header yourself.

That means "end-to-end JWT/OAuth token propagation from the KGateway API layer to the MCP Tool layer" cannot literally mean *the same Okta JWT rides Boto3 into AgentCore*. In practice, the FastAPI service has to do one of:

- **(a) Federate, don't propagate.** Validate the Okta JWT, then call `sts:AssumeRoleWithWebIdentity` (or your existing OIDC↔IAM federation setup) to get short-lived SigV4 credentials, and invoke AgentCore with Boto3 as normal. The user's identity is preserved as an *audit trail* (you know which Okta subject requested the AssumeRole), but the JWT itself stops at the FastAPI boundary.
- **(b) Bypass Boto3 for the JWT-carrying calls.** Configure the AgentCore Runtime with a custom JWT authorizer and call `InvokeAgentRuntime` over HTTPS directly with the Okta-issued bearer token, using Boto3 only for non-OAuth paths (or not at all).
- **(c) Split the claim.** "Propagation" happens on the agentgateway → MCP tool leg (which is real and well-supported — see §3), while the FastAPI → AgentCore leg is IAM-based and identity is carried as a custom header (`X-Amzn-Bedrock-AgentCore-Runtime-Custom-UserId` or similar) rather than a full JWT.

Any of these are workable for a POV, but they're different architectures with different audit stories. Worth a 15-minute call with the customer's security/architecture stakeholders to pick one before you build the FastAPI shim — it'll save a rebuild later. (a) is the least invasive and closest to what "OIDC-integrated IAM roles" already implies in their own wording, so it's the default assumption in the plan below unless you hear otherwise.

---

## 2. What's genuinely turnkey on the agentgateway side

Good news: the harder half of the requirements — agentgateway talking to SaaS MCP servers with OAuth, and JWT validation at the gateway — maps to existing, documented agentgateway capability. Four mechanisms, pick based on what each backend needs:

| Mechanism | Use for | How it works |
|---|---|---|
| **JWT auth** (`traffic.jwtAuthentication` on `EnterpriseAgentgatewayPolicy`, targeting `Gateway` or `HTTPRoute`) | Validating the Okta-issued JWT at the gateway edge, optional claim-based RBAC | Static JWKS or issuer URL; works with any standards-compliant OIDC issuer, so Okta is fine here even though it isn't in the short list of IdPs with full dynamic-client-registration support |
| **OBO delegation** (built-in STS, RFC 8693, `act` claim) | Agent calling an MCP tool server *as* the user, with both identities visible to policy | STS validates the user's Okta JWT via JWKS and mints its own delegated token. Okta doesn't need to support RFC 8693 itself — the STS does the minting — so **delegation works with Okta today**, same as impersonation does. Both depend only on JWKS validation of the subject token. |
| **OBO impersonation** (built-in STS, RFC 8693, `sub`-only) | Downstream only needs to know the user, not the agent | Same Okta dependency as delegation — STS-signed, not Okta-native |
| **Elicitations** (URL-mode OAuth via the STS) | Per-user, browser-consent OAuth to a third-party SaaS API whose auth flow is Authorization Code style | Gateway intercepts the first unauthenticated request, returns a consent URL, user completes OAuth in-browser, gateway stores and replays the resulting token keyed to (user, resource). Only fits backends that actually support user-delegated auth — see §4/§5 for why this rules out DealCloud. |

Two Okta-specific caveats worth carrying into the demo design:

- **Dynamic MCP client registration** (the "eager auth" flow for un-registered clients like Claude Code or MCP Inspector) is currently only tested against **Keycloak and Auth0**. Not a blocker here — this POV only needs JWT validation and OBO subject-token validation, both of which work with Okta — but don't assume the full MCP-client discovery/registration flow is validated against Okta out of the box.
- **External identity provider exchange** — the mechanism used when a *downstream* service needs a token actually minted by the original IdP (not an STS-signed token), because it lives in a different trust/identity domain — has a dedicated, documented code path for Entra (`spec.backend.tokenExchange.entra`) but not for Okta. There's an open, unshipped feature request (agentgateway-enterprise #7151, customer Leidos) tracking exactly this gap: Okta only trusts authorization servers within its own tenant, so a downstream that needs an Okta-native token (not an STS-signed one) can't get it through a documented path today — the customer's current workaround is a bespoke ext-auth shim plus an external token store. This only matters if a downstream in your demo specifically requires a token minted by Okta itself rather than one signed by agentgateway's STS — confirm with the customer whether either Snowflake or DealCloud needs that before you build toward it.

---

## 3. Target MVP architecture

Two parallel spines meeting at Okta as the shared IdP (see diagram above):

- **AgentCore spine**: User → FastAPI (validates Okta JWT, federates to IAM) → Boto3 `invoke_agent_runtime` → AgentCore Runtime → MCP tools/sample tools hosted in OCP.
- **Agentgateway spine**: Client → Agentgateway (JWT auth against Okta JWKS) → per-backend token exchange → MCP backend. Snowflake and DealCloud need *different* mechanisms here (see §4) — this spine isn't one uniform pattern, it's two.

For the vcluster/solomog build, everything on the agentgateway spine is buildable locally. The AgentCore spine needs a real AWS account with Bedrock AgentCore enabled — vind can host the OCP-style MCP tool servers that AgentCore's gateway/tools target, but not AgentCore Runtime itself.

---

## 4. What to obtain before building

- [ ] **AWS account/sandbox** with Bedrock AgentCore enabled, plus an IAM role trust policy set up (or a path to set one up) for OIDC federation from Okta — this is the piece most likely to be gated by someone else's approval, so request it first.
- [ ] **Okta developer org** (free tier is fine) — you need admin access to create an OIDC app, a custom authorization server or claims, and test users. Confirm whether Solo.io has a shared Okta dev tenant already, or spin up your own at developer.okta.com.
- [ ] **Solo Enterprise for agentgateway trial license** via `github.com/solo-io/licensing`, same pattern you've used before.
- [ ] **kind/vcluster harness time** — nothing new needed here beyond what solomog already gives you, but confirm the harness has outbound internet access for the elicitation OAuth consent redirect (it needs to reach Okta's `/authorize` endpoint from a browser, and the STS needs to reach Okta's token endpoint).
- [ ] **Snowflake trial account** — self-serve, 30-day, $400 credit, no payment info required (signup.snowflake.com). Use the real thing rather than a mock: Snowflake has native OAuth 2.0 support, and as `ACCOUNTADMIN` on the trial account you can run `CREATE SECURITY INTEGRATION TYPE = OAUTH` yourself to stand up a real authorization/token endpoint for agentgateway to talk to. Worth knowing for the pitch: Snowflake now supports flagging a custom OAuth integration as `IS_AGENTIC = TRUE`, which tells Snowflake to treat that client's calls as an AI agent acting on a user's behalf — a nice, on-point detail if the customer's security team asks how Snowflake itself thinks about agent identity.
- [ ] **DealCloud — plan to mock it.** There's no public self-serve developer or sandbox signup. DealCloud is a per-customer tenant ("site"); getting a client ID/secret requires an existing site and a user with Platform Manager/admin rights inside it. Getting that from the customer is possible but not something you can arrange yourself before the POV starts, so build a small mock MCP server that mimics DealCloud's real auth shape instead: DealCloud's API only supports the **OAuth2 client-credentials grant** (`POST /api/rest/v1/oauth/token`, `grant_type=client_credentials`, 15-minute token lifetime, no user consent screen at all). Match that shape in the mock so swapping in a real DealCloud sandbox later is a config change, not a rebuild. This also means DealCloud was never a fit for elicitations (browser-based per-user consent) — see §2/§5.
- [ ] **AgentCore CLI** (`@aws/agentcore`) for the runtime deploy path, and confirm which agent framework you're using underneath (Strands, LangGraph, etc.) since that affects the FastAPI wrapper.

---

## 5. Build sequence

**Phase 0 — Okta as shared IdP (do this first, it's the dependency for everything else)**
1. Create an OIDC app in Okta (Authorization Code + PKCE) representing the "user-facing" client.
2. Create a second app/API integration representing agentgateway's own OAuth client identity (needed for JWT auth's JWKS lookup — just need the issuer + JWKS URL, no special app type).
3. Pull the JWKS URL and issuer for later config: `https://<okta-domain>/oauth2/default/.well-known/openid-configuration`.
4. If pursuing IAM federation (§1 option a), set up an Okta-as-OIDC-provider trust in the target AWS account (`aws iam create-open-id-connect-provider`) and a role with a trust policy scoped to the Okta issuer/audience.

**Phase 1 — Agentgateway core in the vcluster**
1. Spin up a vcluster via solomog, install Solo Enterprise for agentgateway control plane (quick start guide pattern you already know).
2. Register two `AgentgatewayBackend` targets: one pointed at your real Snowflake trial account, one at a small mock DealCloud MCP server running in the vcluster (client-credentials token endpoint, matching DealCloud's real shape — see §4).
3. Apply an `EnterpriseAgentgatewayPolicy` with `traffic.jwtAuthentication` pointed at the Okta issuer/JWKS from Phase 0. Validate a real Okta-issued token gets through and a bad one gets a 401 — this is the same validation muscle you already built for Entra JWT.
4. Add OBO delegation config against the same Okta issuer for the subject-token side; confirm the STS can exchange a user token + agent actor identity for a delegated, downscoped token.
5. Configure the two backends with the mechanism each actually needs, not a uniform pattern: an elicitation-backed policy on the Snowflake backend (real browser OAuth consent against your trial account's security integration) to demonstrate user-delegated SaaS auth, and a client-credentials exchange against the mock DealCloud backend to demonstrate the service-account pattern. Use SQLite for the STS token store initially — swap to Postgres only if you need persistence across pod restarts for the demo.

**Phase 2 — AgentCore + FastAPI shim**
1. Stand up a minimal Strands (or your chosen framework) agent, deploy via the AgentCore CLI to get a Runtime ARN.
2. Decide inbound auth mode per §1 (SigV4 vs custom JWT authorizer) and build the FastAPI service accordingly — Okta token validation middleware, then either AssumeRoleWithWebIdentity + Boto3, or a direct HTTPS call with the bearer token forwarded.
3. Wire a sample OCP-hosted MCP tool that the AgentCore agent's gateway/tool config targets — this can be as small as one tool exposed from a pod in your vcluster if OCP itself isn't available yet; the auth pattern matters more than the runtime for a POV.

**Phase 3 — Tie the two spines together for the demo narrative**
1. Pick one end-to-end scenario that touches both spines (e.g., a user asks a question that requires the AgentCore agent to call a tool, and separately the same user's session queries a Snowflake-backed MCP tool through agentgateway) so the demo shows one coherent identity, not two disconnected proofs.
2. Instrument both paths with basic structured logging of the identity at each hop — you don't need OTEL/Datadog/Splunk integration yet (that's north-star scope), but capturing "who did what" in logs makes the identity-propagation story concrete when you walk stakeholders through it.

**Phase 4 — Validate token propagation end to end**
1. Confirm the Okta JWT's `sub`/claims are visible at: agentgateway (JWT auth logs), the OBO-delegated token (act claim present), and the FastAPI/IAM boundary (CloudTrail shows the correct federated principal).
2. Write down explicitly, for the customer readout, where the identity chain is unbroken (agentgateway → MCP tool) and where it necessarily changes shape (FastAPI → AgentCore, per §1) — that's a feature of the writeup, not a gap to hide.

---

## 6. Your personal ramp-up checklist

You've already got strong footing on Entra JWT validation, OBO with k8s service accounts, and MCP endpoint validation from the enterprise-agentgateway labs — this maps almost directly, swap Entra for Okta. Gaps to close:

- [ ] Read the agentgateway docs on [MCP auth](https://docs.solo.io/agentgateway/latest/mcp/auth/about/), [OBO delegation](https://docs.solo.io/agentgateway/latest/mcp/token-exchange/obo/delegation/), and [elicitations](https://docs.solo.io/agentgateway/latest/mcp/token-exchange/elicitations/overview/) in full — the elicitations flow in particular is new territory relative to your prior OBO work.
- [ ] Skim the `McpIDP` enum in the [agentgateway source](https://github.com/agentgateway/agentgateway/blob/main/crates/agentgateway/src/types/agent.rs) to understand exactly what breaks if Okta hits an untested edge case in the MCP OAuth spec compliance path.
- [ ] Get hands-on with AWS Bedrock AgentCore basics you likely haven't touched: Runtime deploy via the `agentcore` CLI, Inbound/Outbound Auth model, and the SigV4-vs-JWT constraint on `InvokeAgentRuntime` (this is genuinely easy to trip on — several other engineers on AWS re:Post have hit exactly this).
- [ ] Set up your own Okta developer org if you don't already have credentials to a shared one — get comfortable with its OIDC app types and custom claims/authorization server config, since your Entra experience won't map 1:1 (different terminology, different default claim shapes).
- [ ] Review `sts:AssumeRoleWithWebIdentity` and OIDC federation into AWS IAM if you haven't set this up before — this is the crux of the §1 gap and worth understanding cold before the customer conversation.
- [ ] Optional but useful: look at the CSL Behring and Morningstar GitHub issues referenced in agentgateway-enterprise (#7441, #761) — both are live customer patterns close to what you're building (external SaaS MCP behind a different IdP, ext-authz + MCP-level authorization by claims) and will save you rediscovering the same edges.
- [ ] Skim agentgateway-enterprise #7151 (Leidos, "Add Okta as a native token exchange provider") — it's the clearest write-up of where Okta-as-IdP genuinely hits a wall (cross-tenant authorization server trust) versus where it doesn't (plain JWT validation, RFC 8693 delegation/impersonation all work fine with Okta today).
- [ ] Spend 30 minutes in a Snowflake trial account setting up `CREATE SECURITY INTEGRATION TYPE = OAUTH` yourself before Phase 1 — it's a different mental model from Okta/Entra JWKS-based validation (Snowflake is *acting as* the OAuth authorization server here, not just a resource server), and you'll want that muscle memory before wiring agentgateway to it.

---

## 7. Open questions to bring back to the customer/account team

1. Confirm inbound auth mode for the AgentCore Runtime (SigV4 vs custom JWT authorizer) — this determines the FastAPI shim design (§1).
2. Does either Snowflake or DealCloud need a token actually minted by Okta itself (not an agentgateway STS-signed token)? If so, that's the external-IdP-exchange gap in §2 (no documented Okta path yet) rather than a same-day config item.
3. Can the customer provide a DealCloud sandbox site with API + Platform Manager access, or should the POV run entirely on the client-credentials mock described in §4? Worth asking early since there's no self-serve way to get this ourselves.
4. Is OCP actually available for the POV, or should the "OCP-hosted MCP tools" be simulated in the vcluster for now and migrated later?
