# Okta setup for agent-audit-evidence

Everything you do in Okta, in order. Verified against agentgateway 2026.7.1-patch.2 on 2026-09-24.
If your tenant already runs another Cross App Access bundle, you can reuse its objects: set the
`XAA_*` values it uses and skip to step 6.

## What you're building

Cross App Access (XAA) is a two-leg exchange. Okta performs leg 1: it turns the reviewer's **ID
token** into an **ID-JAG** asserting "this agent may act for this user at that resource". Leg 2
redeems the ID-JAG at the resource's own authorization server, which in this bundle runs in the
cluster. Okta's resource app is only the registration anchor.

| Object | Okta type | Role | What the bundle needs |
|---|---|---|---|
| `claims-resource` | OIDC Web App | anchor the ID-JAG's `aud` binds to | nothing |
| `reviewer-login` | OIDC Web App | the reviewer signs in here; mints the ID token. One app for both agents | client id + secret |
| `priorauth-agent` | **AI Agent** (Directory) | leg-1 client for the prior-auth agent | agent id (`wlp…`) + private key |
| `intake-agent` | **AI Agent** | leg-1 client for the intake agent | agent id + private key |

Two rules prevent most of the confusing errors:

- **The login app and the agents are different objects with different credentials.** The app holds a
  client secret; each agent holds its own private key. Don't mix up the key files.
- **Name the login app for the user, never for an agent.** The Delegations tab shows labels only, so
  an app that shares an agent's name reads as the agent calling itself. Verify rows by client id.

## Step 1: get the feature enabled

XAA is generally available, but enabling it isn't self-service. Since Okta release 2026.07.0, you
contact Okta Support (or Developer Support for an Integrator Free Plan org). The AI Agent objects
also need **Directory → AI Agents** to exist in the admin console.

A saved "Cross-app access: Enabled" panel is **not** evidence that the feature works: it saves on an
unentitled org too. To tell entitlement from misconfiguration, open **Reports → System Log**, filter
`eventType eq "app.oauth2.token.grant"`, and read `DebugData.TokenExchangeType` on the failure.
`ID Assertion` means the feature is present and the problem is the client or the connection.

## Step 2: the resource app

**Applications → Create App Integration → OIDC → Web Application**, named `claims-resource`.
Grant type **Authorization Code** only; the redirect URI is a placeholder.

Open **Resource Server → Cross-app access (XAA) → Edit → Enable**, and set:

| Field | Value | Bundle knob |
|---|---|---|
| Resource URL | `https://claims.evidence.test/mcp` | `EVIDENCE_RESOURCE_API` |
| Issuer URL | `https://evidence-resource-as.agent-evidence.svc.cluster.local` | `EVIDENCE_RESOURCE_AS_ISSUER` |
| Audience/tenant ID | blank | — |

**The Issuer URL is the riskiest value here.** It becomes the ID-JAG's `aud`, and the in-cluster
resource AS rejects any assertion whose `aud` is not its own issuer. The Okta field and
`EVIDENCE_RESOURCE_AS_ISSUER` must match byte for byte, with no trailing slash. Okta never
dereferences it, so an in-cluster `.svc.cluster.local` name works. If you reuse an existing resource
app, set `EVIDENCE_RESOURCE_AS_ISSUER` to whatever it already has.

## Step 3: the login app

**Applications → Create App Integration → OIDC → Web Application**, named `reviewer-login`:

| Setting | Value |
|---|---|
| Grant types | Authorization Code |
| Sign-in redirect URI | `http://localhost:8899/callback` (`XAA_REDIRECT_URI`) |
| Client authentication | Client secret |
| Assignments | the reviewer |

## Step 4: the two AI Agents

**Directory → AI Agents**, once per agent:

1. **Register AI Agent → Register Manually**, named `priorauth-agent` (then `intake-agent`). Note
   the agent id (`wlp…`).
2. **Credentials → Add public key → Generate new key**, for **client auth (sig)**. Save the private
   key as a PEM (it's shown once) and note the Key ID. **Then activate the key** (ellipsis menu →
   Activate): an inactive key fails leg 1 as `invalid_client`. Got a JWK instead of a PEM? Run
   `helpers/xaa-jwk-to-pem.sh <file>`.
3. **Delegations → User sign-on → Add caller → Application** → `reviewer-login`. Do this on **both**
   agents, naming the same app; it's how one login serves two agents. The row should read
   `ON BEHALF OF User · AUTHORIZATION SERVER Okta Authorization Server`. Ignore the Non-human identity
   panel beside it.
4. **Resource connections → Add → Application → App configured for AI agent access** →
   `claims-resource`, with:

   | Field | priorauth-agent | intake-agent |
   |---|---|---|
   | Client ID at the Resource Authorization Server | `priorauth-agent` | `intake-agent` |
   | Scope policy: Only allow | `claims.read claims.approve` | `claims.read` |

   **The Client ID field is the agent's name in the audit record.** Okta signs it into the ID-JAG as
   `client_id`, and the resource AS puts it in `act.sub`, which the tool policy and every record
   read. It must differ between the agents, and match `EVIDENCE_PRIORAUTH_ACTOR` /
   `EVIDENCE_INTAKE_ACTOR` (defaults `priorauth-agent` / `intake-agent`).

   **Choose it carefully: Okta makes it read-only once the connection is saved.** The edit form shows
   it greyed out as "AI agent's client ID registered in this app". Changing it later means removing
   and re-adding the connection. The scopes stay editable.

   The scope policy is the one ceiling Okta itself enforces on XAA. The bundle requests
   `EVIDENCE_PRIORAUTH_SCOPES` / `EVIDENCE_INTAKE_SCOPES`, and Okta answers `invalid_scope` for
   anything the policy doesn't allow.

## Step 5: assign the reviewer

Assign the reviewer to `reviewer-login` and `claims-resource`.

## Step 6: fill in `.env`

```bash
XAA_AGENT_AUTH=PrivateKeyJwt
XAA_LOGIN_CLIENT_ID=0oa…                  # reviewer-login: the edge JWT audience on every agent route
XAA_LOGIN_CLIENT_SECRET=…
XAA_AGENT_A_CLIENT_ID=wlp…                # priorauth-agent
XAA_AGENT_A_PRIVATE_KEY=/path/to/priorauth-agent.pem
XAA_AGENT_A_KEY_KID=…
XAA_AGENT_B_CLIENT_ID=wlp…                # intake-agent
XAA_AGENT_B_PRIVATE_KEY=/path/to/intake-agent.pem
XAA_AGENT_B_KEY_KID=…
EVIDENCE_REVIEWERS="reviewer@example.com" # granted priorauth-reviewer by the resource AS
```

`EVIDENCE_REVIEWERS` defaults to `XAA_PRIVILEGED_USERS`. Okta can't carry `groups` in an ID-JAG, so
the resource AS resolves the reviewer's entitlement itself, keyed on the email Okta asserts. The
reviewer's **identity** is IdP-attested; their **entitlement** is resource-governed. Say so if a
security audience asks.

## Step 7: verify

```bash
solomog apply BUNDLE=agent-audit-evidence CLUSTER=<c>
bash bundles/agent-audit-evidence/helpers/xaa-login.sh
solomog test BUNDLE=agent-audit-evidence CLUSTER=<c> TESTS=08    # asks Okta directly, both agents
solomog test BUNDLE=agent-audit-evidence CLUSTER=<c>
```

Test 08 prints each ID-JAG's claims. Its `client_id` is the value you typed in step 4.4, and its
`scope` is what the connection's scope policy allowed.

## Troubleshooting

From the gateway, every leg-1 failure looks the same (`400 invalid request`, empty resource AS log).
Start with test 08 or the System Log, then:

```bash
kubectl --context "$CONTEXT" -n agent-evidence logs deploy/evidence-resource-as --tail=50   # leg 2
```

| Symptom | Cause |
|---|---|
| `invalid_scope` on leg 1 | The requested scopes aren't allowed by the connection's scope policy (step 4.4). |
| `The client_assertion JWT kid is invalid` | Wrong `kid`, or a key that belongs to another client. |
| `invalid_client` on leg 1 | Agent key not activated, wrong `kid`, or the wrong PEM. |
| `invalid_requested_token_type` | The leg-1 client isn't an AI Agent with a resource connection. |
| `not registered for delegation to this agent` | `reviewer-login` isn't a delegated caller on that agent (step 4.3). One agent passing and the other failing is the tell. |
| `'subject_token' is invalid`, no trailing clause, or edge `ExpiredSignature` | The ID token expired (about 1h). Re-run `xaa-login.sh`. |
| Resource AS: `assertion aud != this resource AS` | Okta's Issuer URL and `EVIDENCE_RESOURCE_AS_ISSUER` differ. |
| Resource AS: `assertion actor … is not a registered agent` | The connection's Client ID and `EVIDENCE_*_ACTOR` differ. |
| tests/20: `act.sub` shows an old value | Same as above, from the other side. |
| `invalid_target` | Okta rejects the RFC 8707 `resource` parameter; this bundle never sends it. |

## Tearing it down

Okta objects cost nothing at idle. On the cluster:

```bash
kubectl --context "$CONTEXT" delete namespace agent-evidence
kubectl --context "$CONTEXT" -n agentgateway-system delete httproute agents-priorauth agents-intake \
  probe-priorauth probe-intake claims-tools
kubectl --context "$CONTEXT" -n agentgateway-system delete enterpriseagentgatewaypolicy \
  agents-priorauth-xaa agents-intake-xaa probe-priorauth-xaa probe-intake-xaa \
  claims-tools-authz claims-tools-rbac evidence-telemetry
kubectl --context "$CONTEXT" -n agentgateway-system delete enterpriseagentgatewaybackend \
  evidence-okta-idp evidence-resource-as evidence-probe-echo priorauth-agent-svc intake-agent-svc claims-mcp-relay
```
