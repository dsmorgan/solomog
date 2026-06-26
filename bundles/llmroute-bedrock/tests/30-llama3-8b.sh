# /bedrock/llama3-8b → bedrock-llama3-8b backend (Meta Llama 3.1 8B on Bedrock).
# Real Bedrock call (costs tokens). Refresh creds if it 401/403s:
#   solomog aws:refresh apply BUNDLE=llmroute-bedrock CLUSTER=<cluster>
curl --fail-with-body -sS "https://$HOST/bedrock/llama3-8b" \
  -H 'content-type: application/json' \
  -d '{"model":"","messages":[{"role":"user","content":"Why is ocean water more blue in tropical locations?"}]}'
