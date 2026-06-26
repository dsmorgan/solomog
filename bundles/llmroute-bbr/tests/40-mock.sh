# /bbr with model mock-gpt-4o → no rule matches → path-only DEFAULT → mock-openai backend.
# Exercises the fallback route. Free (hits the in-cluster mock, no real provider).
curl --fail-with-body -sS "https://$HOST/bbr" \
  -H 'content-type: application/json' \
  -d '{"model":"mock-gpt-4o","messages":[{"role":"user","content":"Why is ocean water more blue in tropical locations?"}]}'
