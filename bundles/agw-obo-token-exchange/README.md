# Agentgateway MCP and LLM OBO demo

Mirrors the `obo-crewai-agent-with-mcp` workshop lab: one delegated (OBO) token,
issued by the agentgateway STS, unlocks **both** an LLM route and an MCP tool
route. A raw Keycloak user JWT is rejected 401 on either — only an STS-issued
token whose `sub` is the user and `act` is the agent service account is accepted.

| Route | Backend | JWT policy |
|-------|---------|------------|
| `/obo/openai` | mock-openai (`mock-gpt-4o`) | `obo-openai` → `obo-jwt-policy` (70) |
| `/obo/mcp` | in-cluster `mcpx-website-fetcher` (MCP) | `mcpx` → `obo-mcp-jwt-policy` (72) |

The install for this requires Keycloak to be operational before enabling the
agentgateway STS (token exchange) — the STS validates JWKS against Keycloak
*at controller startup*, so Keycloak must already exist.

`TOKEN_EXCHANGE` is CLI-only (never persisted in `.env`) — see `.env.example`
for why. Pass it explicitly on the command that should enable it.

## Fresh cluster

1. Bring up the cluster, gateway, mock backend, and this bundle's resources
   (Keycloak, MCP fetcher, routes) — token exchange is still off at this point:
   ```
   solomog agentgateway:ui expose apps:mock-openai apply BUNDLE=agw-obo-token-exchange CLUSTER=<cluster>
   ```
2. Enable the STS now that Keycloak exists. This also restarts the agw
   data-plane proxy automatically (it doesn't pick up the new STS/JWKS config
   dynamically):
   ```
   solomog agentgateway TOKEN_EXCHANGE=true CLUSTER=<cluster> 
   ```

Two commands, not because of a bundle limitation, but because of that
inherent ordering constraint (Keycloak before STS). Everything else —
restarting the proxy, wiring the flag — is automatic within those two calls.

## Existing cluster (agentgateway/UI/bundle already applied)

Just enable the STS:
```
solomog agentgateway TOKEN_EXCHANGE=true  CLUSTER=<cluster> 
```

## Verify

```
solomog test BUNDLE=agw-obo-token-exchange CLUSTER=<cluster>
```

Key tests:
- `10-obo-openai-401` / `12-obo-mcp-401` — both routes reject unauthenticated requests.
- `50-test-impersonation` — LLM route accepts an OBO token, rejects the raw user JWT.
- `52-test-mcp-obo` — lighter standalone MCP check: impersonation token, MCP handshake through `/obo/mcp` (lists tools).
- `85-del-delegation-flow` — the workshop's core flow: one pod-based delegated token (`sub`=user, `act`=agent) used against **both** `/obo/openai` and `/obo/mcp`.
