#!/usr/bin/env bash
# Config-level check: did the tokenExchange block actually reach the Helm release?
# Complements 01-03 (which only observe runtime symptoms of an already-correct config) —
# this catches TOKEN_EXCHANGE not being read, a wrong .Environment.Name gate, or a gotmpl
# mistake that silently drops the block, none of which the runtime tests can see.
RELEASE=agentgateway
NAMESPACE=agentgateway-system

VALUES_JSON="$(helm get values "$RELEASE" -n "$NAMESPACE" --kube-context "$CONTEXT" -o json 2>&1)" \
  || { echo "✗ could not read Helm values for $RELEASE in $NAMESPACE:" >&2; echo "$VALUES_JSON" >&2; exit 1; }

fail=0
check() {  # check <label> <jq filter> <expected>
  local label="$1" filter="$2" expected="$3" got
  got="$(printf '%s' "$VALUES_JSON" | jq -r "$filter" 2>/dev/null)"
  if [ "$got" = "$expected" ]; then
    echo "  ✓ $label = $got"
  else
    echo "  ✗ $label = ${got:-<empty>}  (expected $expected)"
    fail=1
  fi
}

echo "  tokenExchange values on Helm release $RELEASE:"
check "tokenExchange.enabled"                     ".tokenExchange.enabled"                      "true"
check "tokenExchange.issuer"                       ".tokenExchange.issuer"                       "enterprise-agentgateway.agentgateway-system.svc.cluster.local:7777"
check "tokenExchange.actorValidator.validatorType" ".tokenExchange.actorValidator.validatorType" "k8s"

jwks_url="$(printf '%s' "$VALUES_JSON" | jq -r '.tokenExchange.subjectValidator.remoteConfig.url // empty')"
if [ -n "$jwks_url" ]; then
  echo "  ✓ tokenExchange.subjectValidator.remoteConfig.url = $jwks_url"
else
  echo "  ✗ tokenExchange.subjectValidator.remoteConfig.url is empty"
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "✗ tokenExchange is not correctly configured on the Helm release" >&2
  exit 1
fi
echo "✓ Helm release $RELEASE has tokenExchange correctly configured"
