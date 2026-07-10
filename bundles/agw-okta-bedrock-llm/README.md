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
| 2b | Rate limiting (premium tier) | built (in `50-okta-jwt-authz.sh`, `rateLimit.local` 1k tokens/min — low so `40-` can trip it) |
| 3 | Token acquisition: device-authorization-grant helper script | built (`helpers/okta-device-login.sh`) — needs a live run to confirm |
| 4 | Tests: 401 / standard / premium / rate-limit | built — see `tests/`; 30- proves the `action: Allow` gate, needs a temporary llm-premium removal to run for real |
| 5 | Tool integration (Claude Code / Cursor / Copilot) | built — see [`TOOL-INTEGRATION.md`](TOOL-INTEGRATION.md) + [`helpers/ag-token.sh`](helpers/ag-token.sh) (apiKeyHelper, silent refresh). Claude Code `/v1/messages` path needs a live confirm |
| 6 | Scaling authorization patterns (CEL notes) | built — see [`AUTHZ-PATTERNS.md`](AUTHZ-PATTERNS.md) |

## Prerequisites

- Cluster with `agentgateway` installed + `expose`d (`solomog agentgateway expose CLUSTER=<name>`).
- AWS SSO Bedrock access configured (`aws configure sso` — see `llmroute-bedrock/README.md`)
  and refreshed (`solomog aws:refresh`).
- Okta Lab 1 complete (see `OKTA-SETUP.md`) — `OKTA_DOMAIN`, `OKTA_AUDIENCE`,
  `OKTA_DEVICE_CLIENT_ID` in `.env`.
- **Anthropic first-time-use (FTU) form submitted for the AWS account** (see below).

## Bedrock model access (inference profile required + per-region access)

Two facts about these Claude models on Bedrock that together explain the failures we hit:

1. **On-demand invocation REQUIRES an inference profile.** The bare foundation-model ID
   (`anthropic.claude-haiku-4-5-20251001-v1:0`) returns `400 "Invocation … with on-demand
   throughput isn't supported. Retry with … an inference profile"`. So the backends use the
   **`us.` Geo cross-region profile** (`us.anthropic.claude-haiku-4-5-20251001-v1:0`,
   `us.anthropic.claude-sonnet-5`). (Pinning to a single region on-demand is *only* possible via
   a user-created **application inference profile** — `aws bedrock create-inference-profile` — not
   a bare model ID.)
2. **Model access is per-REGION, and the `us.` profile routes across regions.** `region` is just
   the *entry* region; Bedrock routes the actual inference to any US destination — us-west-2 →
   {us-east-1, us-east-2, us-west-2}. Anthropic access (the use-case form, submitted once per
   account via the Bedrock console → Model catalog or `aws bedrock put-use-case-for-model-access`)
   is granted **per region**. If a request lands in a region without access, that region returns
   `404 "Model use case details have not been submitted…"` — hence the **intermittent** failures.

**What to do:** grant Anthropic model access in **all** destination regions of the profile
(us-east-1, us-east-2, us-west-2). `region` is set to **us-west-2** here to match the sibling
`bundles/llmroute-bedrock`, which works on this account.

**Models:** standard = Claude Haiku 4.5 (`us.anthropic.claude-haiku-4-5-20251001-v1:0`),
premium = Claude Sonnet 5 (`us.anthropic.claude-sonnet-5`).
