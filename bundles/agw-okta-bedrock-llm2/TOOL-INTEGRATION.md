# Lab 5 — Connect your AI tools (single-endpoint variant)

Same as [`agw-okta-bedrock-llm`](../agw-okta-bedrock-llm/TOOL-INTEGRATION.md), with one big
simplification: **every user points at the same base URL, `…/bedrock`** — there's no tier in the
path. The gateway reads the Okta `groups` claim and routes to the entitled tier automatically
(see [`README.md`](README.md)). A user in neither tier gets a 404.

- standard **and** premium users → `https://agw.<cluster>.test/bedrock`

| Tool | API dialect | Token refresh | Gateway reachability |
|------|-------------|---------------|----------------------|
| Claude Code | Anthropic (`/v1/messages`) | **automatic** via `apiKeyHelper` | corp network / VPN ok (runs on your machine) |
| Cursor | OpenAI (`/v1/chat/completions`) | manual re-paste on expiry | must be **internet-reachable, public TLS** |
| GitHub Copilot (VS Code) | OpenAI-compatible | manual re-paste on expiry | corp network / VPN ok |

> On a local vind cluster the mkcert host is laptop-only, so **Claude Code and Copilot work;
> Cursor does not** (its servers can't reach your machine). Cursor needs a public gateway + TLS.

## Claude Code (recommended — automatic refresh)

```bash
# ~/.claude/settings.json
{ "apiKeyHelper": "/ABS/PATH/solomog/bundles/agw-okta-bedrock-llm2/helpers/ag-token.sh" }
```
```bash
export ANTHROPIC_BASE_URL=https://agw.<cluster>.test/bedrock      # same URL for everyone
export CLAUDE_CODE_API_KEY_HELPER_TTL_MS=3600000
claude
```
`ag-token.sh` prints the Okta token; Claude Code re-runs it on TTL/401, refreshing silently. Do
**not** run `claude setup-token` when fronting Bedrock via the gateway. If you'd used Vertex:
`unset CLAUDE_CODE_USE_VERTEX`.

⚠️ Same live-confirm caveat as bundle 1: Claude Code posts Anthropic-Messages to `…/bedrock/v1/messages`.
If it errors on format/routing, add `policies.ai.routes: {"/v1/messages": "Messages", "*": "Passthrough"}`
to the tier backends (10/11).

## Cursor

Settings (⌘⇧J) → Models → API Keys → paste `helpers/ag-token.sh` output as the OpenAI key →
Override OpenAI Base URL → `https://<public-gateway>/bedrock/v1` → add a model name → Verify.
Re-paste on expiry (no helper hook); needs a public gateway with valid TLS.

## GitHub Copilot (VS Code)

Command Palette → **Chat: Manage Language Models** → OpenAI-compatible / Custom Endpoint → base URL
`https://agw.<cluster>.test/bedrock/v1` → API key = `helpers/ag-token.sh` output → register model
name(s). BYOK = chat/agent only; Business/Enterprise needs an admin to enable BYOK first.
