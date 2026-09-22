# Findings — rate limiting an MCP relay path

Verified on cluster-created-for-purpose, agentgateway enterprise **2026.7.1-patch.2** (LTS),
`@modelcontextprotocol/server-everything@2026.8.31`. Suite: 6/6 green in 65s.

## 1. The backend kind is irrelevant, and that is not obvious

Rate limiting is applied by `apply_request_policies` on the **route**, after the backend is
selected but before it is dispatched (`crates/agentgateway/src/proxy/httpproxy.rs`, the
`apply_request_policies` / `maybe_convert_mcp_error` pair). It does not run inside the MCP relay.

This is the opposite of MCP tool RBAC, which *is* enforced in the relay and therefore has no
effect on an `aws.agentCore` backend, because that backend is an opaque passthrough that never
enters the relay. The natural generalisation — "MCP policy does not reach AgentCore" — does not
hold for rate limiting.

**Consequence:** an AgentCore-backed route can be limited exactly like this bundle's in-cluster
relay, and an AgentCore account is not needed to reproduce, demo, or debug a rate limit question.

The only AgentCore-specific difference is cosmetic. `classify_request_protocol` returns `Mcp` only
for `Backend::MCP`; `Backend::Aws` falls to `RequestProtocol::Http`. On releases that reshape the
denial (see §3) an AgentCore route keeps the plain HTTP shape while a relay route does not.

## 2. Token exchange is not linked

Token exchange is backend auth, a separate policy stage and a separate `oneOf`. Nothing about
limiting depends on it. Limiting *per user* would need `jwtAuthentication` to produce a claim to
key on — and note this LTS has no `key` field on `rateLimit.local`, so a per-caller local bucket
is not available here at all; that requires the global arm.

## 3. The denial shape changed AFTER the LTS was cut

Upstream `agentgateway#3146` (2026-08-27) made a rate-limited MCP `tools/call` return **HTTP 200**
with a JSON-RPC `isError` result; non-tool methods get a top-level JSON-RPC error with code
`RESOURCE_EXHAUSTED`. `proxy/mod.rs` maps `MCP(RateLimited)` to `StatusCode::OK`, and a comment in
`proxy_error_to_grpc_status` states it plainly: *"HTTP 200 with JSON-RPC error"*.

That commit is **not** an ancestor of the LTS base (OSS `83c952731`, 2026-07-28), and the observed
behaviour on 2026.7.1-patch.2 confirms it: a denial is a plain **HTTP 429 with an empty body**.

**Why it matters more than it looks:** a test asserting `429` passes today and silently starts
failing on upgrade; a test asserting `200` reports success today while measuring nothing. The
tests here accept either and print which shape was seen.

## 4. The global arm emits no rate-limit headers on this LTS

Observed: `x-ratelimit-limit/remaining/reset` appear on the **local** arm, and only on a 429. On
the **global** arm they appear on neither 200 nor 429.

This contradicts the internal use-case note ("Global: headers appear on every response"), which
describes post-LTS behaviour. Upstream `agentgateway#3386`, *"Fix rate-limit denial headers and add
Retry-After"* (2026-09-08), is the fix — also after the LTS cut. Do not build a client backoff on
those headers if you are on 2026.7.x.

## 5. Why arm B cannot use the rate limiter the product already ships

`entRateLimit` reaches the installed rate limiter through `RateLimitConfig`, and the enterprise
translator **prepends** `generic_key = "<namespace>.<name>"` to every descriptor it builds —
`ratelimitutils.GetGenericKeyDescriptorValue`, called from `agentgatewayenterprisepolicy.go` under
the comment *"Add the Solo.io-specific descriptors FIRST - generic keys before policy keys"*.

So a hand-written MCP descriptor tree pointed at that service matches nothing unless it is nested
under that synthetic prefix. Combined with §6 this is the most likely reason a per-tool MCP rate
limit "looks configured but does nothing".

Arm B therefore runs its own `envoyproxy/ratelimit` with a ConfigMap this bundle owns, so the
descriptors are exactly as written.

## 6. `entRateLimit` cannot express a per-tool limit at all

A `RateLimitConfig` matches with Envoy-style **actions** — `genericKey`, `requestHeaders`,
`remoteAddress`, `metadata`. None of them read a JSON-RPC body, so no action yields "the tool this
call names". Arm C demonstrates the consequence directly: after `echo` exhausts the budget,
`get-sum` is refused on the same budget.

Per-tool limiting requires the CEL descriptors of arm B. This is a **capability boundary, not a
misconfiguration** — worth saying early to anyone who is trying to get there via RateLimitConfig.

## 7. An unmatched descriptor is silence, not an error

The `other` / `none` branches in arm B's CEL are what make `initialize` and `tools/list` free:
they produce a descriptor with no rule in the tree, and an unmatched descriptor is not counted.

The same mechanism is the failure mode. A tool name that does not match — a typo, or a server
whose tool set moved — leaves the route **unlimited**, while the policy still reports
`Accepted=True` and `Attached=True`. Nothing anywhere reports a miss. Only traffic reveals it.

This bit during the build: `server-everything` renamed its arithmetic tool `add` to `get-sum`, and
the npm package is CalVer, so `latest` moves. The bundle pins the version for that reason.

## 8. Sizing: the handshake spends budget on arms A and C

An MCP session is 3-5 HTTP requests before any useful work. Arms A and C count all of them, so the
5/min limit in this bundle admits **four** tool calls after `initialize` — which test 30 asserts,
rather than the more obvious and wrong "five". Size these arms per session, not per tool call.

## 9. `entRateLimit` is fail-closed and you cannot change that

`entRateLimit.global` exposes only `backendRef`, `domain` and `rateLimitConfigRefs`. There is
**no `failureMode` field** on this line, so an unavailable rate limiter takes the route down:
requests return **HTTP 500 `rate limit failed`**. Arm B's `rateLimit.global` does have
`failureMode`, and this bundle sets it to `FailOpen`.

Caught by building the cluster from scratch and testing immediately: `solomog apply` returns as
soon as objects are accepted, and for roughly the first minute the shipped rate limiter is not yet
serving, so every request to `/mcp-ent` 500s while `/mcp-local` and `/mcp-pertool` are already
fine. Preflight now waits on the rate limiter deployment and retries the handshake for that
reason.

**Operationally this is the sharpest edge in the bundle.** On arm C, a rate limiter that is
restarting, being upgraded, or briefly unscheduled is a full outage of every route that uses it,
with no configuration available to soften it. Choose arm C for a distributed ceiling knowing that;
where availability matters more than the ceiling, arm B with `FailOpen` is the safer shape.

## 10. Which CRD? There is no generic Gateway API rate limit kind

Upstream Gateway API ships **no rate limit CRD at any maturity level** — the only policy kind is
`BackendTLSPolicy`. So a "generic" rate limit CR does not exist upstream.

An enterprise install does, however, also ship the community CRD
`agentgatewaypolicies.agentgateway.dev`, and its `traffic.rateLimit` schema is **identical** to the
enterprise one: same `local` / `global` / `conditional`, same `{name, expression}` descriptor
entries. A community `AgentgatewayPolicy` carrying a local limit was applied to an
enterprise-class gateway and **enforced exactly like the enterprise policy** (5/min: handshake plus
four calls, then 429), reconciled by `controllerName: solo.io/enterprise-agentgateway`.

**So arms A and B do not require `EnterpriseAgentgatewayPolicy`.** Either kind works.

The one hard boundary is `entRateLimit` (arm C), which exists only on the enterprise CRD. Using it
on the community kind is rejected by the apiserver, loudly:

    strict decoding error: unknown field "spec.traffic.entRateLimit"

Because that failure is loud, the community CRD is not a candidate explanation for a rate limit
that silently does nothing.

**A better candidate for a silent no-op: an orphan `RateLimitConfig`.** It looks like the generic,
product-neutral rate limiting object, and alone it does nothing — but it reports
`{"observedGeneration":1,"state":"ACCEPTED"}`, with no indication it is attached to zero routes. It
takes effect only when a policy names it under `entRateLimit.global.rateLimitConfigRefs`.

## 11. The catch-all rule is per-tool, not a shared pool

Counters are keyed on the descriptor **values**, not on which config rule matched. A
`key: tool_name` entry with no `value` therefore does not create one shared bucket for "everything
else" — each distinct tool name gets its own counter at that limit. The rate limiter's own log
shows the key, one per tool and per minute window:

    cache key: mcp-tools_mcp_method_tools/call_tool_name_get-env_1790114280  current: 3  limit: 10

Verified: `echo` was driven to exactly 10 and then 429, while `get-env` — matching the *same*
catch-all rule — answered 200 on a fresh counter.

To get a genuinely shared pool for unnamed tools, the CEL must collapse them to a constant
(emit a fixed string instead of `string(body.params.name)`).

## Operational notes

- The rate limit service reads its ConfigMap at **start**. After editing the descriptor tree,
  `kubectl rollout restart deploy/mcp-ratelimit -n agentgateway-system`.
- Arm A's bucket is per gateway **process**: N replicas give N x the limit. Arms B and C count in
  Redis and hold across replicas.
- `failureMode: FailOpen` on arm B means traffic survives an unreachable limiter. Use
  `FailClosed` where the limit is a control rather than a courtesy.
