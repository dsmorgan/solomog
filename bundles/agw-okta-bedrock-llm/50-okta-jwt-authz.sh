# Render + apply, for BOTH tiers:
#   - a shared okta-jwks AgentgatewayBackend (same shape as agw-okta-mcp/50-okta-jwt.sh —
#     this cluster doesn't have that bundle applied, so it needs its own copy), and
#   - one EnterpriseAgentgatewayPolicy per tier, combining jwtAuthentication + CEL
#     authorization (Okta `groups` claim) + (premium only) token-bucket rateLimit.
#
# CRD field shapes below were confirmed live against THIS cluster's CRD (agentgateway
# 2026.6.3): `kubectl explain enterpriseagentgatewaypolicy.spec.traffic.authorization
# --recursive` and `...spec.traffic.rateLimit --recursive`. Notably:
#   - authorization is NOT a `rules: []` list like the gist — it's a single
#     `action` (Allow/Deny/Require) + `policy.matchExpressions: [string]` (CEL).
#   - rateLimit.local[] has a native `tokens` field (alongside `requests`), so an
#     LLM-token budget is expressed directly, no `requests`-as-a-proxy hack needed.
#
# ⚠️ UNVERIFIED: whether `action: Allow` fails CLOSED (default-deny; matchExpressions is
# the whitelist) or something else — the field has no schema description. Lab 4's tests
# must confirm a wrong-tier token is actually rejected on each route before trusting this.
# If it turns out not to gate as expected, swap to `action: Require` and retest.
#
# .env knobs (reused from the existing Okta setup — see agw-okta-mcp/.env / OKTA-SETUP.md):
#   OKTA_DOMAIN     required   Okta org host, NO scheme (e.g. dev-1234567.okta.com)
#   OKTA_AUDIENCE   optional   expected `aud` claim (default: api://default)
# CONTEXT is exported by apply-bundle.sh (target cluster kube context).
set -euo pipefail

: "${OKTA_DOMAIN:?set OKTA_DOMAIN in .env — your Okta org host with no https:// (e.g. dev-1234567.okta.com)}"
OKTA_AUDIENCE="${OKTA_AUDIENCE:-api://default}"
ISSUER="https://${OKTA_DOMAIN}/oauth2/default"
JWKS_PATH="/oauth2/default/v1/keys"

echo "==> Okta JWT + group authorization for routes 'bedrock-standard'/'bedrock-premium': issuer=${ISSUER}  aud=${OKTA_AUDIENCE}"

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
# Standard tier: valid Okta JWT + 'llm-standard' in the groups claim.
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: bedrock-standard-jwt
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: bedrock-standard
  traffic:
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
    authorization:
      action: Allow
      policy:
        matchExpressions:
          - "'llm-standard' in jwt.groups"
---
# Premium tier: valid Okta JWT + 'llm-premium' in groups, plus a 100k-tokens/min budget
# (workshop's maxTokens:100000 / tokensPerFill:100000 / fillInterval:60s, expressed
# natively via rateLimit.local[].tokens + unit: Minutes; burst == tokens gives the same
# "up to 100k per window, no carryover" shape as the workshop's token-bucket).
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: bedrock-premium-jwt
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: bedrock-premium
  traffic:
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
    authorization:
      action: Allow
      policy:
        matchExpressions:
          - "'llm-premium' in jwt.groups"
    rateLimit:
      local:
        - tokens: 100000
          unit: Minutes
          burst: 100000
EOF

echo "✓ applied okta-jwks backend + tiered JWT/authorization(/rate-limit) policies"
