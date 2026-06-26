# /bbr with model google/gemini-2.5-flash-lite → body-based-routing → vertex-ai backend.
# Real Vertex call (costs tokens) and needs a fresh GCP token — if it 401s, refresh it:
#   solomog gcp:refresh apply BUNDLE=llmroute-vertex CLUSTER=<cluster>
curl --fail-with-body -sS "https://$HOST/bbr" \
  -H 'content-type: application/json' \
  -d '{"model":"google/gemini-2.5-flash-lite","messages":[{"role":"user","content":"Why is ocean water more blue in tropical locations?"}]}'
