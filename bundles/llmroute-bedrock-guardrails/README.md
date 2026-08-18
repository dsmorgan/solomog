# llmroute-bedrock-guardrails — AWS Bedrock Guardrails, both attach points

Agentgateway as an LLM gateway in front of AWS Bedrock, with **the same AWS guardrail applied
two different ways** so the two enforcement paths can be compared side by side. Built from
[`llmroute-bedrock`](../llmroute-bedrock/) (Bedrock backends + SSO credential refresh), which
stays as the unguarded control.

Phase 1 is **Bedrock guardrails only**. Agentgateway's `promptGuard` also supports `regex`,
`webhook`, `openAIModeration`, `googleModelArmor`, and (enterprise-only, via `entPromptGuard`)
`purviewDlp` — all deferred, see [Not built yet](#not-built-yet).

## The two attach points

| | Attach point 1 — native passthrough | Attach point 2 — gateway promptGuard |
|---|---|---|
| Field | `spec.ai.provider.bedrock.guardrail` on the Backend | `promptGuard.request[]/response[].bedrockGuardrails` on an `EnterpriseAgentgatewayPolicy` |
| Who enforces | **Bedrock**, as part of the model invocation | **The gateway**, via an out-of-band ApplyGuardrail call |
| Round trips | one | two (guard, then model) |
| `region` | inherited from the provider — no field | **required** |
| Credentials | the backend's `policies.auth.aws` | its **own** `policies.auth.aws`, separate from the backend's |
| Providers | Bedrock only | any provider (OpenAI, Anthropic, Vertex…) |
| A block looks like | HTTP 200 + Bedrock's `blockedInputMessaging` | HTTP **403** + the message set in the policy |
| File | [`12-bedrock-guarded-backend.yaml.tmpl`](12-bedrock-guarded-backend.yaml.tmpl) | [`42-promptguard-bedrock.yaml.tmpl`](42-promptguard-bedrock.yaml.tmpl) |

The credential row is the one to keep in mind: in attach point 2 the guardrail authenticates
**separately from the model call**, so a misconfiguration can leave the model working while the
guard silently fails — or the reverse.

## Routes

| Path | Backend | Guardrail |
|---|---|---|
| `/bedrock/llama3-8b` | `bedrock-llama3-8b` | none — **control** |
| `/bedrock/guard/native` | `bedrock-llama3-8b-guarded` | attach point 1 |
| `/bedrock/guard/promptguard` | `bedrock-llama3-8b` (unguarded) | attach point 2, via policy |

All three use **Llama 3.1 8B** (`meta.llama3-1-8b-instruct-v1:0`) — cheapest of the models in
`10-`, and identical across the three routes so any behavior difference is attributable to the
guardrail rather than the model. The haiku/mistral backends and routes from `llmroute-bedrock`
are left in place unused; they cost nothing and keep this bundle a superset of its parent.

`/bedrock/guard/promptguard` points at the **unguarded** backend deliberately. If it used the
guarded one, both mechanisms would fire and a block could not be attributed to either.

## Prerequisites

1. Cluster with agentgateway installed + exposed (`solomog agentgateway expose CLUSTER=<name>`).
2. AWS SSO Bedrock access (`aws configure sso`, `AWS_PROFILE` in `.env` — see
   [`llmroute-bedrock/README.md`](../llmroute-bedrock/README.md)).
3. **New `.env` keys.** `BEDROCK_GUARDRAIL_ID` / `BEDROCK_GUARDRAIL_VERSION` feed the
   `%%BEDROCK_GUARDRAIL_ID%%` / `%%BEDROCK_GUARDRAIL_VERSION%%` bundle tokens:
   ```bash
   solomog env:sync                  # adds the new keys from .env.example, keeps your values
   # then set them — find an existing guardrail with:
   aws bedrock list-guardrails --region us-west-2
   ```
   The guardrail must be in the **same region** as the backends (this bundle pins `us-west-2`).
   `DRAFT` picks up guardrail edits immediately; a numbered version pins them.
4. **A DENY topic on the guardrail**, which the block tests assert on:
   ```bash
   bash helpers/add-denied-topic.sh              # preview: prints the exact payload, mutates nothing
   APPLY=true bash helpers/add-denied-topic.sh   # apply it
   ```
   ⚠️ `aws bedrock update-guardrail` is a **full PUT** — omitting a policy deletes it. The helper
   reads the live config and re-sends everything, and **refuses to run** if the guardrail contains
   a policy type it cannot faithfully round-trip, rather than silently dropping it. Preview first.

   Why a topic and not the stock content filters: content filters block on classifier confidence,
   so a test verdict can drift. A narrow topic DENY blocks identically every time, which means a
   failing test indicates broken wiring rather than a borderline score.

## Install

```bash
solomog aws:refresh apply BUNDLE=llmroute-bedrock-guardrails CLUSTER=<cluster>
solomog test BUNDLE=llmroute-bedrock-guardrails CLUSTER=<cluster>
```

Use the **chained** form. `aws:refresh` only rewrites `.env`; `01-api-keys.sh` (an apply hook) is
what pushes the credentials into `bedrock-secret`. Refreshing without re-applying leaves the old
token in the cluster, and the symptom is a Bedrock 403 "The security token included in the request
is expired" — with fresh credentials sitting in `.env` the whole time.

[`00-guardrail-preflight.sh`](00-guardrail-preflight.sh) runs first and fails fast on dead
credentials, missing `.env` keys, or a guardrail that is absent / not `READY` / missing the topic —
so those surface by name at apply time instead of as an opaque 403 in a test log later.

## Tests

| Test | Route | Asserts |
|---|---|---|
| `10-baseline-unguarded` | `/bedrock/llama3-8b` | 200 — **control**: same model, same prompt, no guardrail |
| `50-native-topic-blocked` | `/bedrock/guard/native` | Bedrock's intervention message is in the body |
| `60-promptguard-topic-blocked` | `/bedrock/guard/promptguard` | HTTP **403** from the policy |
| `61-promptguard-pii-anonymized` | `/bedrock/guard/promptguard` | 200 **and** the email does not come back verbatim (EMAIL → ANONYMIZE) |

`10-`, `50-`, and `60-` all send the **same prompt** — the only variable is the guardrail, so the
three together isolate each mechanism. `50-` deliberately does not assert on a status code: the
native path returns 200 and expresses the block in the body, so a status assertion there would
never fail.

## Not built yet

- **The customer repro needs a NON-Bedrock upstream.** With Bedrock upstream the guardrail rides
  the invocation (see Verified behavior), so the gateway never calls ApplyGuardrail and never
  rebuilds the request — which is precisely where the reported bugs live. Reproducing them takes
  an Anthropic (or other non-Bedrock) backend, where out-of-band ApplyGuardrail is the only
  option. Tracked separately.
- **The credential-asymmetry probe** — drop `policies.auth.aws` from the `bedrockGuardrails`
  filter in `42-` and see what happens when the guard has no credential but the model call does.
- Other `promptGuard` filter types (`regex`, `webhook`, `openAIModeration`, `googleModelArmor`,
  `purviewDlp`). The webhook path has a prebuilt server —
  `gcr.io/solo-public/docs/ai-guardrail-webhook:latest`, port 8000, gateway calls `POST /request`
  and `POST /response`.
- `promptGuard.streaming: Enabled` — response guarding on a streamed completion.
- Chaining several filters in one `promptGuard` list and pinning down evaluation order. Each list
  item holds exactly one filter type (CRD rule
  `ExactlyOneOf=regex;webhook;openAIModeration;bedrockGuardrails;googleModelArmor`), so a chain is
  several items; `response` is not part of that set and rides alongside the filter it belongs to.
- `entPromptGuard` — identical to `promptGuard` apart from adding `purviewDlp`, so there is nothing
  to prove until Purview is in scope.

## Verified behavior (live, 2026-08-13, cluster g1, agentgateway 2026.7.1-patch.0)

All four tests green. What the runs established beyond the assertions:

- **Native passthrough blocks pre-inference.** `50-` came back `finish_reason: "content_filter"`
  with `total_tokens: 0` — Bedrock rejected the prompt before the model ran, so a block costs no
  inference tokens. It also confirms the `guardrail` provider field works on Llama 3.1 8B.
- **The promptGuard deny is unambiguously the gateway's.** `60-` returned 403 with the exact
  `response.message` string from `42-`, as plain text (not JSON) — a body Bedrock could not produce.
- **Masking happens — but NOT via ApplyGuardrail, and NOT reconstructed by the gateway.**
  `61-`'s model reply was literally `{EMAIL}`, so the placeholder did reach the model. The
  original reading (that the gateway forwards ApplyGuardrail's masked content) is **wrong**.
  Three probes, 2026-08-13:
    * `aws bedrock-runtime apply-guardrail` on the identical text → `action: NONE`, `outputs: []`,
      `sensitiveInformationPolicyUnits: 0` with 60/60 chars covered. A literal MAC address is
      likewise undetected. The PII policy is simply not evaluated on that path.
    * `aws bedrock-runtime converse` with `guardrailConfig` on the identical text →
      `stopReason: guardrail_intervened` and output `{EMAIL}` — byte-identical to what the
      gateway returned.
    * The unguarded control route returns the real address, so the masking is real.
  The gateway's behavior on a **Bedrock** upstream is therefore fully explained by the guardrail
  riding the invocation, with no out-of-band call and nothing to reconstruct. Which means this
  bundle never exercises the ApplyGuardrail-and-rebuild path at all — see
  [Not built yet](#not-built-yet); that path needs a non-Bedrock provider.
- **Cost asymmetry between the attach points.** Both avoid inference cost on a block, but
  promptGuard spends an extra ApplyGuardrail round trip on *every* request including allowed
  ones, while native passthrough adds no extra call. Relevant for high-volume routes.
- **Caveat on the control.** In `10-` the model declined the investment question by itself. The
  test asserts on HTTP status only (and the token counts confirm real inference), so it still
  proves "not blocked" — but not "answers freely". Do not compare the three tests on prose.

## Notes

- Verified against enterprise agentgateway **2026.7.1-patch.0**; all four objects pass a
  server-side dry-run on that build.
- The guardrail this was built against (`agentgateway-guardrails-poc`) has `PROMPT_ATTACK` set to
  `NONE`, so prompt-injection blocking is off. Raise it in the AWS console to demo that.
- The `%%BEDROCK_GUARDRAIL_*%%` tokens are substituted only when the `.env` vars are non-empty; an
  unset one survives as a literal token and trips apply-bundle.sh's leftover-token error rather
  than rendering an empty `identifier:` the CRD rejects for a less obvious reason.
