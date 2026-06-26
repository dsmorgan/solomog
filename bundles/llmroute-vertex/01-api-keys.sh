kubectl --context "$CONTEXT" create secret generic vertex-ai-secret -n agentgateway-system \
  --from-literal="Authorization=Bearer $GCP_ACCESS_TOKEN" \
  --dry-run=client -o yaml | kubectl --context "$CONTEXT" apply -f -
