# agent-audit-evidence — who approved that? One gateway record per agent tool call

A reviewer signs in once. Two agents act for her through agentgateway against one claims MCP
server. Only the named prior-auth agent may see or call `approve_prior_auth`, and every tool call
leaves one access record that answers an auditor's four questions: which agent, whose authority,
what it called, and which control decided. Identity comes from Okta Cross App Access (ID-JAG), so
the agent is named in an Okta-signed `act` chain, not by the agent itself.

| | |
|---|---|
| Covers | Cross App Access at checkpoint 1, `act`-keyed MCP tool policy at checkpoint 2, the evidence record (stdout, OTLP, Loki, trace spans), and the `trace.id` join to each app's own log |
| Needs | enterprise agentgateway + `expose`; `monitoring` for Grafana. An Okta org with Cross App Access enabled and two AI Agents ([docs/OKTA-SETUP.md](docs/OKTA-SETUP.md)); one browser login |
| Versions | verified on **2026.7.1-patch.2** (LTS) |
| Clash-safe | **no** — owns the Gateway's `parametersRef` and adds attributes to the gateway's tracing policy |
| Verified | 10/10 on `audit`, 2026-09-25 |

## Run it

```bash
solomog agentgateway:ui monitoring expose CLUSTER=<c>
solomog apply BUNDLE=agent-audit-evidence CLUSTER=<c>
bash bundles/agent-audit-evidence/helpers/xaa-login.sh        # reviewer login, ~1h
solomog test BUNDLE=agent-audit-evidence CLUSTER=<c>
```

Tests 00, 05 and 10 need no login. The rest skip without one and fail on an expired one.

## Demo it

```bash
CLUSTER=<c> bash bundles/agent-audit-evidence/helpers/demo.sh            # 4 steps, enter to advance
CLUSTER=<c> bash bundles/agent-audit-evidence/helpers/evidence-query.sh  # the auditor's query, any time
```

Run of show and talk track: [docs/DEMO-SCRIPT.md](docs/DEMO-SCRIPT.md). What each field means and
where it comes from: [docs/EVIDENCE.md](docs/EVIDENCE.md).

## Routes

| Path | Checkpoint | What it does |
|---|---|---|
| `/agents/priorauth`, `/agents/intake` | 1 | validate the reviewer's ID token, run both XAA legs, hand the composite to the agent |
| `/probe/priorauth`, `/probe/intake` | 1 | same policy, echoes the minted token (bring-up and tests) |
| `/claims-tools` | 2 | validate the composite, then deny `approve_prior_auth` unless `act.sub` is the prior-auth agent and the reviewer holds the reviewer group |

## `.env`

Okta facts keep their shared `XAA_*` names (any Cross App Access bundle on the tenant uses the same
objects). This bundle's own knobs are `EVIDENCE_*`; every one has a default. The two you are most
likely to set:

- `EVIDENCE_RESOURCE_AS_ISSUER` — must equal the Issuer URL on the Okta resource app.
- `EVIDENCE_PRIORAUTH_SCOPES` / `EVIDENCE_INTAKE_SCOPES` — must be allowed by each agent's Okta
  resource connection (defaults `claims.read claims.approve` / `claims.read`).

The full list is in the header of each root hook.
