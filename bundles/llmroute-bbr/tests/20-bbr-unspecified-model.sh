# Body-based routing, fallback path: with NO model in the body, the extract policy sets
# x-gateway-model-status=unspecified, which matches the third /bbr rule → mock-openai.
# Confirms requests without a model still route. Hits the mock (no real API cost).
curl --fail-with-body -sS "https://$HOST/bbr" \
  -H 'content-type: application/json' \
  -d '{"messages":[{"role":"user","content":"Reply with: ok"}]}'
