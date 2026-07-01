# Agentgateway MCP and LLM OBO demo

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
