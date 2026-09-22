# mcp-ratelimit — rate limiting an MCP relay path on agentgateway

Three ways to limit MCP traffic, side by side on one gateway, each on its own route so they can
be compared without interfering. Written against the **2026.7.x LTS** line.

| | route | mechanism | limits by | needs |
|---|---|---|---|---|
| **A** | `/mcp-local` | `traffic.rateLimit.local` | whole route | nothing |
| **B** | `/mcp-pertool` | `traffic.rateLimit.global` + CEL | **each tool** | Redis + a rate limit service |
| **C** | `/mcp-ent` | `traffic.entRateLimit` + `RateLimitConfig` | whole route | nothing (uses the shipped rate limiter) |

**Pick B only if limits must differ per tool.** It is the only arm that reads the JSON-RPC body,
and the only one where `initialize` and `tools/list` go uncounted. A and C count every request on
the route, so an MCP handshake spends budget before a single tool is called.

## Run it

```bash
solomog agentgateway expose apply BUNDLE=mcp-ratelimit CLUSTER=<c>
solomog test BUNDLE=mcp-ratelimit CLUSTER=<c>
```

Takes about 65s: the limits are per-minute, so a test that finds a spent window waits one out.
`TESTS=40` re-runs just the per-tool arm.

## Facts worth knowing before you copy this

- **Rate limiting does not care what the MCP backend is.** It is applied on the route before the
  backend is dispatched, so an `aws.agentCore` backend behaves the same as the in-cluster relay
  here. This is unlike MCP tool RBAC, which runs inside the relay and never sees an AgentCore
  backend at all. No AgentCore account is needed to reproduce or debug this.
- **Token exchange is unrelated.** It is backend auth, a different policy stage. Limiting per user
  needs `jwtAuthentication`, not exchange.
- **A policy may set `rateLimit` or `entRateLimit`, never both** — hence three routes, not one.
- **Arms A and B do not require `EnterpriseAgentgatewayPolicy`.** The community
  `AgentgatewayPolicy` (`agentgateway.dev/v1alpha1`) has an identical `traffic.rateLimit` schema
  and enforces the same on an enterprise gateway. Only `entRateLimit` is enterprise-only. Upstream
  Gateway API has no rate limit CRD at all.
- **Arm B's catch-all is per tool, not a shared pool** — counters key on the descriptor values, so
  each unnamed tool gets its own bucket at that limit.
- **On this LTS a denial is a plain HTTP 429 with an empty body.** Newer builds return HTTP 200
  with the denial inside the JSON-RPC body instead. The tests accept either.
- **Arm A's bucket is per gateway process**, so N replicas give N x the limit. Arm B and C count
  in Redis and hold across replicas.
- **`requests` and `tokens` are mutually exclusive**; `tokens` is for LLM routes.

Version pins matter twice here: the gateway line (denial shape) and the pinned
`server-everything` npm version (the per-tool descriptor matches the literal tool name
`get-sum`, which older releases called `add`).

## Gotchas that cost time

- **Arm C is fail-closed and offers no switch.** `entRateLimit` has no `failureMode` field, so
  while the shipped rate limiter is starting (or restarting) every request to `/mcp-ent` returns
  HTTP 500 `rate limit failed`. Arm B sets `failureMode: FailOpen` instead. Straight after an
  apply, give the rate limiter a minute — preflight waits for it.

- **An unmatched CEL descriptor is not counted, it is not an error.** A typo in a tool name leaves
  the route unlimited while the policy still reports `Accepted=True`. Assert with traffic.
- **The rate limit service reads its ConfigMap at start.** After editing the descriptor tree:
  `kubectl rollout restart deploy/mcp-ratelimit -n agentgateway-system`.
- **`Accepted=True` validates nothing** about enforcement.

Full reasoning, source citations and two doc/behaviour mismatches: [docs/findings.md](docs/findings.md).
