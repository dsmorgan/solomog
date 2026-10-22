#!/usr/bin/env bash
# The objects that make an agent: a ModelConfig on the mock model, a Harness (the runtime image and
# where it runs), an AgentTemplate (prompt, model and tools) and the Agent that pairs them.
#
# The Agent becomes Ready once Substrate has built its golden snapshot, which takes minutes on a
# cold node. This hook waits only for Accepted and ResolvedRefs; tests/30 waits for Ready.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/helpers/env.sh"
CTX="${CONTEXT:?CONTEXT not set — solomog sets this for bundle hooks}"
k() { kubectl --context "$CTX" "$@"; }

echo "==> ${KAGENT_NS}: ModelConfig mock-model, Harness adk, AgentTemplate and Agent assistant"
k apply -f - >/dev/null <<EOF
apiVersion: api.kagent.dev/v1alpha3
kind: ModelConfig
metadata: {name: mock-model, namespace: ${KAGENT_NS}}
spec:
  provider: OpenAI
  model: mock
  apiKeySecret: kagent-openai
  apiKeySecretKey: OPENAI_API_KEY
  openAI:
    baseUrl: ${MODEL_URL}
---
apiVersion: api.kagent.dev/v1alpha3
kind: Harness
metadata: {name: adk, namespace: ${KAGENT_NS}}
spec:
  kagent: {}
  workload:
    image: ${KEF_ADK_IMAGE}
  substrate:
    workerPoolRef:
      name: ${POOL}
    # The in-cluster object store (rustfs) Substrate's chart deploys, bucket ate-snapshots.
    snapshotPolicy:
      location: gs://ate-snapshots/kagent/
---
apiVersion: api.kagent.dev/v1alpha3
kind: AgentTemplate
metadata: {name: assistant, namespace: ${KAGENT_NS}}
spec:
  description: A general assistant on the mock model
  modelConfig:
    name: mock-model
  systemPrompt: |
    You are a helpful assistant. Answer briefly.
---
apiVersion: api.kagent.dev/v1alpha3
kind: Agent
metadata: {name: assistant, namespace: ${KAGENT_NS}}
spec:
  template:
    ref:
      name: assistant
  harnessRef:
    name: adk
EOF

cond() { k get agent.api.kagent.dev "$1" -n "$KAGENT_NS" -o jsonpath="{.status.conditions[?(@.type=='$2')].status}" 2>/dev/null || true; }
for _ in $(seq 1 36); do
  [ "$(cond assistant Accepted)" = True ] && [ "$(cond assistant ResolvedRefs)" = True ] && break
  sleep 5
done
if [ "$(cond assistant Accepted)" != True ] || [ "$(cond assistant ResolvedRefs)" != True ]; then
  echo "    ✗ Agent assistant not accepted:" >&2
  k get agent.api.kagent.dev assistant -n "$KAGENT_NS" \
    -o jsonpath="{range .status.conditions[*]}      {.type}={.status} {.reason}: {.message}{'\n'}{end}" >&2
  exit 1
fi
echo "    ✓ Agent assistant accepted; its golden snapshot builds in the background"
