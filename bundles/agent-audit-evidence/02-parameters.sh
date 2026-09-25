# JSON access logs on the proxy (the default format is text), so a record can be read by jq, a SIEM
# parser, and the tests alike.
#
# CLASH: a Gateway has exactly ONE infrastructure.parametersRef, so this bundle cannot share a gateway
# with another bundle that attaches its own parameters (bundles/agw-policy-logging does). The patch
# rolls the proxy, which is why it runs first.
#
# CONTEXT and GATEWAY are exported by apply-bundle.sh.
set -euo pipefail

NS=agentgateway-system
PARAMS=evidence-logging

gateway_class="$(kubectl --context "$CONTEXT" get gateway "$GATEWAY" -n "$NS" \
  -o jsonpath='{.spec.gatewayClassName}' 2>/dev/null || true)"
case "$gateway_class" in
  *agentgateway*) ;;
  "") echo "Error: Gateway $NS/$GATEWAY not found. Create it first:  solomog expose CLUSTER=<c>" >&2; exit 1 ;;
  *)  echo "Error: Gateway $NS/$GATEWAY uses class '$gateway_class', not agentgateway." >&2; exit 1 ;;
esac

kubectl --context "$CONTEXT" apply -f - <<YAML
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayParameters
metadata:
  name: ${PARAMS}
  namespace: ${NS}
spec:
  logging:
    level: info
    format: json
YAML

existing="$(kubectl --context "$CONTEXT" get gateway "$GATEWAY" -n "$NS" \
  -o jsonpath='{.spec.infrastructure.parametersRef.name}' 2>/dev/null || true)"
if [ -n "$existing" ] && [ "$existing" != "$PARAMS" ]; then
  echo "    NOTE: replacing parametersRef '${existing}' on Gateway/${GATEWAY} — another bundle owned it."
fi

kubectl --context "$CONTEXT" patch gateway "$GATEWAY" -n "$NS" --type=merge \
  -p "{\"spec\":{\"infrastructure\":{\"parametersRef\":{\"group\":\"enterpriseagentgateway.solo.io\",\"kind\":\"EnterpriseAgentgatewayParameters\",\"name\":\"${PARAMS}\"}}}}" \
  >/dev/null

echo "✓ attached EnterpriseAgentgatewayParameters/${PARAMS} (json logs) to Gateway/${GATEWAY}"
