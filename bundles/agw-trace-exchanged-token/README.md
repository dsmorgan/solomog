# agw-trace-exchanged-token — can you observe the token an OAuth exchange produced?

A customer asked how to log the token produced by a backend OAuth token exchange, seeing only
the inbound JWT. The answer turns out to depend on the backend type, so this bundle holds
everything constant except that: the same Keycloak realm, the same user, the same exchange
policy, applied to one HTTP-backend route and one MCP-relay route.

| Route | Backend | Exchange |
|-------|---------|----------|
| `/exchange-http` | `go-httpbin` (echoes the headers it received) | `backend.auth.oauthTokenExchange` |
| `/exchange-mcp`  | `mcp-relay` → in-cluster MCP server, no backend auth | same policy |

Two observation surfaces are compared: **access logs** (continuous, but blind on MCP relays —
see [#7844](https://github.com/solo-io/agentgateway-enterprise/issues/7844)) and **`agctl proxy
trace` body snapshots** (interactive; the authorization server's RFC 6749 response body carries
`access_token`, and trace bodies are not redacted).

## Deploy and test

```bash
solomog agentgateway expose CLUSTER=<c> AGENTGATEWAY_VERSION=v2026.7.1-patch.0
solomog apply BUNDLE=agw-trace-exchanged-token CLUSTER=<c>
solomog test  BUNDLE=agw-trace-exchanged-token CLUSTER=<c>
```

Re-run on a newer line by changing only the version pin (`v2026.8.1`, the current default).
Iterate on one test with `TESTS=50`.

| | |
|---|---|
| **Covers** | exchanged-token visibility in access logs vs debug traces, HTTP vs MCP backend |
| **Needs** | nothing in `.env` — Keycloak is in-cluster and the client secret is minted at apply time |
| **Needs** | `agctl` for tests 40/50; they self-skip without it |
| **Versions** | `backend.auth.oauthTokenExchange` requires 2026.7.x+; body snapshots exist there too |
| **Clash-safe** | yes — its own realm, routes and namespaces; reuses the `keycloak` namespace with identical manifests |

## Reading the results

- **20** is the control: Keycloak performs the RFC 8693 exchange with the gateway out of the
  picture. If it fails, nothing below is a gateway finding.
- **30** proves the exchanged token reaches the HTTP upstream, from what `go-httpbin` echoed.
- **40/50** are the experiment: can a trace show the exchanged token, on each backend type.
- **60** reproduces #7844 — the access log carries it on HTTP and nothing on the MCP relay.

**Result on 2026.7.1-patch.0: 6/6, and a trace DOES show the exchanged token on the MCP relay
route** — the surface the access log cannot see. Details in [docs/FINDINGS.md](docs/FINDINGS.md).

**Mind the exchange cache.** The proxy caches an exchange result (~300s), and a cache hit makes
no call to the authorization server, so there is no token response to capture and the technique
looks broken when it is merely warm. Always trace with a *fresh* subject token;
`helpers/capture-trace.sh` forces one.

## Handling the capture

A trace that includes a token-endpoint response contains a **live bearer token in clear text** —
trace bodies are not redacted, unlike headers. `helpers/capture-trace.sh` discards the raw
capture by default; `KEEP=true` retains it. Do not attach one to a ticket.

More detail: [docs/MECHANISM.md](docs/MECHANISM.md).
