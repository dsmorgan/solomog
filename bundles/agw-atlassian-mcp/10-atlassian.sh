# Atlassian remote-MCP elicitation backend (Jira/Confluence via mcp.atlassian.com).
#
# STATUS: INCOMPLETE — see README.md. The backend/route/policy/secret below are correct and applied
# fine, and the `mode`-omission fix (below) is in place. BUT the browser-consent step is a no-op in
# this minimal setup: Atlassian uses the elicitation secret's DISCOVERY mode (base_url + upstream
# .well-known/oauth-authorization-server + Dynamic Client Registration), and that requires the
# eager-auth OAuth issuer handler in the controller (`KGW_OAUTH_ISSUER_CONFIG`), which we have NOT
# enabled. Controller log proof when it's missing: "KGW_OAUTH_ISSUER_CONFIG is not set, OAuth issuer
# handler will not be registered". So Authorize does nothing. See README.md "How to complete".
#
# DEPENDS ON the agw-okta-mcp bundle's foundation on the same cluster: the `okta-jwks` AgentgatewayBackend
# (from agw-okta-mcp/50-okta-jwt.sh), the STS (TOKEN_EXCHANGE=true + TOKEN_EXCHANGE_API_VALIDATOR=remote),
# the proxy STS_URI (agw-okta-mcp/88-snowflake-proxy-sts.sh), and the Solo UI wired to Okta OIDC. Apply
# agw-okta-mcp first, then this bundle.
#
# Generates:
#   - atlassian-elicitation  (Secret, DISCOVERY mode — no secret values; Atlassian uses DCR)
#   - atlassian-mcp-backend  (EnterpriseAgentgatewayBackend) → mcp.atlassian.com StreamableHTTP
#   - atlassian-mcp          (HTTPRoute /atlassian/mcp)
#   - atlassian-mcp          (EnterpriseAgentgatewayPolicy) Okta edge-JWT frontend + elicitation backend
#
# .env knobs (all optional; DCR needs no creds): OKTA_DOMAIN (required, frontend issuer),
# ATLASSIAN_BASE_URL, ATLASSIAN_MCP_PATH, ATLASSIAN_SCOPES. CONTEXT/HOST exported by apply-bundle.sh.
set -euo pipefail

: "${OKTA_DOMAIN:?set OKTA_DOMAIN in .env (frontend user identity for elicitation keying)}"

BASE_URL="${ATLASSIAN_BASE_URL:-https://mcp.atlassian.com}"
# Atlassian's StreamableHTTP remote MCP endpoint. /v1/sse is deprecated (post Jun-2026); use /v1/mcp.
# If the handshake 404s, try /v1/mcp/authv2 (see ATLASSIAN-SETUP.md) via ATLASSIAN_MCP_PATH.
MCP_PATH="${ATLASSIAN_MCP_PATH:-/v1/mcp}"
SCOPES="${ATLASSIAN_SCOPES:-read:jira-work read:confluence-content.summary offline_access}"
AT_HOST="${BASE_URL#https://}"; AT_HOST="${AT_HOST#http://}"; AT_HOST="${AT_HOST%%/*}"
ROUTE_PATH="/atlassian/mcp"

echo "==> Atlassian elicitation: host=${AT_HOST} mcp=${MCP_PATH} route=${ROUTE_PATH} (discovery/DCR — no OAuth app)"
echo "    NOTE: consent will no-op until the eager-auth issuer (KGW_OAUTH_ISSUER_CONFIG) is enabled — see README.md."

# --- Elicitation secret: DISCOVERY mode (no client_id/secret/urls; gateway does DCR against base_url) ---
kubectl --context "$CONTEXT" apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: atlassian-elicitation
  namespace: agentgateway-system
type: Opaque
stringData:
  app_id: "atlassian"
  base_url: "${BASE_URL}"
  mcp_resource: "${ROUTE_PATH}"
  scopes: "${SCOPES}"
  client_name: "Atlassian"
  instructions: "Authorize agentgateway to read your Jira issues and Confluence pages on your behalf."
EOF

# --- Backend + route + policy ---
kubectl --context "$CONTEXT" apply -f - <<EOF
# Atlassian's managed remote MCP server over :443 (StreamableHTTP). policies.tls:{} → verified HTTPS
# (system CAs + auto-SNI) against Atlassian's public cert.
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayBackend
metadata:
  name: atlassian-mcp-backend
  namespace: agentgateway-system
spec:
  mcp:
    targets:
    - name: atlassian-mcp-target
      static:
        host: ${AT_HOST}
        port: 443
        protocol: StreamableHTTP
        path: ${MCP_PATH}
        policies:
          tls: {}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: atlassian-mcp
  namespace: agentgateway-system
spec:
  parentRefs:
  - name: agw
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: ${ROUTE_PATH}
      backendRefs:
      - name: atlassian-mcp-backend
        group: enterpriseagentgateway.solo.io
        kind: EnterpriseAgentgatewayBackend
---
# Frontend = Okta edge JWT (reuses the okta-jwks backend from agw-okta-mcp/50-okta-jwt.sh).
# ⚠️ To COMPLETE Atlassian (discovery/DCR consent), this frontend likely needs to become eager-auth
# (mcp.authentication + resourceMetadata.issuer-proxy + the .well-known/oauth-* discovery routes), paired
# with the controller's KGW_OAUTH_ISSUER_CONFIG. See README.md "How to complete".
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: atlassian-mcp
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: atlassian-mcp
  traffic:
    jwtAuthentication:
      mode: Strict
      providers:
        - issuer: https://${OKTA_DOMAIN}/oauth2/default
          audiences:
            - api://default
          jwks:
            remote:
              backendRef:
                name: okta-jwks
                namespace: agentgateway-system
                kind: AgentgatewayBackend
                group: agentgateway.dev
              jwksPath: /oauth2/default/v1/keys
  backend:
    tokenExchange:
      # NO \`mode\` — ElicitationOnly elicits but never injects the token (should_exchange=false in the
      # enterprise proxy/token_exchange.rs handle_request). Omitting mode → default (exchange=true,
      # elicit=true) → elicits AND injects. This fix is proven working for Snowflake in agw-okta-mcp.
      elicitation:
        clientName: "Atlassian (agentgateway PoV)"
        secretName: atlassian-elicitation
EOF

echo "✓ applied atlassian-elicitation secret + atlassian-mcp backend/route/policy"
echo "  route: https://${HOST}/atlassian/mcp  (Okta JWT required; consent needs the eager-auth issuer — see README.md)"
