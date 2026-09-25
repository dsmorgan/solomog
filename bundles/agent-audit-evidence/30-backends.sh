# The gateway backends, all in agentgateway-system beside the gateway.
#
#   evidence-okta-idp      Okta ORG authorization server (/oauth2/v1/*): the edge JWKS for the user's
#                          ID token AND leg 1 of Cross App Access. Not the custom /oauth2/default
#                          server — XAA lives on the org server. TLS with defaults (`tls: {}`).
#   evidence-resource-as   our in-cluster leg-2 AS: leg 2 AND the JWKS for the final token.
#   evidence-probe-echo    go-httpbin behind /probe/priorauth|intake.
#   priorauth-agent-svc / intake-agent-svc   the agent workloads behind /agents/priorauth|intake.
#                          Separate backends because each route attaches a DIFFERENT agent's Okta
#                          credential, and a static credential cannot be selected by a header.
#
# .env: OKTA_DOMAIN (required). CONTEXT exported by apply-bundle.sh.
set -euo pipefail

: "${OKTA_DOMAIN:?set OKTA_DOMAIN in .env — Okta org host, no https://}"

backend() {  # $1 name  $2 host  $3 port  $4 extra spec lines
  cat <<YAML
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayBackend
metadata:
  name: $1
  namespace: agentgateway-system
spec:
  static:
    host: $2
    port: $3
$4
YAML
}

{
  backend evidence-okta-idp "$OKTA_DOMAIN" 443 "  policies:
    tls: {}"
  backend evidence-resource-as evidence-resource-as.agent-evidence.svc.cluster.local 8080 ""
  backend evidence-probe-echo evidence-probe-echo.agent-evidence.svc.cluster.local 8080 ""
  backend priorauth-agent-svc priorauth-agent.agent-evidence.svc.cluster.local 8080 ""
  backend intake-agent-svc intake-agent.agent-evidence.svc.cluster.local 8080 ""
} | kubectl --context "$CONTEXT" apply -f -

echo "✓ applied 5 backends (Okta org AS ${OKTA_DOMAIN}, resource AS, probe echo, two agents)"
