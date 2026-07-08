# Eager-auth frontend for the /mcp route: the MCP client authenticates via the gateway's OAuth
# issuer (which brokers to Okta); Okta-issued JWTs are validated at the backend against Okta JWKS.
# Workshop labs/mcp/mcp-eager-auth-okta.md Steps 7 (okta-jwks + elicitation-secret) + 8 (mcp auth policy).
#
# A hook (not static YAML) because it's specific to YOUR Okta org (from .env). Applies:
#   - okta-jwks         (AgentgatewayBackend)          Okta JWKS source over TLS (public keys only)
#   - elicitation-secret (Secret, fixed name)          REQUIRED by the eager-auth issuer to START a
#                                                      flow; EXPLICIT mode → Okta authorize/token
#   - mcp-okta-eager    (EnterpriseAgentgatewayPolicy) backend.mcp.authentication + resourceMetadata
#                                                      issuer-proxy (serves the gateway's OWN AS metadata)
#
# Prereqs (product-level, run before this bundle — see README):
#   solomog agentgateway CLUSTER=<c> TOKEN_EXCHANGE=true OAUTH_ISSUER=true
#   (that sets KGW_OAUTH_ISSUER_CONFIG + the STS validators + TOKEN_EXCHANGE_JWKS_URL→Okta JWKS)
#
# .env knobs: OKTA_DOMAIN (required); the eager-auth client = OAUTH_ISSUER_CLIENT_ID/SECRET, which
# must be a CONFIDENTIAL Authorization Code app with the two /oauth-issuer/callback/{downstream,
# upstream} redirect URIs (NOT the API-Services/client-credentials OKTA_CLIENT_ID app used by the
# agw-okta-mcp tests). Falls back to OKTA_CLIENT_ID/SECRET only for the simple single-app case.
# OKTA_AUTH_SERVER_ID (default "default"), OKTA_AUDIENCE (default api://default). CONTEXT/HOST by apply-bundle.sh.
set -euo pipefail

: "${OKTA_DOMAIN:?set OKTA_DOMAIN in .env — Okta org host, no scheme (e.g. dev-1234567.okta.com)}"
CID="${OAUTH_ISSUER_CLIENT_ID:-${OKTA_CLIENT_ID:-}}"
CSEC="${OAUTH_ISSUER_CLIENT_SECRET:-${OKTA_CLIENT_SECRET:-}}"
: "${CID:?set OAUTH_ISSUER_CLIENT_ID (or OKTA_CLIENT_ID) — the confidential eager-auth Okta client}"
: "${CSEC:?set OAUTH_ISSUER_CLIENT_SECRET (or OKTA_CLIENT_SECRET) — its client secret}"
AS_ID="${OKTA_AUTH_SERVER_ID:-default}"
OKTA_AUDIENCE="${OKTA_AUDIENCE:-api://default}"
ISSUER="https://${OKTA_DOMAIN}/oauth2/${AS_ID}"      # NO trailing slash (matches Okta's iss claim)
JWKS_PATH="oauth2/${AS_ID}/v1/keys"                  # NO leading slash — controller joins with "/"; a
                                                     # leading slash yields https://host//oauth2/... (404)
ISSUER_PROXY="http://enterprise-agentgateway.agentgateway-system.svc.cluster.local:7777/oauth-issuer"

echo "==> eager-auth for route 'mcp': issuer=${ISSUER}  aud=${OKTA_AUDIENCE}  host=${HOST}"

# --- okta-jwks backend + issuer elicitation-secret ---
kubectl --context "$CONTEXT" apply -f - <<EOF
# Okta JWKS source over :443. policies.tls:{} → verified HTTPS (system CAs + auto-SNI). Public keys
# only; no secrets. Same shape as agw-okta-mcp/50-okta-jwt.sh (this bundle brings its own — standalone).
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
# The eager-auth issuer looks for this EXACT name in its own namespace at the start of an auth flow
# and 500s with "secret not found: agentgateway-system/elicitation-secret" if it's missing. EXPLICIT
# mode (authorize_url/access_token_url + client creds) → the downstream Okta the issuer brokers to.
apiVersion: v1
kind: Secret
type: Opaque
metadata:
  name: elicitation-secret
  namespace: agentgateway-system
stringData:
  app_id: "okta"
  authorize_url: "${ISSUER}/v1/authorize"
  access_token_url: "${ISSUER}/v1/token"
  client_id: "${CID}"
  client_secret: "${CSEC}"
  mcp_resource: "/mcp"
  scopes: "openid profile email"
EOF

# --- eager-auth MCP policy on mcp-backend ---
kubectl --context "$CONTEXT" apply -f - <<EOF
# Ties it together: validate Okta JWTs at the MCP backend, and serve the gateway's OWN AS metadata
# (issuer-proxy) so MCP clients discover the gateway as their OAuth provider (not Okta directly).
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: mcp-okta-eager
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: enterpriseagentgateway.solo.io
      kind: EnterpriseAgentgatewayBackend
      name: mcp-backend
  backend:
    mcp:
      authentication:
        mode: Strict
        issuer: ${ISSUER}
        audiences:
          - ${OKTA_AUDIENCE}
        jwks:
          backendRef:
            name: okta-jwks
            kind: AgentgatewayBackend
            group: agentgateway.dev
          jwksPath: ${JWKS_PATH}
        resourceMetadata:
          agentgateway.dev/issuer-proxy: ${ISSUER_PROXY}
          authorizationServers:
            - https://${HOST}/mcp
          resource: https://${HOST}/mcp
EOF

echo "✓ applied okta-jwks + elicitation-secret + mcp-okta-eager policy"
echo "  Point an MCP client at https://${HOST}/mcp — it should discover the gateway as its OAuth AS,"
echo "  DCR against /oauth-issuer/register, then redirect to Okta (${OKTA_DOMAIN}) to log in."
