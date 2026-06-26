# /vertex → Vertex AI (gemini), via the "gemini" model alias. Real API call (costs tokens).
# Requires: bundle applied + a FRESH GCP token in the secret. If it 401s, the token expired:
#     solomog gcp:refresh apply BUNDLE=llmroute-vertex CLUSTER=<cluster>
curl --fail-with-body -sS "https://$HOST/vertex" \
  -H 'content-type: application/json' \
  -d '{"model":"gemini","messages":[{"role":"user","content":"Reply with: ok"}]}'
