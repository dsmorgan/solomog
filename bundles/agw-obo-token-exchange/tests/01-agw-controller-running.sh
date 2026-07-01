#!/usr/bin/env bash

NAMESPACE="agentgateway-system"
LABEL="app.kubernetes.io/name=enterprise-agentgateway"

# Get all phases for matching pods, one per line
PHASES=$(kubectl --context "$CONTEXT" get pods -n "$NAMESPACE" -l "$LABEL" -o jsonpath='{.items[*].status.phase}')

if [ -z "$PHASES" ]; then
  echo "No pods found matching label $LABEL in namespace $NAMESPACE" >&2
  exit 1
fi

FAILED=0
for PHASE in $PHASES; do
  if [ "$PHASE" != "Running" ]; then
    FAILED=1
  fi
done

if [ "$FAILED" -eq 1 ]; then
  echo "One or more pods are not Running:" >&2
  kubectl get pods -n "$NAMESPACE" -l "$LABEL" >&2
  exit 1
fi

exit 0
