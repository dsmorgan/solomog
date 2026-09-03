# Why the exchanged token is visible in a trace but not in an access log

Source-verified against `agentgateway-enterprise` at `v2026.7.1-patch.0`.

## The access-log surface

Backend policies — including backend auth, where the exchange runs — execute **before** the
proxy snapshots the request for logging. So access-log CEL describes the request *as it left the
gateway*: `request.headers.authorization` at log time is the exchanged token, and
`request.path` is the post-rewrite path.

Two consequences the bundle demonstrates:

- On an HTTP or AI backend, access-log attributes can decode the exchanged token's claims.
- On an **MCP** backend the request is handed to the relay before backend auth runs. The relay
  exchanges on its own upstream call to each MCP target, and that call is issued internally with
  no request log attached — so no access-log record of it exists.

The `jwt.*` variables are populated only where a `jwtAuthentication` policy validated a token on
that route; a route carrying only an exchange has no inbound claims to log.

## The trace surface

Every backend call's response body is wrapped for tracing at the end of the backend-call path,
and emitted on completion as a `bodySnapshot` event with `stage: "response"`. The wrap happens
only while a debug tracer is active — that is, while `agctl proxy trace` is capturing.

The exchange reaches the authorization server through that same backend-call path, so the token
endpoint's reply is captured like any other response. Per RFC 6749 that body is a JSON object
containing `access_token` — which is why the exchanged token is readable from a trace even
though the header carrying it is redacted.

Credit: this route to the token was found by Solo engineering on an RBC ticket and noted on
[#7844](https://github.com/solo-io/agentgateway-enterprise/issues/7844).

## The redaction asymmetry

| Surface | Credential headers | Bodies |
|---|---|---|
| Access log (direct lookup) | not redacted | n/a |
| Debug trace / CEL variable dump | **redacted** (`<redacted>`) | **not redacted** |
| `jwt.rawToken` | redacted by default, `.unredacted()` opts in | n/a |

Headers are redacted in trace snapshots by name — `authorization`, `proxy-authorization`,
`cookie`, `set-cookie`. Bodies carry no such treatment, so a capture that includes a token
endpoint response holds a usable credential in clear text.

## What a trace cannot tell you

The body snapshot is the authorization server's *response*, not the header the gateway
subsequently sends upstream. It confirms what was issued — audience, scopes, client, lifetime —
but not what arrived at the MCP server. For that, the upstream side has to be instrumented, or
#7844 delivered.

It is also a live, interactive capture, and request tracing is experimental and unsupported for
production use. It is a troubleshooting tool, not a logging substitute.
