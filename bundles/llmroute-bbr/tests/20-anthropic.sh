# /bbr with model claude-haiku-4-5-20251001 → body-based-routing → anthropic backend.
# Real Anthropic call (costs tokens).
curl --fail-with-body -sS "https://$HOST/bbr" \
  -H 'content-type: application/json' \
  -d '{"model":"claude-haiku-4-5-20251001","messages":[{"role":"user","content":"Why is ocean water more blue in tropical locations?"}]}'
