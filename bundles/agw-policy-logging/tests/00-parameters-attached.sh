#!/usr/bin/env bash
set -euo pipefail

NS=agentgateway-system
PARAMS=policy-logging

level="$(kubectl --context "$CONTEXT" get enterpriseagentgatewayparameters "$PARAMS" \
  -n "$NS" -o jsonpath='{.spec.logging.level}')"
format="$(kubectl --context "$CONTEXT" get enterpriseagentgatewayparameters "$PARAMS" \
  -n "$NS" -o jsonpath='{.spec.logging.format}')"
ref="$(kubectl --context "$CONTEXT" get gateway "$GATEWAY" -n "$NS" \
  -o jsonpath='{.spec.infrastructure.parametersRef.group}/{.spec.infrastructure.parametersRef.kind}/{.spec.infrastructure.parametersRef.name}')"

[ "$level" = "info" ] || { echo "expected logging level info, got '$level'"; exit 1; }
[ "$format" = "json" ] || { echo "expected logging format json, got '$format'"; exit 1; }
[ "$ref" = "enterpriseagentgateway.solo.io/EnterpriseAgentgatewayParameters/$PARAMS" ] || {
  echo "unexpected Gateway parametersRef: '$ref'"
  exit 1
}

echo "  ✓ Gateway/$GATEWAY → EnterpriseAgentgatewayParameters/$PARAMS"
echo "  ✓ persistent logging level=$level format=$format"
