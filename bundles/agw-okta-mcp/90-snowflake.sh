# Snowflake elicitation backend: per-user browser OAuth consent against Snowflake, then the
# gateway replays the user's Snowflake token to the Snowflake-managed MCP server.
#
# Generates (from .env, so no secrets are committed):
#   - snowflake-elicitation  (Secret)   the Snowflake OAuth provider details the STS/UI use
#   - snowflake-mcp-backend  (EnterpriseAgentgatewayBackend)  → Snowflake managed MCP endpoint
#   - snowflake-mcp          (HTTPRoute /snowflake/mcp)
#   - snowflake-mcp          (EnterpriseAgentgatewayPolicy)   Okta JWT frontend + elicitation backend
#
# Prereqs (see SNOWFLAKE-SETUP.md): the OAuth security integration, a semantic view, and a
# CREATE MCP SERVER must already exist in Snowflake; the controller must run with
# TOKEN_EXCHANGE=true AND TOKEN_EXCHANGE_API_VALIDATOR=remote (the UI elicitation API); the
# Solo UI must be routed (its /age/elicitations is the OAuth callback).
#
# .env knobs (see .env.example): SNOWFLAKE_ACCOUNT_URL, SNOWFLAKE_OAUTH_CLIENT_ID/SECRET,
# SNOWFLAKE_OAUTH_SCOPES, SNOWFLAKE_MCP_DATABASE/SCHEMA/SERVER, OKTA_DOMAIN. CONTEXT/HOST are
# exported by apply-bundle.sh.
set -euo pipefail

: "${SNOWFLAKE_ACCOUNT_URL:?set SNOWFLAKE_ACCOUNT_URL in .env (e.g. https://dimqfms-qy56216.snowflakecomputing.com)}"
: "${SNOWFLAKE_OAUTH_CLIENT_ID:?set SNOWFLAKE_OAUTH_CLIENT_ID in .env}"
: "${SNOWFLAKE_OAUTH_CLIENT_SECRET:?set SNOWFLAKE_OAUTH_CLIENT_SECRET in .env}"
: "${OKTA_DOMAIN:?set OKTA_DOMAIN in .env (frontend user identity for elicitation keying)}"
# Snowflake OAuth CUSTOM clients require a SPECIFIC role scope `session:role:<ROLE>`. The
# `session:role-any` scope is an EXTERNAL-OAuth feature (needs OAUTH_ANY_ROLE_MODE) and Snowflake
# rejects it here with "The requested scope is invalid." Default to the role SNOWFLAKE-SETUP.md creates.
SCOPES="${SNOWFLAKE_OAUTH_SCOPES:-session:role:AGW_ANALYST refresh_token}"
DB="${SNOWFLAKE_MCP_DATABASE:-AGW_DEMO}"
SCHEMA="${SNOWFLAKE_MCP_SCHEMA:-PUBLIC}"
SERVER="${SNOWFLAKE_MCP_SERVER:-SNOWFLAKE_MCP}"

SF_HOST="${SNOWFLAKE_ACCOUNT_URL#https://}"; SF_HOST="${SF_HOST#http://}"; SF_HOST="${SF_HOST%%/*}"
MCP_PATH="/api/v2/databases/${DB}/schemas/${SCHEMA}/mcp-servers/${SERVER}"
REDIRECT_URI="https://ui.${HOST}/age/elicitations"

echo "==> Snowflake elicitation: host=${SF_HOST} mcp=${MCP_PATH}"
echo "    redirect_uri=${REDIRECT_URI}  (must match the OAUTH_REDIRECT_URI on the Snowflake integration)"

# --- Elicitation secret: the Snowflake OAuth provider config (individual stringData keys) ---
kubectl --context "$CONTEXT" apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: snowflake-elicitation
  namespace: agentgateway-system
type: Opaque
stringData:
  type: oauth
  title: "Snowflake"
  instructions: "Authorize agentgateway to query Snowflake on your behalf. Pick a non-admin role at the Snowflake consent screen."
  app_id: snowflake
  client_id: "${SNOWFLAKE_OAUTH_CLIENT_ID}"
  client_secret: "${SNOWFLAKE_OAUTH_CLIENT_SECRET}"
  authorize_url: "${SNOWFLAKE_ACCOUNT_URL%/}/oauth/authorize"
  access_token_url: "${SNOWFLAKE_ACCOUNT_URL%/}/oauth/token-request"
  scopes: "${SCOPES}"
  redirect_uri: "${REDIRECT_URI}"
EOF

# --- Backend + route + policy (no secrets here) ---
kubectl --context "$CONTEXT" apply -f - <<EOF
# The Snowflake-managed MCP server, reached over the public internet on :443 (Streamable HTTP).
# policies.tls: {} → verified HTTPS with system CAs + auto-SNI (Snowflake's public cert).
# NOTE: uses agentgateway.dev/AgentgatewayBackend (NOT EnterpriseAgentgatewayBackend) — Solo's
# elicitation + OBO token-exchange examples all attach token-exchange to this CRD, and the exchanged
# token IS injected into the upstream on this kind. Our earlier EnterpriseAgentgatewayBackend served
# the token (STS 200) but never attached Authorization:Bearer to the MCP upstream — the CRD kind is
# the prime suspect for that gap (see memory snowflake-mcp-oauth-token-type-header).
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: snowflake-mcp-backend
  namespace: agentgateway-system
spec:
  mcp:
    targets:
    - name: snowflake-mcp-target
      static:
        host: ${SF_HOST}
        port: 443
        protocol: StreamableHTTP
        path: ${MCP_PATH}
        policies:
          tls: {}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: snowflake-mcp
  namespace: agentgateway-system
spec:
  parentRefs:
  - name: agw
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /snowflake/mcp
      backendRefs:
      - name: snowflake-mcp-backend
        group: agentgateway.dev
        kind: AgentgatewayBackend
---
# Frontend: the user authenticates with their Okta JWT (identifies WHO — elicitation keys the
# Snowflake token to this identity). Backend: ElicitationOnly token exchange → browser OAuth
# consent against Snowflake, token stored per-user and replayed to the backend.
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: snowflake-mcp
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: snowflake-mcp
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
    # Snowflake REST v2 (the managed-MCP endpoint /api/v2/... lives here) requires OAuth bearer
    # tokens tagged with the token-type header, else it treats the Bearer as a keypair JWT. This
    # transformation IS confirmed reaching the MCP upstream (proxy trace shows the header on the
    # outbound request) — the value MUST be a nested-quoted CEL string literal ("'OAUTH'"), per the
    # solo-io/solo-sa-agentic snowflake-cortex example.
    # ⚠️ KNOWN BLOCKER (agentgateway 2026.6.3): ElicitationOnly token-exchange fetches the Snowflake
    # token (STS returns 200 "served elicitation token") but the proxy does NOT attach it as
    # Authorization: Bearer on the StreamableHTTP MCP upstream request — the outbound request has
    # NO authorization header (confirmed via RUST_LOG=agentgateway=trace, with AND without this
    # transformation). Snowflake then returns 401 (no token-type) / 390146 "Bearer missing" (with it).
    # Everything upstream of this works (Okta identity → elicitation → per-user token stored & served).
    # Open with Solo — see memory snowflake-mcp-oauth-token-type-header. Config below is the intended
    # final shape; leaving it in place so it's correct once the attachment gap is resolved.
    transformation:
      request:
        add:
          - name: X-Snowflake-Authorization-Token-Type
            value: "'OAUTH'"
    tokenExchange:
      # NO `mode` here — deliberately. In the enterprise source (proxy/token_exchange.rs
      # handle_request), the exchanged/elicited token is only injected into Authorization when
      # `should_exchange` is true. expand_mode(): ElicitationOnly→(exchange=FALSE, elicit=true) so it
      # ELICITS but NEVER injects the token (the "STS 200 served elicitation token but no Authorization
      # upstream" bug we chased). Omitting mode → default (exchange=true, elicit=true) → elicits AND
      # injects. NOT a bug — ElicitationOnly is documented as "elicit, don't exchange/inject"; default
      # (omit mode) = both. See ELICITATION-MODE-NOTES.md (the trap: Solo's consent-screen doc example
      # uses mode:ElicitationOnly, but the setup doc omits it — omitting is correct).
      elicitation:
        clientName: "Snowflake (agentgateway PoV)"
        secretName: snowflake-elicitation
EOF

echo "✓ applied snowflake-elicitation secret + snowflake-mcp backend/route/policy"
echo "  route: https://${HOST}/snowflake/mcp  (Okta JWT required; first call elicits Snowflake OAuth consent)"
