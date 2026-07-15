# Render + apply the Okta edge-JWT config for the MCP route:
#   - an AgentgatewayBackend that reaches Okta's JWKS endpoint over TLS, and
#   - an EnterpriseAgentgatewayPolicy that makes the /mcp route (40-mcp-route.yaml)
#     require a valid Okta-issued JWT.
#
# This is a hook (not a static .yaml) because the config is specific to YOUR Okta org and
# lives in .env — and only OKTA_DOMAIN really varies: the issuer, JWKS path, and audience
# all derive from Okta's custom "default" authorization server. Mirrors how the OBO bundle
# keeps its IdP config in a hook. NO SECRETS are applied here — the gateway only needs Okta's
# PUBLIC JWKS to *validate* tokens; the client id/secret are used solely by the tests to
# *fetch* a token (see tests/ + .env.example).
#
# Why the custom "default" authorization server (/oauth2/default) and not the org server:
# the default AS issues real JWT access tokens with a JWKS at /oauth2/default/v1/keys and a
# configurable `aud` (api://default) — exactly what edge JWT validation needs. The org server
# (https://<domain>/) issues tokens meant for Okta's own APIs, not for validating here.
#
# .env knobs (see .env.example):
#   OKTA_DOMAIN     required   Okta org host, NO scheme   (e.g. dev-1234567.okta.com)
#   OKTA_AUDIENCE   optional   expected `aud` claim       (default: api://default)
# CONTEXT is exported by apply-bundle.sh (target cluster kube context).
set -euo pipefail

: "${OKTA_DOMAIN:?set OKTA_DOMAIN in .env — your Okta org host with no https:// (e.g. dev-1234567.okta.com)}"
OKTA_AUDIENCE="${OKTA_AUDIENCE:-api://default}"
ISSUER="https://${OKTA_DOMAIN}/oauth2/default"
JWKS_PATH="/oauth2/default/v1/keys"

echo "==> Okta edge JWT for route 'mcp': issuer=${ISSUER}  aud=${OKTA_AUDIENCE}"

kubectl --context "$CONTEXT" apply -f - <<EOF
# JWKS source: Okta's custom "default" authorization server, over the public internet on :443.
# spec.policies.tls: {} initiates TLS to the backend, validates the server against the system
# CA bundle, and auto-sets SNI from the host — so Okta's public cert works with no cert config.
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
# Require a valid Okta JWT on the /mcp HTTPRoute. mode: Strict → missing/invalid token = 401.
# The provider checks iss + aud and verifies the signature against Okta's rotating JWKS
# (fetched via the backend above, cached 5m). This is the whole "Okta integrated with
# agentgateway" proof: a real Okta token gets in, anything else is rejected at the edge.
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: okta-mcp-jwt
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: mcp
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: mcp2
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
EOF

echo "✓ applied okta-jwks backend + okta-mcp-jwt policy — route 'mcp' and 'tools' now requires an Okta JWT"
