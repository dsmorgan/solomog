# The evidence record

One access-log line per MCP tool call, emitted by the gateway that made the decision, at the moment
it made it. `60-evidence-telemetry.yaml.tmpl` adds the `audit.*` attributes. Everything else is built
in. The same record goes to stdout (JSON), over OTLP to the collector and Loki, and, for the fields
`62-tracing.sh` adds, onto the trace span.

## A real record

intake-agent forcing `approve_prior_auth`, from run `20260925-160400` on 2026.7.1-patch.2. The
reviewer's email and Okta ids are redacted; everything else is verbatim. Transport fields are trimmed.

```json
{
  "audit.agent.id": "xaa-agent-b-at-treasury",
  "audit.agent.okta_id": "wlp<redacted>",
  "audit.agent.via_app": "0oa<redacted>",
  "audit.declared.agent_name": "intake-agent",
  "audit.declared.agent_version": "1.4.2",
  "audit.declared.user_agent": "intake-agent/1.4.2",
  "jwt.sub": "00u<redacted>",
  "audit.user.email": "reviewer@example.com",
  "audit.user.groups": ["priorauth-reviewer"],
  "audit.token.scopes": ["claims.read"],
  "audit.token.issuer": "https://<resource-as-issuer>",
  "audit.token.audience": "https://claims.evidence.test/mcp",
  "audit.token.idjag_id": "IDAAG.<redacted>",
  "audit.token.expiry": 1790367552,
  "audit.caller.unverified_pod": "intake-agent-79b9c6cf67-vftf4",
  "audit.caller.unverified_namespace": "agent-evidence",
  "mcp.method.name": "tools/call",
  "gen_ai.tool.name": "approve_prior_auth",
  "mcp.target": "claims",
  "route": "agentgateway-system/claims-tools",
  "http.status": 400,
  "reason": "MCP",
  "error": "mcp: Unknown tool: approve_prior_auth",
  "trace.id": "c6065302c5bf5160eb04f30b4bcf40c9",
  "span.id": "b08f0950a9efb4fc"
}
```

`audit.agent.id` is the alias typed on that tenant's Okta connection when it was created. Okta makes
the field read-only afterwards, which is why it isn't `intake-agent` here. A fresh setup following
[OKTA-SETUP.md](OKTA-SETUP.md) gets `intake-agent`. Set `EVIDENCE_*_ACTOR` to match whatever your
connections carry.

## Field by question

| Question | Field | Source | Assurance |
|---|---|---|---|
| Q1 which agent | `audit.agent.id` | `jwt.act.sub`: the alias on the agent's Okta connection | IdP-signed, via the ID-JAG |
| | `audit.agent.okta_id` | `jwt.act.okta_agent_id`: Okta's own AI Agent id | IdP-signed |
| | `audit.agent.via_app` | `jwt.act.act.sub`: the app the reviewer signed into | IdP-signed |
| | `audit.declared.*` | `X-Agent-Name` / `X-Agent-Version` / `User-Agent` | **declared** by the caller |
| Q2 whose authority | `jwt.sub`, `audit.user.email` | the reviewer | IdP-signed |
| | `audit.user.groups` | resource-side entitlement (Okta can't carry groups in an ID-JAG) | resource-governed |
| | `audit.token.scopes` | ceiling set by the Okta connection's scope policy | IdP-governed |
| | `audit.token.issuer`, `.audience`, `.expiry`, `.idjag_id` | the validated token; `idjag_id` links to Okta's issuance | present only after validation |
| Q3 what it called | `mcp.method.name`, `gen_ai.tool.name`, `mcp.target`, `route` | built in | gateway-observed |
| | `audit.caller.unverified_*` | resolved from the source IP | attribution, **not** authentication |
| Q4 which control decided | `http.status`, `reason`, `error` | built in; `reason` names the policy class that changed the outcome | gateway-observed |
| join | `trace.id`, `span.id` | built in; the agents forward `traceparent` | — |

A line carrying `audit.token.issuer` is itself the record that signature, issuer, audience and expiry
checked out: the gateway publishes claims to CEL only after validation. A refusal before validation
(no token, bad signature) is still recorded, with `reason=JwtAuth` and the specific `error`
(tests/10).

## What the run showed

- **The refused attempt exists only in the gateway record.** For the trace above, claims-mcp's own
  log has a `get_claim` line and nothing for the approve, because the call never reached it.
  intake-agent's log says `refused`, in its own words. An application-log-only audit trail would hold
  no record of the control working.
- **The join works.** The trace id on the gateway record equals the trace id on each application's
  own log line for the same call (tests/80), with no application change beyond forwarding
  `traceparent`.
- **Denied tools are filtered from discovery.** `tools/list` for intake-agent omits
  `approve_prior_auth`; a forced call gets HTTP 400 with JSON-RPC `-32602 Unknown tool`, logged with
  `reason=MCP`.
- **Nested `act` traversal works in CEL** on 2026.7.1-patch.2: `jwt.act.sub` and `jwt.act.act.sub`
  both evaluate, in the tool policy and in log attributes.
- **`endpoint` is absent on MCP relay calls.** Use `mcp.target` (the relay target name) instead.
- **Loki keys the stream on the gateway name** (`service_name="agw"`) and turns attribute dots into
  underscores (`audit.agent.id` → `audit_agent_id`).

## Querying it

```bash
CLUSTER=<c> bash bundles/agent-audit-evidence/helpers/evidence-query.sh
CLUSTER=<c> TRACE=<trace.id> bash bundles/agent-audit-evidence/helpers/evidence-query.sh
```

Grafana → Explore → Loki:

```logql
{service_name="agw"} | gen_ai_tool_name="approve_prior_auth" | mcp_method_name="tools/call"
  | line_format "{{.audit_agent_id}} for {{.audit_user_email}} -> {{.http_status}} {{.reason}}"
```

Tool-call arguments are deliberately not logged (`audit.mcp.tool_arguments` is commented out). They
are the likeliest place for regulated data to enter a log pipeline, so turn them on as a decision.
