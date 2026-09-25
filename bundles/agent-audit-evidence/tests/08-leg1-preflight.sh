# PREFLIGHT — can this Okta org mint an ID-JAG at all?
#
# WHY THIS TEST EXISTS. When Cross App Access is not enabled on the org, every downstream test fails
# the same opaque way: the gateway returns `400 invalid request` / `reason=Internal`, the response body
# is the string "invalid request", and the resource AS logs show nothing at all (leg 2 is never
# reached). Nothing in that picture names Okta, so the natural reading is "my gateway config is
# broken" — which sends you debugging the wrong half. Verified on 2026-08-04: that is exactly what a
# non-enabled org looks like from the outside.
#
# So this asks Okta directly and reports the cause in plain words. It runs BEFORE the probe tests
# (08 < 20) so the first red line you read is the true one.
#
# IT CHECKS BOTH AGENTS, and that is a correction, not a nicety. This test used to preflight agent A
# only — so on 2026-08-05 it passed while agent B's leg 1 was broken, and the three downstream failures
# all reported the gateway's opaque `400 invalid request` with nothing pointing at Okta. A localiser
# that cannot see one of the two things it is localising is worse than useless: it actively argues the
# problem is elsewhere. The two agents have DIFFERENT credentials and DIFFERENT Okta connections, so
# they are two independent leg-1 configurations and both need asking.
#
# ⚠️ WHAT THIS TEST CANNOT TELL YOU — corrected 2026-08-04 after it drew the wrong conclusion.
# An earlier version reported "'requested_token_type' is invalid or not supported" as PROOF that the
# org lacks the XAA entitlement. That was an over-read. Okta returns the same error when the feature
# IS present but the *requesting client* is not eligible for the ID-Assertion exchange — per
# blog.christianposta.com/okta-saml-and-keycloak-for-id-jag-cross-app-access/, the token-exchange
# client must be an **AI Agent** authenticated with **private_key_jwt**; a normal OIDC web/API client
# "tends to land in On-Behalf-Of and fail". A plain confidential web app on client_secret_basic is
# therefore expected to fail this way on a fully-enabled org.
#
# The ONLY place that distinguishes the two is Okta's **System Log** (Reports → System Log, filter
# eventType eq "app.oauth2.token.grant"). Look at `DebugData.TokenExchangeType`:
#   • "ID Assertion"  → Okta ROUTED this as an XAA exchange, so the feature is present and the
#                       rejection is about the client/connection, not the entitlement.
#   • absent, or the event never appears → then suspect the entitlement.
# Observed 2026-08-04 on a developer org: TokenExchangeType="ID Assertion" alongside
# Reason="invalid_requested_token_type", with the subject ID token resolved and the audience echoed
# as AuthorizationServerAudience — i.e. the feature was there and the web-app client was the problem.
#
# So: this test tells you leg 1 is failing and hands you Okta's own words for it. Treat the cause as a
# hypothesis to check in the System Log, not a verdict.
#
# Deliberately uses the CACHED ID token rather than minting one: this must not open a browser, and a
# stale token still produces a meaningful answer (a capability error is returned before subject
# validation — an expired subject would say so explicitly instead).
set -euo pipefail

[ -n "${XAA_AGENT_A_CLIENT_ID:-}" ] || { echo "↷ skipped — XAA_AGENT_A_CLIENT_ID not set (bundle not configured; see docs/OKTA-SETUP.md)"; exit 0; }
: "${OKTA_DOMAIN:?set OKTA_DOMAIN in .env}"
AGENT_AUTH="${XAA_AGENT_AUTH:-${XAA_CLIENT_AUTH_METHOD:-ClientSecretBasic}}"

REPO_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
HELPERS="$(cd "$(dirname "$0")/../helpers" && pwd)"

# Subject freshness. Okta rejects an ineligible requested_token_type BEFORE validating the subject, so
# a stale token still yields a meaningful capability answer — verified 2026-08-05, where a 3h-expired
# ID token still produced invalid_requested_token_type rather than an expiry error. But a conclusion
# drawn from a confounded run is worth less than one from a clean run, and re-minting is one command.
# NOTE: a "not registered for delegation" error is ALSO reported as `'subject_token' is invalid`, so an
# expired subject and a missing delegation look similar at a glance — hence this warning.
warn_if_stale() {   # $1 = the ID token
  SUB_EXP=$(printf '%s' "$1" | cut -d. -f2 | tr '_-' '/+' \
    | awk '{n=length($0)%4; if(n==2)$0=$0"=="; else if(n==3)$0=$0"="; print}' \
    | base64 -d 2>/dev/null | jq -r '.exp // empty')
  if [ -n "$SUB_EXP" ] && [ "$SUB_EXP" -lt "$(date +%s)" ]; then
    echo "  ⚠ the cached ID token EXPIRED $(( ( $(date +%s) - SUB_EXP ) / 60 ))m ago." >&2
    echo "    A capability error below is still trustworthy (Okta checks the token type first), but any" >&2
    echo "    subject/connection/assignment error is NOT — re-mint first: bash helpers/xaa-login.sh" >&2
  fi
}

AUDIENCE="${EVIDENCE_RESOURCE_AS_ISSUER:-https://evidence-resource-as.agent-evidence.svc.cluster.local}"
RESOURCE_API="${EVIDENCE_RESOURCE_API:-https://claims.evidence.test/mcp}"
TOKEN_URL="https://${OKTA_DOMAIN}/oauth2/v1/token"

# The login app, resolved exactly as 44-checkpoint1-policies.sh and helpers/xaa-login.sh do — so the
# delegation message below can NAME the app that must be registered rather than say "the login app".
login_app_for() {   # $1 = A|B
  eval "printf '%s' \"\${XAA_AGENT_${1}_LOGIN_CLIENT_ID:-\${XAA_AGENT_${1}_AUDIENCE:-\${XAA_LOGIN_CLIENT_ID:-\${XAA_AGENT_${1}_CLIENT_ID:-}}}}\""
}

# Okta rejects the RFC 8707 `resource` parameter here (invalid_target) — verified 2026-08-05. Kept as a
# knob so a future Okta change can be retested in one command rather than by editing this file.
if [ "${XAA_SEND_RESOURCE:-false}" = "true" ]; then
  SEND_RESOURCE_ARG="--data-urlencode resource=${RESOURCE_API}"
else
  SEND_RESOURCE_ARG=""
fi

# ── THE DISCRIMINATING EXPERIMENT this supports ─────────────────────────────────────────────────
# Posta's finding ("the token-exchange client must be the AI Agent … a normal OIDC Web/API tends to
# land in On-Behalf-Of and fail") bundles TWO variables together:
#   (i)  the client is an AI Agent OBJECT   — needs Directory > AI Agents, maybe a separate entitlement
#   (ii) the client uses private_key_jwt    — ANY confidential OIDC app can do this today, no
#        entitlement: General > Client Credentials > Client authentication > "Public key / Private key"
# RESULT, run 2026-08-05 on a developer org: a plain Web App switched to private_key_jwt
# (Client auth "sig" key registered, ClientAuthType=private_key_jwt confirmed in the System Log)
# STILL returned invalid_requested_token_type, with TokenExchangeType=ID Assertion. So (ii) is
# ELIMINATED — the auth method was never the constraint. It is (i) the AI Agent object, and/or the
# missing agent→resource CONNECTION. Posta's phrasing bundles those together; this run separates the
# auth method out of the explanation.
# Keep the knob: private_key_jwt is still what the AI-Agent path requires, so this is now the
# credential path rather than an experiment.

preflight() {   # $1 = a|b   -> 0 pass, 1 fail, 2 skip
  L="$1"; U=$(printf '%s' "$L" | tr 'a-z' 'A-Z')
  eval "CLIENT_ID=\${XAA_AGENT_${U}_CLIENT_ID:-}"
  eval "AGENT_KEY=\${XAA_AGENT_${U}_PRIVATE_KEY:-}"
  eval "AGENT_KID=\${XAA_AGENT_${U}_KEY_KID:-\${XAA_AGENT_KEY_KID:-}}"
  eval "AGENT_SECRET=\${XAA_AGENT_${U}_CLIENT_SECRET:-}"
  # a = priorauth-agent, b = intake-agent — the same scopes 44-checkpoint1-policies.sh requests.
  if [ "$L" = a ]; then SCOPES="${EVIDENCE_PRIORAUTH_SCOPES:-claims.read claims.approve}"
  else SCOPES="${EVIDENCE_INTAKE_SCOPES:-claims.read}"; fi

  [ -n "$CLIENT_ID" ] || { echo "── agent ${U}: not configured (XAA_AGENT_${U}_CLIENT_ID unset) — skipped"; return 2; }

  if [ "$AGENT_AUTH" = "PrivateKeyJwt" ]; then
    [ -n "$AGENT_KEY" ] || { echo "✗ agent ${U}: XAA_AGENT_AUTH=PrivateKeyJwt needs XAA_AGENT_${U}_PRIVATE_KEY — the PEM path" >&2; return 1; }
  else
    [ -n "$AGENT_SECRET" ] || { echo "✗ agent ${U}: set XAA_AGENT_${U}_CLIENT_SECRET in .env (or XAA_AGENT_AUTH=PrivateKeyJwt)" >&2; return 1; }
  fi

  CACHE=$(bash "$HELPERS/xaa-token-path.sh" "$L") || {
    echo "↷ agent ${U}: no cached ID token; run helpers/xaa-login.sh first"; return 2; }
  ID_TOKEN=$(jq -r '.id_token // empty' "$CACHE")
  [ -n "$ID_TOKEN" ] || { echo "↷ agent ${U}: cached ID token unreadable; re-run helpers/xaa-login.sh"; return 2; }

  echo "── agent ${U}: will https://${OKTA_DOMAIN} mint an ID-JAG?"
  echo "    client=${CLIENT_ID}  auth=${AGENT_AUTH}  scope=[${SCOPES}]"
  warn_if_stale "$ID_TOKEN"

  if [ "$AGENT_AUTH" = "PrivateKeyJwt" ]; then
    CLIENT_ASSERTION=$(KID_OVERRIDE="$AGENT_KID" bash "$HELPERS/xaa-client-assertion.sh" \
      "$CLIENT_ID" "$AGENT_KEY" "$TOKEN_URL") || {
        echo "✗ agent ${U}: could not build the client_assertion — check XAA_AGENT_${U}_PRIVATE_KEY" >&2; return 1; }
    set -- --data-urlencode "client_id=${CLIENT_ID}" \
           --data-urlencode 'client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer' \
           --data-urlencode "client_assertion=${CLIENT_ASSERTION}"
  else
    set -- -u "${CLIENT_ID}:${AGENT_SECRET}"
  fi

  RESP=$(curl -sS -X POST "$TOKEN_URL" "$@" \
    -H 'Accept: application/json' \
    --data-urlencode 'grant_type=urn:ietf:params:oauth:grant-type:token-exchange' \
    --data-urlencode 'requested_token_type=urn:ietf:params:oauth:token-type:id-jag' \
    --data-urlencode 'subject_token_type=urn:ietf:params:oauth:token-type:id_token' \
    --data-urlencode "subject_token=${ID_TOKEN}" \
    --data-urlencode "audience=${AUDIENCE}" \
  ${SEND_RESOURCE_ARG} \
    --data-urlencode "scope=${SCOPES}") || {
      echo "✗ agent ${U}: could not reach Okta's org token endpoint" >&2; return 1; }

  ERR=$(printf '%s' "$RESP" | jq -r '.error // empty')
  DESC=$(printf '%s' "$RESP" | jq -r '.error_description // empty')

  if [ -z "$ERR" ]; then
    ISSUED=$(printf '%s' "$RESP" | jq -r '.issued_token_type // empty')
    echo "  ✓ Okta minted a token (issued_token_type=${ISSUED:-<unset>})"
    [ "$ISSUED" = "urn:ietf:params:oauth:token-type:id-jag" ] || {
      echo "✗ agent ${U}: expected an ID-JAG, got issued_token_type=${ISSUED:-<unset>}" >&2; return 1; }
    # Draft §5.2 conformance, both fields. Okta's own client library asserts these and throws if either
    # is wrong (oktadev/okta-cross-app-access-mcp, id-assert-authz-grant-client/request-id-jwt-authz-grant.ts),
    # so a mismatch means the IdP is not speaking the grant properly — worth catching here rather than
    # as a confusing leg-2 failure.
    TOKTYPE=$(printf '%s' "$RESP" | jq -r '.token_type // empty' | tr 'A-Z' 'a-z')
    [ "$TOKTYPE" = "n_a" ] || echo "  ⚠ token_type=${TOKTYPE:-<unset>}, expected 'n_a' per ID-JAG draft §5.2" >&2
    # The claims that decide everything downstream, printed so a later act.sub surprise is traceable.
    ASSERTION=$(printf '%s' "$RESP" | jq -r '.access_token')
    SEG=$(printf '%s' "$ASSERTION" | cut -d. -f2 | tr '_-' '/+')
    case $(( ${#SEG} % 4 )) in 2) SEG="${SEG}==" ;; 3) SEG="${SEG}=" ;; esac
    printf '%s' "$SEG" | base64 -d 2>/dev/null \
      | jq -c '{client_id, sub, aud, iss, scope, resource, groups: (.groups // "«absent»")}' \
      | sed 's/^/  ID-JAG: /'
    return 0
  fi

  echo "  Okta said: ${ERR} — ${DESC}" >&2

  # invalid_client is decided BEFORE Okta considers the grant at all, so it says nothing about XAA.
  # Handle it separately or the message below draws a conclusion the response cannot support.
  if [ "$ERR" = "invalid_scope" ]; then
    cat >&2 <<EOM
✗ agent ${U}: Okta minted nothing because the scopes [${SCOPES}] are not allowed on this agent's
  resource connection. Either allow them in Okta (Directory > AI Agents > the agent > Resource
  connections > Scope policy) or request what the connection allows, e.g. in .env:
    EVIDENCE_PRIORAUTH_SCOPES="treasury.read treasury.write"
    EVIDENCE_INTAKE_SCOPES="treasury.read"
  then re-apply the bundle (44-checkpoint1-policies.sh sends the same scopes).
EOM
    return 1
  fi
  if [ "$ERR" = "invalid_client" ]; then
    cat >&2 <<EOM
✗ agent ${U}: client authentication failed — this is upstream of anything XAA-related, so it tells you
  NOTHING about whether Cross App Access works. Fix the credential, then re-run.
    auth=${AGENT_AUTH}
  If the message mentions a missing JWKSet: the app has no public key registered, so it cannot use
  private_key_jwt yet. For an ordinary OIDC app: Applications > <app> > General > Client Credentials >
  Client authentication > "Public key / Private key" > Add key > Generate new key, save the PRIVATE key
  and point XAA_AGENT_${U}_PRIVATE_KEY at it. For an AI Agent object it is the Credentials tab
  (and remember to ACTIVATE the key — docs/OKTA-SETUP.md step 4).
  If it mentions the assertion audience: \`aud\` must be the token ENDPOINT (${TOKEN_URL}).
EOM
    return 1
  fi

  case "$DESC" in
    *"not registered for delegation"*)
      # MEASURED 2026-08-05, and unusually precise for an Okta leg-1 error — it names the exact missing
      # object. Collapsing to one shared login app makes this the single most likely failure, because
      # the app is typically registered on agent A only and agent B is then the odd one out.
      LOGIN_APP=$(login_app_for "$U")
      cat >&2 <<EOM
✗ agent ${U}: the app that minted this ID token is NOT a registered delegated caller on this agent, so
  Okta will not exchange it for THIS agent's ID-JAG. Okta names the missing object exactly, which is
  rare — believe it.

  ⚠️ THE DELEGATIONS LIST IS PROBABLY NOT EMPTY. Expect to find a row already there for a DIFFERENT
  app, which is why this looks like it is already configured. Check the CALLER column names the app
  whose client id is:
      ${LOGIN_APP}
  and if it does not, ADD IT — an existing row for another app does nothing for this one.

  The CALLER column shows only labels, so verify by client id — an app whose name resembles an agent's
  is a separate object entirely.

  FIX:
    Okta Admin Console > Directory > AI Agents > the agent whose id is ${CLIENT_ID}
      > Delegations > "User sign-on" panel > Add caller > Application or service
      > the app whose client id is ${LOGIN_APP} > Add caller
  Correct result reads:  CALLER <app> · ON BEHALF OF User · AUTHORIZATION SERVER Okta Authorization Server
  (that last column being the ORG authorization server is what confirms the XAA path). Leaving the old
  row in place is harmless; an agent may have several callers.

  WHY THIS AGENT AND NOT THE OTHER: with one shared login app (XAA_LOGIN_CLIENT_ID) the SAME app must be
  registered on BOTH agents. It is usually already registered on whichever agent it was created for, so
  that agent passes and the other fails with otherwise identical config. Registering "agent A's app" on
  agent B feels wrong but is the point: the app is only the front door the human logs in through, and it
  does not decide which agent acts — the leg-1 credential does. See docs/OKTA-SETUP.md step 4.3.

  Do NOT confuse this with an expired subject: both are reported as \`'subject_token' is invalid\`. The
  trailing clause is what distinguishes them, and the ⚠ above says whether the token is stale.
EOM
      return 1 ;;
    *requested_token_type*|*actor_token*)
      cat >&2 <<EOM
✗ agent ${U}: Okta refused to mint an ID-JAG for this client. TWO causes produce this same error — go to
  the System Log to tell them apart, because they need opposite actions:

  (1) THE CLIENT IS NOT ELIGIBLE  ← most likely if you are using a plain OIDC app + client secret
      Okta only offers the ID-Assertion exchange to an **AI Agent** client authenticated with
      **private_key_jwt**. A normal OIDC Web/API client falls through to On-Behalf-Of and fails.
      Fix: register the agent under Directory > AI Agents, give it a key, add the OIDC app as a
      delegated caller, then set XAA_AGENT_AUTH=PrivateKeyJwt (docs/OKTA-SETUP.md step 4).

  (2) THE ORG LACKS THE ENTITLEMENT
      Per OIE release note 2026.07.0 the self-service toggle is gone: "contact Okta Support. If you
      have an Integrator Free Plan org, contact Developer Support instead." The EA toggles are named
      "AI Agent Identity Assertion" and "Agent to Agent Connections" (searching for "Cross App
      Access" finds nothing). NOTE: the Resource Server > Cross-app access panel saving as ENABLED
      is NOT evidence either way — verified: it saves fine on a non-entitled org.

  HOW TO TELL: Admin Console > Reports > System Log, filter
    eventType eq "app.oauth2.token.grant"
  open the FAILURE event and read DebugData.TokenExchangeType:
    "ID Assertion" → Okta routed this as XAA ⇒ the feature is present ⇒ cause (1), or a missing
                     agent-to-resource connection. Check Outcome.Reason for which.
    absent / no event at all → suspect cause (2).
  See docs/OKTA-SETUP.md step 1 and step 4.
EOM
      return 1 ;;
    *)
      cat >&2 <<EOM
✗ agent ${U}: leg 1 rejected, but the org DOES support ID-JAG minting — so this is a config error, not
  an entitlement one. Most likely, in order of probability:
    1. no XAA resource connection from this agent to the resource app  (docs/OKTA-SETUP.md step 4.4 — it
       is created on the CONSUMER: Directory → AI Agents → <agent> → Resource connections)
    2. the login app is not a delegated caller on this agent  (step 4.3)
    3. the user is not assigned to the app  (step 5)
    4. audience mismatch: this sent audience=${AUDIENCE}, which must equal the resource app's
       "Issuer URL" field exactly
    5. resource mismatch: sent resource=${RESOURCE_API}, must equal its "Resource URL" field
  Okta's System Log carries the real reason — it is far more specific than this response.
EOM
      return 1 ;;
  esac
}

echo "==> leg 1 preflight against https://${OKTA_DOMAIN} (org AS) — BOTH agents"
RC=0
CHECKED=0
for L in a b; do
  # `|| true` so `set -e` cannot abort the loop before agent B is asked — the entire point of this
  # rework is that one agent's failure must not hide the other's state.
  preflight "$L" && S=0 || S=$?
  case "$S" in
    0) CHECKED=$((CHECKED+1)) ;;
    1) CHECKED=$((CHECKED+1)); RC=1 ;;
  esac
done

if [ "$CHECKED" = 0 ]; then
  echo "↷ skipped — no agent had both a client id and a cached ID token"
  exit 0
fi
[ "$RC" = 0 ] || exit 1
echo "✓ leg 1 works for every configured agent — this org mints ID-JAGs for both"
