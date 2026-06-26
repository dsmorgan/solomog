# Materialize the AWS credential secret the bedrock backends authenticate with. The three
# values come from .env (managed by `solomog aws:refresh` — SSO temp creds, expire <=12h);
# this hook carries no secret, only the env-var references, so it's safe to commit. Keys
# (accessKey/secretKey/sessionToken) are what `policies.auth.aws.secretRef` expects.
kubectl --context "$CONTEXT" create secret generic bedrock-secret -n agentgateway-system \
  --from-literal="accessKey=$AWS_ACCESS_KEY_ID" \
  --from-literal="secretKey=$AWS_SECRET_ACCESS_KEY" \
  --from-literal="sessionToken=$AWS_SESSION_TOKEN" \
  --dry-run=client -o yaml | kubectl --context "$CONTEXT" apply -f -
