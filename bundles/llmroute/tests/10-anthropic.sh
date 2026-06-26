# /anthropic chat smoke. Copy-paste runnable: `export HOST=agw.<cluster>.test`, then run.
# `--fail-with-body` makes HTTP >=400 exit non-zero (test fails) but still prints the body.
# Uses the "claude" model alias so it stays correct if the pinned model changes.
# NOTE: calls the real Anthropic API (costs tokens) — expected for a deliberate test run.
curl --fail-with-body -sS https://$HOST/anthropic \
  -H 'content-type: application/json' \
  -d '{"model":"claude","messages":[{"role":"user","content":"Reply with the single word: ok"}]}'
