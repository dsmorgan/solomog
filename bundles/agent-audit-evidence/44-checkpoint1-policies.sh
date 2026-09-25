# CHECKPOINT 1: edge authentication + the two-leg Cross App Access exchange, one policy per route.
#
# Per route, in order:
#   1. validate the reviewer's Okta ID token (Strict) against the Okta ORG authorization server;
#   2. leg 1 (RFC 8693) at Okta, authenticated as THAT agent's Okta AI Agent credential
#        subject_token = the ID token, requested_token_type = id-jag, audience = our resource AS
#        → an Okta-signed ID-JAG whose client_id is the agent's per-connection alias;
#   3. leg 2 (RFC 7523) at our in-cluster resource AS
#        → an access token with sub = reviewer, act.sub = agent, groups, scp;
#   4. that token replaces the inbound credential upstream.
#
# priorauth-agent uses Okta AI Agent A (XAA_AGENT_A_*), intake-agent uses AI Agent B (XAA_AGENT_B_*).
#
# .env / knobs:
#   OKTA_DOMAIN, XAA_AGENT_A_CLIENT_ID, XAA_AGENT_B_CLIENT_ID   required
#   XAA_LOGIN_CLIENT_ID      required  the OIDC app the reviewer signs into (0oa…); the edge audience
#   XAA_AGENT_AUTH           PrivateKeyJwt (AI Agents) | ClientSecretBasic | ClientSecretPost
#   XAA_AGENT_KEY_ALG        default RS256
#   XAA_AGENT_A_KEY_KID / XAA_AGENT_B_KEY_KID   optional `kid` for each agent's client_assertion
#   EVIDENCE_RESOURCE_AS_ISSUER   the ID-JAG audience (see 16-resource-as-config.sh)
#   EVIDENCE_PRIORAUTH_SCOPES     default "claims.read claims.approve"
#   EVIDENCE_INTAKE_SCOPES        default "claims.read"
#     Both must be allowed by the scope policy on that agent's Okta resource connection, or leg 1
#     answers invalid_scope. tests/08 asks Okta directly.
#   XAA_EXCHANGE_CACHE_TTL   default 5m
# CONTEXT exported by apply-bundle.sh.
set -euo pipefail

: "${OKTA_DOMAIN:?set OKTA_DOMAIN in .env}"
: "${XAA_AGENT_A_CLIENT_ID:?set XAA_AGENT_A_CLIENT_ID in .env — priorauth-agent Okta AI Agent id}"
: "${XAA_AGENT_B_CLIENT_ID:?set XAA_AGENT_B_CLIENT_ID in .env — intake-agent Okta AI Agent id}"
: "${XAA_LOGIN_CLIENT_ID:?set XAA_LOGIN_CLIENT_ID in .env — the OIDC app (0oa…) the reviewer signs into}"

case "$XAA_LOGIN_CLIENT_ID" in wlp*)
  echo "✗ XAA_LOGIN_CLIENT_ID=${XAA_LOGIN_CLIENT_ID} is an Okta AI Agent, not an app. Set it to the OIDC app's client id (0oa…)." >&2
  exit 1 ;;
esac

ISSUER="https://${OKTA_DOMAIN}"
TOKEN_PATH="/oauth2/v1/token"
JWKS_PATH="/oauth2/v1/keys"
RESOURCE_AS_ISSUER="${EVIDENCE_RESOURCE_AS_ISSUER:-https://evidence-resource-as.agent-evidence.svc.cluster.local}"
RESOURCE_CLIENT_ID="${EVIDENCE_RESOURCE_CLIENT_ID:-evidence-gateway}"
PRIORAUTH_SCOPES="${EVIDENCE_PRIORAUTH_SCOPES:-claims.read claims.approve}"
INTAKE_SCOPES="${EVIDENCE_INTAKE_SCOPES:-claims.read}"
AGENT_AUTH="${XAA_AGENT_AUTH:-ClientSecretBasic}"
KEY_ALG="${XAA_AGENT_KEY_ALG:-RS256}"
CACHE_TTL="${XAA_EXCHANGE_CACHE_TTL:-5m}"

client_auth() {  # $1 leg-1 client id  $2 secret base name  $3 kid (may be empty)
  if [ "$AGENT_AUTH" = "PrivateKeyJwt" ]; then
    cat <<EOF
            clientId: "${1}"
            method: PrivateKeyJwt
            privateKeyJwt:
              # Okta wants its TOKEN ENDPOINT URL as the assertion audience, not the issuer.
              assertionAudience: "${ISSUER}${TOKEN_PATH}"
              alg: ${KEY_ALG}${3:+
              kid: "${3}"}
              signingKeyRef:
                name: ${2}-key
                key: private_key
EOF
  else
    cat <<EOF
            clientId: "${1}"
            method: ${AGENT_AUTH}
            secretRef:
              name: ${2}
              key: client_secret
EOF
  fi
}

scope_items() {
  printf '%s' "$1" | tr ',' ' ' | awk '{for(i=1;i<=NF;i++) printf "          - \"%s\"\n", $i}'
}

apply_xaa() {  # $1 route  $2 leg-1 client id  $3 secret base  $4 scopes  $5 kid
  AUTH_BLOCK=$(client_auth "$2" "$3" "$5")
  ITEMS=$(scope_items "$4")
  kubectl --context "$CONTEXT" apply -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: ${1}-xaa
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: ${1}
  traffic:
    # The reviewer's OIDC ID token. Its audience is the login app's client id.
    jwtAuthentication:
      mode: Strict
      providers:
        - issuer: ${ISSUER}
          audiences:
            - ${XAA_LOGIN_CLIENT_ID}
          jwks:
            remote:
              backendRef:
                name: evidence-okta-idp
                namespace: agentgateway-system
                kind: EnterpriseAgentgatewayBackend
                group: enterpriseagentgateway.solo.io
              jwksPath: ${JWKS_PATH}
              cacheDuration: 5m
  backend:
    auth:
      crossAppAccess:
        identityProvider:              # leg 1: Okta mints the ID-JAG
          backendRef:
            name: evidence-okta-idp
            kind: EnterpriseAgentgatewayBackend
            group: enterpriseagentgateway.solo.io
          path: ${TOKEN_PATH}
          clientAuth:
${AUTH_BLOCK}
        resourceAuthorizationServer:   # leg 2: our AS turns the ID-JAG into an access token
          backendRef:
            name: evidence-resource-as
            kind: EnterpriseAgentgatewayBackend
            group: enterpriseagentgateway.solo.io
          path: /token
          clientAuth:
            clientId: "${RESOURCE_CLIENT_ID}"
            method: ClientSecretBasic
            secretRef:
              name: evidence-resource-client
              key: client_secret
        # The ID-JAG's aud. MUST equal the resource AS issuer AND Okta's registered Issuer URL.
        audience: "${RESOURCE_AS_ISSUER}"
        scopes:
${ITEMS}
        # resources: omitted — Okta rejects the RFC 8707 resource parameter here (invalid_target).
        subjectToken:
          source:
            # jwtAuthentication consumes the Authorization header; hand the validated raw token on.
            expression: jwt.rawToken.unredacted()
        cache:
          inMemory:
            defaultTtl: ${CACHE_TTL}
EOF
}

A_KID="${XAA_AGENT_A_KEY_KID:-${XAA_AGENT_KEY_KID:-}}"
B_KID="${XAA_AGENT_B_KEY_KID:-${XAA_AGENT_KEY_KID:-}}"

echo "==> checkpoint 1 (Okta org AS ${ISSUER}, login app ${XAA_LOGIN_CLIENT_ID}, leg-1 auth ${AGENT_AUTH})"
echo "    priorauth-agent  leg-1 client ${XAA_AGENT_A_CLIENT_ID}  scopes [${PRIORAUTH_SCOPES}]"
echo "    intake-agent     leg-1 client ${XAA_AGENT_B_CLIENT_ID}  scopes [${INTAKE_SCOPES}]"
echo "    ID-JAG aud ${RESOURCE_AS_ISSUER}"

apply_xaa agents-priorauth "$XAA_AGENT_A_CLIENT_ID" evidence-priorauth "$PRIORAUTH_SCOPES" "$A_KID"
apply_xaa probe-priorauth  "$XAA_AGENT_A_CLIENT_ID" evidence-priorauth "$PRIORAUTH_SCOPES" "$A_KID"
apply_xaa agents-intake    "$XAA_AGENT_B_CLIENT_ID" evidence-intake    "$INTAKE_SCOPES"    "$B_KID"
apply_xaa probe-intake     "$XAA_AGENT_B_CLIENT_ID" evidence-intake    "$INTAKE_SCOPES"    "$B_KID"

echo "✓ checkpoint 1 on 4 routes (edge ID-token JWT + two-leg ID-JAG exchange)"
