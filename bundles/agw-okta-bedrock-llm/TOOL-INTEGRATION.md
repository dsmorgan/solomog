# Lab 5 — Connect your AI tools

Point Claude Code / Cursor / Copilot at the tiered Bedrock routes, authenticating with the
Okta device-flow token (Lab 3) instead of AWS creds. The token carries the user's `groups`
claim, so the gateway's CEL policy (Lab 2) admits them to the tier they belong to.

**Solomog routing note:** the source workshop uses two *ports* (3000 standard / 3001 premium).
Solomog uses one gateway with two *paths*, so the per-tier base URL is:

- standard → `https://agw.<cluster>.test/bedrock/standard`
- premium  → `https://agw.<cluster>.test/bedrock/premium`

| Tool | API dialect | Token refresh | Gateway reachability |
|------|-------------|---------------|----------------------|
| Claude Code | Anthropic (`/v1/messages`) | **automatic** via `apiKeyHelper` | corp network / VPN ok (runs on your machine) |
| Cursor | OpenAI (`/v1/chat/completions`) | manual re-paste on expiry | must be **internet-reachable, public TLS** (Cursor's servers call it) |
| GitHub Copilot (VS Code) | OpenAI-compatible | manual re-paste on expiry | corp network / VPN ok (runs in VS Code) |

> The local mkcert host (`agw.<cluster>.test`) is only reachable from this machine, so on a
> local vind cluster **Claude Code and Copilot work; Cursor does not** (its servers can't reach
> your laptop). Cursor needs a publicly-exposed gateway with real TLS.

---

## Claude Code (recommended — automatic refresh)

Claude Code speaks the Anthropic dialect and supports an `apiKeyHelper` that it re-runs on TTL
expiry or a 401 — so [`helpers/ag-token.sh`](helpers/ag-token.sh) keeps you logged in silently.

```bash
# ~/.claude/settings.json
{ "apiKeyHelper": "/ABS/PATH/solomog/bundles/agw-okta-bedrock-llm/helpers/ag-token.sh" }
```

```bash
export ANTHROPIC_BASE_URL=https://agw.<cluster>.test/bedrock/premium   # or /bedrock/standard
export CLAUDE_CODE_API_KEY_HELPER_TTL_MS=3600000                        # re-run the helper hourly
claude
```

- The helper prints the Okta access token; Claude Code sends it as `Authorization: Bearer`
  (and `x-api-key`). On expiry it re-runs the helper, which refreshes silently (step 2 of
  `ag-token.sh`) — no browser prompt until the refresh token itself expires.
- **Do NOT** run `claude setup-token` or hand-edit `~/.claude/.credentials.json` when fronting
  Bedrock through the gateway — that's for direct Anthropic subscription auth and will conflict.
- If you previously used Vertex: `unset CLAUDE_CODE_USE_VERTEX`.

⚠️ **Needs a live confirm:** Claude Code posts Anthropic-Messages format to `…/v1/messages`.
The Bedrock backends (10/11) currently have no `policies.ai.routes` map. If Claude Code gets a
routing/format error, add the Messages mapping to the tier backend (mirrors the
`agent-harnesses/claude-code.md` passthrough lab):

```yaml
  policies:
    ai:
      promptCaching: {}
      routes:
        "/v1/messages": "Messages"
        "*": "Passthrough"
```

## Cursor

1. Settings (⌘⇧J) → **Models** → **API Keys**.
2. Get a token: `bundles/agw-okta-bedrock-llm/helpers/ag-token.sh` → paste as the **OpenAI API Key**.
3. Enable **Override OpenAI Base URL** → `https://<public-gateway>/bedrock/premium/v1`.
4. Add a custom model name matching the tier, then **Verify**.

Token expiry → re-paste (Cursor has no helper hook). Requests transit Cursor's servers, so the
gateway must be publicly reachable with valid TLS (not a local `.test` host).

## GitHub Copilot (VS Code)

1. Command Palette → **Chat: Manage Language Models** → add an **OpenAI-compatible / Custom
   Endpoint** provider.
2. Base URL: `https://agw.<cluster>.test/bedrock/premium/v1`.
3. API key: output of `helpers/ag-token.sh`. Register the model name(s) from your routes.

Limits: BYOK covers chat/agent mode only (inline completions stay on Copilot's models); on
Business/Enterprise an org admin must enable the BYOK policy first. Runs in VS Code, so an
internal-only gateway is fine.
