# /bedrock/haiku → bedrock-haiku backend (Anthropic Claude Haiku 4.5 on Bedrock).
# Real Bedrock call (costs tokens) and needs current AWS creds — if it 401/403s, refresh:
#   solomog aws:refresh apply BUNDLE=llmroute-bedrock CLUSTER=<cluster>
# model is "" — the backend pins the model; the body just carries the prompt.
curl --fail-with-body -sS "https://$HOST/bedrock/haiku" \
  -H 'content-type: application/json' \
  -d '{"model":"","messages":[{"role":"user","content":"Why is ocean water more blue in tropical locations?"}]}'
