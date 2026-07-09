# agw-okta-bedrock-llm — tiered Bedrock access via Okta groups

Models the ["Fronting AWS Bedrock with Agentgateway + Okta SSO"](
https://gist.github.com/rvennam/45c206806a177c4084c723b170d9372f) workshop: developers get
an Okta-issued token via **device authorization grant** instead of AWS credentials; the
gateway validates the token, checks Okta **group membership** (`llm-standard` /
`llm-premium`) via CEL, and forwards to the matching Bedrock model — with a token-bucket
rate limit on the premium tier.

Built lab-by-lab, mirroring the workshop's own structure. Reuses patterns from
[`agw-okta-mcp`](../agw-okta-mcp/) (Okta JWT validation) and
[`llmroute-bedrock`](../llmroute-bedrock/) (Bedrock backend + SSO creds) rather than
reinventing them — the new ground this bundle covers is **CEL group-based authorization**,
**rate limiting**, and the **device-flow** token helper.

**Routing model note:** the workshop uses two ports (3000 standard / 3001 premium) — that's
the standalone agentgateway binary's `binds:` config. Solomog's `expose` model is one shared
gateway/host with path-based routing, so the two tiers become two **paths**
(`/bedrock/standard`, `/bedrock/premium`) on the same gateway instead of two ports.

## Status

| Lab | What | Status |
|---|---|---|
| 1 | Okta: device-flow app, `groups` claim, `llm-standard`/`llm-premium` groups | ✅ done — see [`OKTA-SETUP.md`](OKTA-SETUP.md) |
| 2 | Gateway: tiered backends + routes + JWT/CEL authorization policies | built, ⚠️ `action: Allow` semantics unverified — see files 10/11/20/21/50 |
| 2b | Rate limiting (premium tier) | built (in `50-okta-jwt-authz.sh`, `rateLimit.local` 100k tokens/min) |
| 3 | Token acquisition: device-authorization-grant helper script | built (`helpers/okta-device-login.sh`) — needs a live run to confirm |
| 4 | Tests: 401 / standard / premium / rate-limit | built — see `tests/`; 30- proves the `action: Allow` gate, needs a temporary llm-premium removal to run for real |
| 5 | Tool integration (Claude Code / Cursor / Copilot) | not yet built |
| 6 | Scaling authorization patterns (CEL notes) | not yet built |

## Prerequisites

- Cluster with `agentgateway` installed + `expose`d (`solomog agentgateway expose CLUSTER=<name>`).
- AWS SSO Bedrock access configured (`aws configure sso` — see `llmroute-bedrock/README.md`)
  and refreshed (`solomog aws:refresh`).
- Okta Lab 1 complete (see `OKTA-SETUP.md`) — `OKTA_DOMAIN`, `OKTA_AUDIENCE`,
  `OKTA_DEVICE_CLIENT_ID` in `.env`.
- **Anthropic first-time-use (FTU) form submitted for the AWS account** (see below).

## Bedrock model access (one-time, per AWS account)

Anthropic requires a **one-time use-case form** before the *first* invocation of any Anthropic
model on the standard `bedrock-runtime` path (which agentgateway uses). It is **per-account**,
not per-model — one submission covers Haiku, Sonnet, everything — and switching model IDs does
**not** bypass it. Symptom if missing: a `404` with *"Model use case details have not been
submitted for this account. Fill out the Anthropic use case details form…"* (the model ID
resolved fine; only the account gate failed).

Submit it once (needs Bedrock console/API perms on the account):
- **Console:** Bedrock → Model catalog → pick any Anthropic model → submit use-case details.
  Access is granted immediately (or "try again in ~15 min").
- **API:** `aws bedrock put-use-case-for-model-access …` (check with `get-use-case-for-model-access`).

The only path exempt from the FTU form is the newer `bedrock-mantle` endpoint, which
agentgateway's bedrock provider does not use.

**Models:** standard = Claude Haiku 4.5 (`us.anthropic.claude-haiku-4-5-20251001-v1:0`),
premium = Claude Sonnet 5 (`us.anthropic.claude-sonnet-5`). Sonnet 4.5 was deprecated Feb 2026;
Sonnet 5 uses the newer suffix-less CRIS ID.
