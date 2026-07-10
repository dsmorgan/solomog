# Claim-based tier routing (bundle2's whole point). Applies:
#   - okta-jwks AgentgatewayBackend (JWKS source; same as bundle1's 50 — this cluster has no
#     agw-okta-mcp bundle, so it needs its own copy), and
#   - a PreRouting policy on the GATEWAY that validates the Okta JWT and, BEFORE route
#     selection, derives an `x-llm-tier` request header from the caller's `groups` claim, and
#   - a rate-limit policy on the premium HTTPRoute.
#
# WHY this shape (vs bundle1's per-path routes): `traffic.phase: PreRouting` runs the
# transformation before Gateway API picks a route, so the two /bedrock HTTPRoutes (20-) can
# match on the derived header. The user hits ONE path and gets the best tier their token
# entitles them to — no need to know or choose a tier. Proven pattern: workshop lab
# security/jwt-auth-with-rbac.md ("Claims Based Routing using JWT Auth and Transformations").
#
# Tier precedence (CEL ternary): premium if in llm-premium, else standard if in llm-standard,
# else "none" -> matches no route -> 404 (that 404 IS the "deny if neither"; no fallback route).
#
# ⚠️ BUILT, NOT YET RUN — to be validated e2e on a fresh cluster. Unknowns to confirm:
#   1. transformation.request.set `value` accepts a CEL ternary + has()/`in` over jwt.groups
#      (workshop only shows simple `jwt['team']` and default(json(...)) values).
#   2. PreRouting on a Gateway-targeted policy fires before route match on THIS CalVer build.
#   3. Each backend forces its own model (10/11 pin the model), so the served model reflects
#      the tier regardless of the client's requested model — 20-tier-routing.sh checks this.
#
# .env knobs (reused from the existing Okta setup — see OKTA-SETUP.md):
#   OKTA_DOMAIN     required   Okta org host, NO scheme (e.g. dev-1234567.okta.com)
#   OKTA_AUDIENCE   optional   expected `aud` claim (default: api://default)
# CONTEXT / GATEWAY are exported by apply-bundle.sh.
set -euo pipefail

: "${OKTA_DOMAIN:?set OKTA_DOMAIN in .env — your Okta org host with no https:// (e.g. dev-1234567.okta.com)}"
OKTA_AUDIENCE="${OKTA_AUDIENCE:-api://default}"
GATEWAY="${GATEWAY:-agw}"
ISSUER="https://${OKTA_DOMAIN}/oauth2/default"
JWKS_PATH="/oauth2/default/v1/keys"

echo "==> Claim-based tier routing on gateway '${GATEWAY}': issuer=${ISSUER} aud=${OKTA_AUDIENCE}"

kubectl --context "$CONTEXT" apply -f - <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: okta-jwks
  namespace: agentgateway-system
spec:
  static:
    host: ${OKTA_DOMAIN}
    port: 443
  policies:
    tls: {}
---
# PreRouting: validate the Okta JWT, then map groups -> x-llm-tier BEFORE route selection.
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: bedrock-tier-routing
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: ${GATEWAY}
  traffic:
    phase: PreRouting
    jwtAuthentication:
      mode: Strict
      providers:
        - issuer: ${ISSUER}
          audiences:
            - ${OKTA_AUDIENCE}
          jwks:
            remote:
              backendRef:
                name: okta-jwks
                namespace: agentgateway-system
                kind: AgentgatewayBackend
                group: agentgateway.dev
              jwksPath: ${JWKS_PATH}
              cacheDuration: 5m
    transformation:
      request:
        set:
          - name: x-llm-tier
            value: "(has(jwt.groups) && 'llm-premium' in jwt.groups) ? 'premium' : ((has(jwt.groups) && 'llm-standard' in jwt.groups) ? 'standard' : 'none')"
---
# Premium tier token budget — DELIBERATELY SMALL (1,000 tokens/min) so the rate limit is
# demonstrable/testable: a ~1k-token request trips it in 1-2 calls (tests/40-ratelimit-premium.sh)
# while a single normal request stays under. Real deployments would set this far higher (the
# workshop used 100k). Targets the premium route.
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: bedrock-premium-ratelimit
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: bedrock-premium
  traffic:
    rateLimit:
      local:
        - tokens: 1000
          unit: Minutes
          burst: 1000
EOF

echo "✓ applied okta-jwks + PreRouting tier-routing policy + premium rate-limit"
