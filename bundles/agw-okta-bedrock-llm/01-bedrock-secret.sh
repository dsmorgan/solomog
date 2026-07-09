# Materialize the AWS credential secret the bedrock backends authenticate with. Same
# pattern as bundles/llmroute-bedrock/01-api-keys.sh (SSO temp creds via `solomog aws:refresh`,
# expire <=12h) — see that bundle's README for the one-time `aws configure sso` setup.
kubectl --context "$CONTEXT" create secret generic bedrock-secret -n agentgateway-system \
  --from-literal="accessKey=$AWS_ACCESS_KEY_ID" \
  --from-literal="secretKey=$AWS_SECRET_ACCESS_KEY" \
  --from-literal="sessionToken=$AWS_SESSION_TOKEN" \
  --dry-run=client -o yaml | kubectl --context "$CONTEXT" apply -f -
