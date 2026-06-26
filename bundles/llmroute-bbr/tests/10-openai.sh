# /bbr with model gpt-4o-mini → body-based-routing → openai-all-models backend.
# Real OpenAI call (costs tokens).
curl --fail-with-body -sS "https://$HOST/bbr" \
  -H 'content-type: application/json' \
  -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"Why is ocean water more blue in tropical locations?"}]}'
