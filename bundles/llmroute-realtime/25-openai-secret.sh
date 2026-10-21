# Upstream credential for the REAL OpenAI route (40-openai-real.yaml). Created from .env so the
# value never lands in git. Without OPENAI_API_KEY the secret is skipped: the mock route and its
# tests still work, and test 20 self-skips. Its own name avoids clashing with the llmroute
# bundle's `openai-secret`.
if [ -z "${OPENAI_API_KEY:-}" ]; then
  echo "    OPENAI_API_KEY not set in .env: skipping openai-realtime-secret (real route tests will self-skip)"
  exit 0
fi
kubectl --context "$CONTEXT" create secret generic openai-realtime-secret -n agentgateway-system \
  --from-literal="Authorization=Bearer $OPENAI_API_KEY" \
  --dry-run=client -oyaml | kubectl --context "$CONTEXT" apply -f -
