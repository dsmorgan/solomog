#!/usr/bin/env bash

NAMESPACE="agentgateway-system"
LABEL="app.kubernetes.io/name=enterprise-agentgateway"
SVC="enterprise-agentgateway"
EXPECTED_PORT="7777"

# --- Check pod phases ---
PHASES=$(kubectl --context "$CONTEXT" get pods -n "$NAMESPACE" -l "$LABEL" -o jsonpath='{.items[*].status.phase}')

if [ -z "$PHASES" ]; then
  echo "No pods found matching label $LABEL in namespace $NAMESPACE" >&2
  exit 1
fi

for PHASE in $PHASES; do
  if [ "$PHASE" != "Running" ]; then
    echo "One or more pods are not Running:" >&2
    kubectl --context "$CONTEXT" get pods -n "$NAMESPACE" -l "$LABEL" >&2
    exit 1
  fi
done

# --- Check service port ---
PORTS=$(kubectl --context "$CONTEXT" get svc -n "$NAMESPACE" "$SVC" -o jsonpath='{.spec.ports[*].port}')

if [ -z "$PORTS" ]; then
  echo "Could not retrieve ports for service $SVC in namespace $NAMESPACE" >&2
  exit 1
fi

FOUND=0
for PORT in $PORTS; do
  if [ "$PORT" = "$EXPECTED_PORT" ]; then
    FOUND=1
    break
  fi
done

if [ "$FOUND" -eq 0 ]; then
  echo "Port $EXPECTED_PORT not found on service $SVC. Found ports: $PORTS" >&2
  exit 1
fi

echo "All checks passed: pods Running, port $EXPECTED_PORT exposed."
exit 0
