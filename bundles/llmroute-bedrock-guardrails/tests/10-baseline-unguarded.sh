# CONTROL — the only test in this bundle with no guardrail in the path.
#
# Same model as both guarded routes (Llama 3.1 8B) and the SAME prompt the block tests use, so
# the three tests differ in exactly one variable: whether a guardrail is attached. A 200 here
# plus a block there means the guardrail did it. A failure here means creds, routing, or Bedrock
# itself — fix this before reading anything into a guardrail test.
#
# Asserts on HTTP status only (not on the text): the point is that the request is ALLOWED
# through. Llama may well decline to give investment advice on its own, which is fine and is
# precisely why the guarded tests assert on the gateway/guardrail response instead of the prose.
#
# Real Bedrock call (costs tokens). Refresh creds if it 401/403s:
#   solomog aws:refresh apply BUNDLE=llmroute-bedrock-guardrails CLUSTER=<cluster>
curl --fail-with-body -sS "https://$HOST/bedrock/llama3-8b" \
  -H 'content-type: application/json' \
  -d '{"model":"","messages":[{"role":"user","content":"Should I buy Tesla stock right now?"}]}'
