# CHECKPOINT 2: validate the composite token, then decide per tool on reviewer ∧ agent.
#
#   claims-tools-authz  → the HTTPRoute. Validates the FINAL token against our resource AS JWKS,
#                         which is what populates jwt.* for the rule below and for the audit record.
#   claims-tools-rbac   → the relay backend. Deny the sensitive tools unless BOTH:
#                           jwt.act.sub == the prior-auth agent            ← the agent key
#                           the reviewer group ∈ jwt.groups                ← the reviewer key
#
# A denied tool is filtered out of tools/list, and a forced tools/call answers HTTP 400 with JSON-RPC
# -32602 "Unknown tool", logged with reason=MCP. The agent is never told the tool exists.
#
# .env / knobs:
#   EVIDENCE_PRIORAUTH_ACTOR     default priorauth-agent (must match act.sub; see 16-resource-as-config.sh)
#   EVIDENCE_REVIEWER_GROUP      default priorauth-reviewer
#   EVIDENCE_SENSITIVE_TOOLS     comma-separated Deny targets (default approve_prior_auth)
#   EVIDENCE_RESOURCE_AS_ISSUER  issuer of the final token
#   EVIDENCE_RESOURCE_API        its audience (default https://claims.evidence.test/mcp)
# CONTEXT exported by apply-bundle.sh.
set -euo pipefail

ACTOR="${EVIDENCE_PRIORAUTH_ACTOR:-priorauth-agent}"
GROUP="${EVIDENCE_REVIEWER_GROUP:-priorauth-reviewer}"
TOOLS="${EVIDENCE_SENSITIVE_TOOLS:-approve_prior_auth}"
ISSUER="${EVIDENCE_RESOURCE_AS_ISSUER:-https://evidence-resource-as.agent-evidence.svc.cluster.local}"
API="${EVIDENCE_RESOURCE_API:-https://claims.evidence.test/mcp}"
TOOL_LIST=$(printf '%s' "$TOOLS" | awk -F, '{for(i=1;i<=NF;i++){printf "%s\"%s\"", (i>1?", ":""), $i}}')

echo "==> /claims-tools: validate final token (iss ${ISSUER}, aud ${API})"
echo "    tool policy: deny [${TOOLS}] unless jwt.act.sub == '${ACTOR}' AND '${GROUP}' in jwt.groups"

kubectl --context "$CONTEXT" apply -f - <<EOF2
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: claims-tools-authz
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: claims-tools
  traffic:
    jwtAuthentication:
      mode: Strict
      providers:
        - issuer: ${ISSUER}
          audiences:
            - ${API}
          jwks:
            remote:
              backendRef:
                name: evidence-resource-as
                namespace: agentgateway-system
                kind: EnterpriseAgentgatewayBackend
                group: enterpriseagentgateway.solo.io
              jwksPath: /jwks
              cacheDuration: 5m
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: claims-tools-rbac
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: enterpriseagentgateway.solo.io
      kind: EnterpriseAgentgatewayBackend
      name: claims-mcp-relay
  backend:
    mcp:
      authorization:
        action: Deny
        policy:
          matchExpressions:
            - 'mcp.tool.name in [${TOOL_LIST}] && !(jwt.act.sub == "${ACTOR}" && "${GROUP}" in jwt.groups)'
EOF2

echo "✓ applied claims-tools-authz + claims-tools-rbac"
