# THE breakthrough for elicitation: the agentgateway PROXY (data plane) needs to know where the
# in-cluster STS elicitation endpoint is, or it returns "token exchange required but not configured"
# (proxy config shows tokenExchange: null). OBO worked without this because it hit the STS directly
# on :7777; elicitation is the first flow where the PROXY itself performs the exchange.
#
# Fix (from the v2026.6.1 workshop, Step 4 — confirmed working on our 2026.6.3): set STS_URI +
# STS_AUTH_TOKEN env on the proxy via an EnterpriseAgentgatewayParameters, and point the
# GatewayClass at it. The controller then regenerates the proxy deployment WITH the STS env, and
# the proxy populates its token-exchange config.
#
# NOTE (layering): this patches the CLUSTER-SCOPED GatewayClass 'enterprise-agentgateway' — fine on
# a single-purpose PoV cluster like a8, where every gateway of that class should get the STS env.
# The proper long-term home is the agentgateway helmfile (gatewayClassParametersRefs + a managed
# params CR); kept here as a bundle hook so elicitation is reproducible without a chart change.
# Idempotent: re-applying the same params/ref is a no-op (no proxy restart unless values change).
set -euo pipefail

STS_URI="http://enterprise-agentgateway.agentgateway-system.svc.cluster.local:7777/elicitations/oauth2/token"

echo "==> wiring proxy STS env (STS_URI) via EnterpriseAgentgatewayParameters + GatewayClass"
kubectl --context "$CONTEXT" apply -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayParameters
metadata:
  name: agentgateway-config
  namespace: agentgateway-system
spec:
  env:
    - name: STS_URI
      value: ${STS_URI}
    - name: STS_AUTH_TOKEN
      value: /var/run/secrets/xds-tokens/xds-token
EOF

kubectl --context "$CONTEXT" patch gatewayclass enterprise-agentgateway --type=merge -p='{"spec":{"parametersRef":{"group":"enterpriseagentgateway.solo.io","kind":"EnterpriseAgentgatewayParameters","name":"agentgateway-config","namespace":"agentgateway-system"}}}'

echo "✓ proxy STS env wired (STS_URI). The controller regenerates the proxy with the env; give it"
echo "  a few seconds to roll. Without this, elicitation returns 'token exchange required but not configured'."
