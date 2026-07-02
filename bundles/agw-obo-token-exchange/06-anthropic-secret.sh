# Create the anthropic-secret that the /obo/anthropic backend injects as the upstream
# credential. Copied from bundles/llmroute/01-api-keys.sh (anthropic only). The secret VALUE
# lives in .env ($CLAUDE_API_KEY) — this hook carries no secret and is safe to commit.
#
# This is also what makes the "token is not forwarded to the LLM" claim verifiable: the
# gateway strips the client's OBO token and injects THIS key upstream, so a successful real
# Anthropic call proves the OBO token never reached Anthropic (it would 401 if it had).
set -euo pipefail

[ -n "${CLAUDE_API_KEY:-}" ] || { echo "✗ CLAUDE_API_KEY is empty — set it in .env before applying this bundle" >&2; exit 1; }

kubectl --context "$CONTEXT" create secret generic anthropic-secret -n agentgateway-system \
  --from-literal="Authorization=$CLAUDE_API_KEY" \
  --dry-run=client -oyaml | kubectl --context "$CONTEXT" apply -f -
