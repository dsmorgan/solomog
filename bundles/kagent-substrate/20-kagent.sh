#!/usr/bin/env bash
# kagent, wired to the substrate installed by 10-.
#
# Pinned to 0.10.1 rather than solomog's KAGENT_COMMUNITY_VERSION: this bundle needs the
# exact kagent whose go.mod vendors substrate 0.0.9, and 0.10.1 is also the last release
# that serves /api/substrate/status — the REST endpoint substrate-scope's high-fidelity
# mode polls. kagent 1.0.0-alpha1 removed it. See docs/findings.md.
set -euo pipefail

CTX="${CONTEXT:?CONTEXT not set — solomog sets this for bundle hooks}"

# NOT named KAGENT_VERSION. The root Taskfile declares `dotenv: ['.env', 'versions.env']`,
# so solomog's own KAGENT_VERSION — the ENTERPRISE chart line, 0.5.x — is already in this
# hook's environment, and `${KAGENT_VERSION:-0.10.1}` would silently resolve to it. The
# symptom is a 404 on a chart that does exist:
#   Error: failed to perform "FetchReference" on source:
#     ghcr.io/kagent-dev/kagent/helm/kagent-crds:0.5.6: not found
# Enterprise kagent is published elsewhere; this bundle wants the community line. Any name
# that appears in .env or versions.env is unusable as a bundle knob for the same reason.
SUBSTRATE_KAGENT_VERSION="${SUBSTRATE_KAGENT_VERSION:-0.10.1}"
SUBSTRATE_VERSION="${SUBSTRATE_VERSION:-0.0.9}"
WORKER_REPLICAS="${SUBSTRATE_WORKER_REPLICAS:-2}"

# KAGENT_PROVIDER is deliberately NOT namespaced: it is solomog's own setting (.env,
# default openAI) and means exactly the same thing here, so the bundle follows it.
PROVIDER="${KAGENT_PROVIDER:-openAI}"

case "$SUBSTRATE_KAGENT_VERSION" in
  0.[5-9].*)
    echo "✗ SUBSTRATE_KAGENT_VERSION='${SUBSTRATE_KAGENT_VERSION}' is the enterprise chart line." >&2
    echo "  This bundle needs community kagent 0.10.x. Unset it, or set it to 0.10.1." >&2
    exit 1 ;;
esac

if [ "${SOLOMOG_HELM_ANON:-true}" = "true" ]; then
  _ANON_CFG="$(mktemp -d)"
  echo '{}' > "$_ANON_CFG/config.json"
  export DOCKER_CONFIG="$_ANON_CFG"
  trap 'rm -rf "$_ANON_CFG"' EXIT
fi

echo "==> kagent ${SUBSTRATE_KAGENT_VERSION} → kagent (substrate enabled, provider ${PROVIDER})"

helm --kube-context "$CTX" upgrade --install kagent-crds \
  "oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds" \
  --version "$SUBSTRATE_KAGENT_VERSION" \
  --namespace kagent --create-namespace --wait

# ── model credential ─────────────────────────────────────────────────────────
# kagent 0.10.x takes the credential by SECRET REFERENCE only. There is no
# providers.<p>.apiKey value any more, so --set providers.anthropic.apiKey=... sets
# nothing at all and the agent fails at its first turn with an auth error. Create the
# Secret the chart's default apiKeySecretRef already points at.
kubectl --context "$CTX" create namespace kagent --dry-run=client -o yaml \
  | kubectl --context "$CTX" apply -f -

set -- \
  --set controller.substrate.enabled=true \
  --set controller.substrate.ateApiEndpoint=dns:///api.ate-system.svc:443 \
  --set controller.substrate.ateApiInsecure=true \
  --set substrateWorkerPool.create=true \
  --set "substrateWorkerPool.replicas=${WORKER_REPLICAS}" \
  --set "substrateWorkerPool.ateomImage=ghcr.io/kagent-dev/substrate/ateom-gvisor:v${SUBSTRATE_VERSION}"

case "$PROVIDER" in
  anthropic)
    kubectl --context "$CTX" create secret generic kagent-anthropic -n kagent \
      --from-literal=ANTHROPIC_API_KEY="${CLAUDE_API_KEY:?CLAUDE_API_KEY is empty in .env}" \
      --dry-run=client -o yaml | kubectl --context "$CTX" apply -f -
    set -- "$@" --set providers.default=anthropic
    ;;
  openai|openAI)
    kubectl --context "$CTX" create secret generic kagent-openai -n kagent \
      --from-literal=OPENAI_API_KEY="${OPENAI_API_KEY:?OPENAI_API_KEY is empty in .env}" \
      --dry-run=client -o yaml | kubectl --context "$CTX" apply -f -
    set -- "$@" --set providers.default=openAI
    ;;
  ollama)
    # The chart's default host, host.docker.internal:11434, is where a container on
    # Docker Desktop finds a local ollama. No secret needed.
    set -- "$@" --set providers.default=ollama
    ;;
esac

helm --kube-context "$CTX" upgrade --install kagent \
  "oci://ghcr.io/kagent-dev/kagent/helm/kagent" \
  --version "$SUBSTRATE_KAGENT_VERSION" \
  --namespace kagent --wait --timeout 10m "$@"

kubectl --context "$CTX" get pods -n kagent

# Two workers by default, not one. A SandboxAgent config or image rollout is blue-green:
# kagent keeps the previous ActorTemplate serving until the new golden is Ready, so a
# single-worker pool has nowhere to bake the replacement.
echo "    WorkerPool:"
kubectl --context "$CTX" get workerpools.ate.dev -A
