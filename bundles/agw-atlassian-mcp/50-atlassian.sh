# Phase 2: Atlassian (Jira/Confluence) remote-MCP elicitation. Frontend is a PLAIN Strict Okta JWT
# policy (reuses the okta-jwks backend from 40-eager-auth.sh) — NOT eager-auth's
# backend.mcp.authentication. Backend is backend.tokenExchange.elicitation against a
# DISCOVERY-mode secret (DCR against Atlassian). This exactly matches Solo's own VALIDATED
# reference (agentgateway-enterprise/dev-docs/tokenexchange/elicitation/test-elicitation-guide-mcp.md
# — "Status: VALIDATED", GitHub as the remote MCP backend) and the already-working Snowflake shape
# in agw-okta-mcp/90-snowflake.sh — same policy pattern, just a discovery-mode secret instead of
# explicit-mode.
#
# ⚠️ CORRECTED (2026-07-08): an earlier version of this file used backend.mcp.authentication
# (eager-auth) as the frontend, combined with backend.tokenExchange.elicitation on the same policy.
# That combination isn't demonstrated anywhere in Solo's reference material — the eager-auth lab
# (mcp-eager-auth-okta.md) only covers login, no backend elicitation; the validated elicitation doc
# above only covers elicitation, with a plain JWT frontend. Symptom of the wrong combination: every
# attempt got a real, successful Atlassian consent (token minted, has_access_token:true in the
# controller logs), but the immediately-following STS token-serve check reused a DIFFERENT, stale
# DCR client id, 400ing every time — even across a clean controller restart. Once eager-auth's
# `backend.mcp.authentication` is on a resource, the controller's separate "dual OAuth agent flow"
# machinery (ent-controller/internal/issuer/flow_select.go's mcpAuthResources index) takes over the
# ENTIRE flow, including its own DCR-caching path (flow_upstream.go resolveUpstreamClientID) — a
# DIFFERENT, apparently less battle-tested code path than the one the validated doc exercises (the
# secret/configLookup-driven `LookupMCPResource` path, mediated by a human approving ONE pending
# elicitation at a time in the Solo UI, not by a raw MCP client retrying automatically). This file
# now avoids `backend.mcp.authentication` entirely, matching the validated architecture.
#
# Consequence: this route gives NO OAuth-discovery hints (no resourceMetadata, no issuer-proxy), so
# an MCP client that auto-discovers OAuth (MCP Inspector, Claude Code's `claude mcp add`) cannot log
# in against it automatically. Per the validated doc itself, testing is CURL (or MCP Inspector with
# a MANUALLY-pasted `Authorization: Bearer` header) using an Okta token obtained out-of-band — reuse
# `../agw-okta-mcp/helpers/okta-pkce-login.sh`, exactly as agw-okta-mcp's OBO/Snowflake tests already
# do. See ATLASSIAN-SETUP.md.
#
# `OAUTH_ISSUER=true` at the CONTROLLER level is STILL required — discovery/DCR elicitation depends
# on the controller's issuer infra (KGW_OAUTH_ISSUER_CONFIG) regardless of which frontend policy
# type a given route uses. Without it: "KGW_OAUTH_ISSUER_CONFIG is not set, OAuth issuer handler
# will not be registered" and DCR against Atlassian can't build a consent URL.
#
# Two DIFFERENT elicitations are in play — don't confuse them:
#   - `elicitation-secret` (40-eager-auth.sh, fixed name) = the ISSUER's own broker credential to
#     Okta, used only by Phase 1's eager-auth login. Unrelated to this file.
#   - `atlassian-elicitation` (this file) = a PER-BACKEND discovery/DCR secret so the gateway can
#     elicit a per-user ATLASSIAN token and replay it upstream. Atlassian's remote MCP uses Dynamic
#     Client Registration (RFC 7591), so there are no client id/secret to configure — the gateway
#     registers itself dynamically against `base_url`'s discovery document.
#
# Per the validated doc: elicitation approval is mediated by the **Solo UI** (`/age/elicitations`),
# not a browser redirect the MCP client follows itself — bring up `agentgateway:ui` for this.
#
# .env knobs: OKTA_DOMAIN (required), OKTA_AUDIENCE (default api://default). ATLASSIAN_BASE_URL/
# MCP_PATH/SCOPES all optional (see .env.example / ATLASSIAN-SETUP.md). CONTEXT/HOST exported by
# apply-bundle.sh.
set -euo pipefail

: "${OKTA_DOMAIN:?set OKTA_DOMAIN in .env — Okta org host, no scheme}"
OKTA_AUDIENCE="${OKTA_AUDIENCE:-api://default}"
ISSUER="https://${OKTA_DOMAIN}/oauth2/default"
JWKS_PATH="/oauth2/default/v1/keys"

BASE_URL="${ATLASSIAN_BASE_URL:-https://mcp.atlassian.com}"
# /v1/sse is deprecated (post Jun-2026); use /v1/mcp. If the handshake 404s, try /v1/mcp/authv2
# (ATLASSIAN_MCP_PATH) — Atlassian docs reference both forms.
MCP_PATH="${ATLASSIAN_MCP_PATH:-/v1/mcp}"
SCOPES="${ATLASSIAN_SCOPES:-read:jira-work read:confluence-content.summary offline_access}"
AT_HOST="${BASE_URL#https://}"; AT_HOST="${AT_HOST#http://}"; AT_HOST="${AT_HOST%%/*}"
ROUTE_PATH="/atlassian/mcp"

echo "==> Atlassian elicitation MCP: upstream=${AT_HOST}${MCP_PATH}  route=${HOST}${ROUTE_PATH}"

# --- Per-backend discovery elicitation secret (no client creds — DCR against base_url) ---
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

# --- Backend + route (no .well-known/CORS needed — no OAuth discovery served on this route) ---
kubectl --context "$CONTEXT" apply -f - <<EOF
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
EOF

# --- Policy: plain Strict Okta JWT frontend (reuses okta-jwks from 40-eager-auth.sh) + discovery
#     elicitation backend (per-user Atlassian token, mode OMITTED = elicit + inject) ---
kubectl --context "$CONTEXT" apply -f - <<EOF
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
  backend:
    tokenExchange:
      # NO \`mode\` — omitting it = default = elicit AND inject (see agw-okta-mcp/ELICITATION-MODE-NOTES.md).
      elicitation:
        clientName: "Atlassian (agentgateway PoV)"
        secretName: atlassian-elicitation
EOF

echo "✓ applied atlassian-elicitation secret + atlassian-mcp backend/route/policy"
echo "  route: https://${HOST}${ROUTE_PATH}  (Okta JWT required; first call elicits Atlassian OAuth consent via the Solo UI)"
