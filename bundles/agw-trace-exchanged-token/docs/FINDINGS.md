# Findings

## v2026.7.1-patch.0 (the customer's version) — 6/6, 2026-09-02, cluster `xtok`

| Question | Result |
|---|---|
| Keycloak performs RFC 8693 exchange (20) | ✅ `azp=exchange-client` |
| HTTP route forwards the exchanged token upstream (30) | ✅ echoed by go-httpbin |
| Trace shows the token on an HTTP route (40) | ✅ `stage=response`, decoded claims |
| **Trace shows the token on an MCP relay route (50)** | **✅ yes — same as HTTP** |
| Access log: HTTP populated, MCP empty (60) | ✅ #7844 reproduced |

### The headline

**A debug trace exposes the exchanged token on an MCP relay route, where the access log cannot.**
Sadie's technique covers the customer's shape. Citizens and RBC have a usable troubleshooting
path today on the version they already run.

The two surfaces disagree because they hook different things. The relay performs the exchange on
its own upstream call; that call is issued with no request log attached, so **nothing about it
reaches an access log** — but the debug tracer is inherited by it, so the same call's
authorization-server response **is** captured. Logging and tracing are not two views of one
mechanism here; the relay's upstream leg is invisible to one and visible to the other.

Access-log evidence on the MCP route is unchanged: `exchanged_fingerprint` is
`e3b0c44298…7852b855`, the SHA-256 of the empty string, so no `Authorization` header was on the
logged request at all.

### The cache is a trap

The first run of test 40 **failed**, and the technique looked broken. It was not: test 30 had
just performed an exchange, and the proxy caches the result (in-memory, ~300s by default). A
cache hit makes **no call to the authorization server**, so there is no token response to
snapshot.

Anyone reproducing this must force a cache miss — a fresh subject token is a new cache key.
`helpers/capture-trace.sh` now always fetches a new one. Told to a customer as "run a trace and
look for the token response", this will fail roughly as often as it succeeds, and the failure
looks like the feature is missing rather than warm.

### Trace stages seen, in order

```
stage=final request  1678 bytes   POST to the token endpoint — contains the SUBJECT token
stage=response       ~1 KB        RFC 6749 reply — contains the EXCHANGED token   ← the one
stage=final request  0 bytes      the upstream call to the backend
stage=response       1541 bytes   the backend's reply            (HTTP route only)
```

Both credentials are therefore exposed in a capture: the inbound token in the request body and
the exchanged token in the response body. Neither is redacted.

## v2026.8.1 (current default)

_not yet run — same bundle, change only the version pin_

## What this changes

- **#7844 narrows.** It is no longer "the exchanged token cannot be observed on MCP routes" but
  "it cannot be observed *continuously*, only in an interactive trace". Still worth building —
  a live trace is not an audit trail, and it cannot show the upstream header — but the urgency
  drops and the framing in the issue needs correcting.
- **The customer answer changes** from "not on your shape" to "yes, with `agctl proxy trace`,
  and mind the cache".
