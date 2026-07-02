# Agentgateway MCP and LLM OBO demo

Mirrors the `obo-crewai-agent-with-mcp` workshop lab: one delegated (OBO) token,
issued by the agentgateway STS, unlocks **both** an LLM route and an MCP tool
route. A raw Keycloak user JWT is rejected 401 on either — only an STS-issued
token whose `sub` is the user and `act` is the agent service account is accepted.

| Route | Backend | JWT policy |
|-------|---------|------------|
| `/obo/openai` | mock-openai (`mock-gpt-4o`) | `obo-openai` → `obo-jwt-policy` (70) |
| `/obo/mcp` | in-cluster `mcpx-website-fetcher` (MCP) | `mcpx` → `obo-mcp-jwt-policy` (72) |
| `/obo/anthropic` | **real** Anthropic API (`obo-anthropic`) | `obo-anthropic` → `obo-anthropic-jwt-policy` (74) |

The gateway strips the client's OBO token and injects the real upstream credential (from a
backend `secretRef`), so the LLM/MCP backend never sees the OBO token. The `/obo/anthropic`
route makes this verifiable: Anthropic validates the key, so a successful call proves the OBO
token was swapped out — it would 401 if the token had been forwarded (see `99-test-anthropic-obo`).

The install for this requires Keycloak to be operational before enabling the
agentgateway STS (token exchange) — the STS validates JWKS against Keycloak
*at controller startup*, so Keycloak must already exist.

`TOKEN_EXCHANGE` is CLI-only (never persisted in `.env`) — see `.env.example`
for why. Pass it explicitly on the command that should enable it.

The `/obo/anthropic` route calls the real Anthropic API, so `CLAUDE_API_KEY` must be set in
`.env` — the `06-anthropic-secret.sh` hook fails fast on apply if it's missing.

## Fresh cluster

1. Bring up the cluster, gateway, UI, mock backend, and this bundle's resources
   (Keycloak, MCP fetcher, routes) — token exchange is still off at this point:
   ```
   solomog agentgateway:ui expose apps:mock-openai apply BUNDLE=agw-obo-token-exchange CLUSTER=<cluster>
   ```
2. Route the Solo UI *and* enable the STS in one call. `agentgateway:ui` runs
   the same agentgateway install as the standalone `agentgateway` task, so
   `TOKEN_EXCHANGE=true` enables the STS and restarts the agw proxy (which
   doesn't pick up the new STS/JWKS config dynamically), while `ROUTE=true`
   routes the UI at `ui.agw.<cluster>.test`:
   ```
   solomog agentgateway:ui ROUTE=true TOKEN_EXCHANGE=true CLUSTER=<cluster>
   ```

Two commands, not because of a bundle limitation, but because of ordering
constraints that both point back to step 1: the UI can only be routed after
`expose` creates the Gateway, and the STS can only start after Keycloak exists.
Since step 2 runs entirely after step 1, both preconditions are met. `ROUTE` is
scoped to this `agentgateway:ui` call, so the mock backend does *not* also get
an unprotected `/openai` route (which would bypass the OBO policy this demo is
about). Everything else — restarting the proxy, wiring the flags — is automatic.

## Existing cluster (agentgateway/UI/bundle already applied)

Enable the STS (and route the UI if it isn't already):
```
solomog agentgateway:ui ROUTE=true TOKEN_EXCHANGE=true CLUSTER=<cluster>
```

If you only need the STS and the UI is already routed, the lighter standalone
task works too:
```
solomog agentgateway TOKEN_EXCHANGE=true CLUSTER=<cluster>
```

## Verify

```
solomog test BUNDLE=agw-obo-token-exchange CLUSTER=<cluster>
```

Key tests:
- `10-obo-openai-401` / `12-obo-mcp-401` — both routes reject unauthenticated requests.
- `50-test-impersonation` — LLM route accepts an OBO token, rejects the raw user JWT.
- `99-test-anthropic-obo` — OBO against the **real** Anthropic API; a 200 proves the OBO token was swapped for the real key (not forwarded to Anthropic).
- `52-test-mcp-obo` — lighter standalone MCP check: impersonation token, MCP handshake through `/obo/mcp` (lists tools).
- `85-del-delegation-flow` — the workshop's core flow: one pod-based delegated token (`sub`=user, `act`=agent) used against **both** `/obo/openai` and `/obo/mcp`.
