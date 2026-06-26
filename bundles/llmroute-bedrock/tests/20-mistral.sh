# /bedrock/mistral → bedrock-mistral backend (Mistral Voxtral Mini on Bedrock).
# Real Bedrock call (costs tokens). Refresh creds if it 401/403s:
#   solomog aws:refresh apply BUNDLE=llmroute-bedrock CLUSTER=<cluster>
curl --fail-with-body -sS "https://$HOST/bedrock/mistral" \
  -H 'content-type: application/json' \
  -d '{"model":"","messages":[{"role":"user","content":"Why is ocean water more blue in tropical locations?"}]}'
