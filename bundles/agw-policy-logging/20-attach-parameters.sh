#!/usr/bin/env bash
set -euo pipefail

NS=agentgateway-system
PARAMS=policy-logging

gateway_class="$(kubectl --context "$CONTEXT" get gateway "$GATEWAY" -n "$NS" \
  -o jsonpath='{.spec.gatewayClassName}')"

case "$gateway_class" in
  *agentgateway*) ;;
  *)
    echo "Error: Gateway $NS/$GATEWAY uses class '$gateway_class', not agentgateway." >&2
    exit 1
    ;;
esac

kubectl --context "$CONTEXT" get enterpriseagentgatewayparameters "$PARAMS" \
  -n "$NS" >/dev/null

kubectl --context "$CONTEXT" patch gateway "$GATEWAY" -n "$NS" --type=merge \
  -p "{\"spec\":{\"infrastructure\":{\"parametersRef\":{\"group\":\"enterpriseagentgateway.solo.io\",\"kind\":\"EnterpriseAgentgatewayParameters\",\"name\":\"$PARAMS\"}}}}" \
  >/dev/null

echo "    attached EnterpriseAgentgatewayParameters/$PARAMS to Gateway/$GATEWAY"
