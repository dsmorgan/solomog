# Demo script

The four steps on the "replay last month" slide, about three minutes of screen time. Every command
is copy-pasteable. `helpers/demo.sh` runs the same four steps one keypress at a time.

## Before you record

```bash
solomog apply BUNDLE=agent-audit-evidence CLUSTER=<c>        # idempotent; safe to re-run
bash bundles/agent-audit-evidence/helpers/xaa-login.sh       # reviewer login, lasts ~1h
solomog test BUNDLE=agent-audit-evidence CLUSTER=<c>         # 10/10 before you hit record
```

Open two windows: a terminal at ~110 columns, and Grafana (`https://grafana.agw.<c>.test`, admin /
prom-operator) on **Explore → Loki**. Optional third: the Solo UI traces view at
`https://ui.agw.<c>.test/age/`.

## The run

```bash
CLUSTER=<c> bash bundles/agent-audit-evidence/helpers/demo.sh
```

| Step | On screen | Say |
|---|---|---|
| 01 SIGN IN | the reviewer's Okta ID token claims | "One reviewer, one Okta login. Two agents will act for her." |
| 02 LOOK | each agent's `act.sub` and tool list | "Same person, same tools server, identical agent code. The prior-auth agent sees approve. The intake agent doesn't, so it can't pick it." |
| 03 ESCAPE | intake's forced approve: `REFUSED at the gateway (HTTP 400 -32602)` | "So we make it try to escape. That's last month's incident. Refused at the checkpoint." |
| 04 ASK | the evidence table, then both app logs for the refused trace | "Now the auditor's question: which agent, whose authority, what it called, and which control decided. One query. And look: the claims system's own log has no approve line at all. It never saw the attempt. Only the gateway can prove the control ran." |

Then open the refused trace in the Solo UI (traces, route `claims-tools`, status 400); the span
carries the `audit.*` fields. Last, switch to Grafana and paste the query from the end of step 4. Expand one row to show every field.
That's the "this is what your SIEM gets" moment.

## If a Shark asks

| Question | Answer, and where to show it |
|---|---|
| "Can the agent lie about who it is?" | It can lie in `audit.declared.*`, and the record keeps that apart from `audit.agent.id`, which comes from an Okta-signed assertion. Show both in the Grafana row. |
| "What stops an agent calling the tool directly?" | The tools server only accepts the composite token, validated at `/claims-tools`. Nothing else is routable to it. In production, pair it with mesh mTLS. |
| "Does this need agent code changes?" | Point the agent's tool calls at the gateway. Forwarding `traceparent` is only needed for the log join. |
| "Is Okta Cross App Access real?" | GA, enabled through Okta Support. Okta can't carry groups in an ID-JAG, so entitlements are resource-side, and the record says so. |
| "Can I debug one request live?" | Yes: `agctl` traces a request through the proxy as it happens. That's for operators; the evidence is the record, because it covers last month. Captured bodies aren't redacted, so don't use it on regulated traffic. |
| "What about the tool arguments?" | Off by default on purpose: regulated data. One commented line in `60-evidence-telemetry.yaml.tmpl`. |
