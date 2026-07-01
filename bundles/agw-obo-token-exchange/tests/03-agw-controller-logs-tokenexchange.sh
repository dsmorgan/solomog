#!/usr/bin/env bash

NAMESPACE="agentgateway-system"
DEPLOYMENT="deploy/enterprise-agentgateway"

LOGS=$(kubectl --context "$CONTEXT" logs -n "$NAMESPACE" "$DEPLOYMENT")

PATTERN1="KGW_AGENTGATEWAY_TOKEN_EXCHANGE_CONFIG is set"
PATTERN2="starting token exchange server on"

MISSING=0

echo "$LOGS" | grep -F "$PATTERN1"
if [ $? -ne 0 ]; then
  echo "MISSING: token exchange config log line" >&2
  MISSING=1
fi

echo "$LOGS" | grep -F "$PATTERN2"
if [ $? -ne 0 ]; then
  echo "MISSING: token exchange server start log line" >&2
  MISSING=1
fi

if [ "$MISSING" -eq 1 ]; then
  exit 1
fi

exit 0
