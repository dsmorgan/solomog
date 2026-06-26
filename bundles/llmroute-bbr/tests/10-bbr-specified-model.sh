# Body-based routing: the model in the request body is extracted to the
# x-gateway-model-name header (extract policy), and /bbr routes on it. A "gpt-4o-mini"
# model body matches the first rule → mock-openai backend. Hits the mock (no real API cost).
# Requires: this bundle applied + the mock backend (solomog apps:mock-openai CLUSTER=…).
curl --fail-with-body -sS "https://$HOST/bbr" \
  -H 'content-type: application/json' \
  -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"Reply with: ok"}]}'
