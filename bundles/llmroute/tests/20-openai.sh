# /openai chat smoke. Copy-paste runnable: `export HOST=agw.<cluster>.test`, then run.
# `--fail-with-body` makes HTTP >=400 exit non-zero (test fails) but still prints the body.
# openai backend is passthrough (no pinned model) — send a real OpenAI model id.
# NOTE: calls the real OpenAI API (costs tokens) — expected for a deliberate test run.
curl --fail-with-body -sS https://$HOST/openai \
  -H 'content-type: application/json' \
  -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"Reply with the single word: ok"}]}'
