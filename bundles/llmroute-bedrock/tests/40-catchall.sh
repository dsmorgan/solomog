# Bare /bedrock (Exact match) → catch-all default → bedrock-mistral backend.
# Exercises the default rule. Real Bedrock call (costs tokens). Refresh creds if it 401/403s:
#   solomog aws:refresh apply BUNDLE=llmroute-bedrock CLUSTER=<cluster>
curl --fail-with-body -sS "https://$HOST/bedrock" \
  -H 'content-type: application/json' \
  -d '{"model":"","messages":[{"role":"user","content":"Why is ocean water more blue in tropical locations?"}]}'
