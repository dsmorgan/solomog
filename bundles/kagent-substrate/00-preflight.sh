#!/usr/bin/env bash
# Preflight: refuse to install substrate onto a cluster that cannot run it.
#
# Every check here maps to a failure that otherwise surfaces minutes later as something
# that reads like a product bug. The feature-gate one is the worst of them: a missing gate
# does not error, it SILENTLY DROPS the projected volume source, and the first symptom is
# postgres dying on a certificate file that was never written.
set -euo pipefail

CTX="${CONTEXT:?CONTEXT not set — solomog sets this for bundle hooks}"
FAIL=0

say()  { printf '    %s\n' "$*"; }
bad()  { printf '    ✗ %s\n' "$*"; FAIL=1; }
good() { printf '    ✓ %s\n' "$*"; }

echo "==> preflight: can this cluster run Agent Substrate?"

# Wait for the cluster before asserting anything about it. When you chain creation and apply
# in one line — solomog vind:create … apply BUNDLE=… — the checks below can start while the
# node is still joining, and a point-in-time check then reports a healthy cluster as broken.
# Run as two separate commands, the gap hides the race; chained, it does not.
READY_WAIT="${PREFLIGHT_READY_WAIT:-120}"
_waited=0
while [ "$_waited" -lt "$READY_WAIT" ]; do
  NODES_READY="$(kubectl --context "$CTX" get nodes --no-headers 2>/dev/null | grep -c ' Ready ' || true)"
  [ "${NODES_READY:-0}" -ge 1 ] && break
  [ "$_waited" -eq 0 ] && printf '    waiting for a Ready node'
  printf '.'
  sleep 5
  _waited=$((_waited + 5))
done
if [ "$_waited" -gt 0 ]; then echo; fi

# ── 1. Kubernetes version ────────────────────────────────────────────────────
# PodCertificateRequest is not a recognised gate before 1.36: kubeadm silently drops it
# and the apiserver comes up without it.
SERVER_VER="$(kubectl --context "$CTX" version -o json 2>/dev/null \
  | sed -n 's/.*"gitVersion": *"v\([0-9]*\.[0-9]*\)[^"]*".*/\1/p' | tail -1)"
case "$SERVER_VER" in
  1.3[6-9]|1.[4-9]*|[2-9].*) good "kubernetes v${SERVER_VER}" ;;
  "")   bad "could not read the server version from context '$CTX'" ;;
  *)    bad "kubernetes v${SERVER_VER} — substrate needs 1.36+" ;;
esac

# ── 2. Feature gates, observed rather than asserted ──────────────────────────
# NOT `kubectl api-resources`: that reads the discovery cache under ~/.kube/cache, and a
# rebuilt cluster reusing the same host:port answers from the PREVIOUS cluster's document
# for minutes. `get --raw` goes to the apiserver every time.
RAW="$(kubectl --context "$CTX" get --raw /apis/certificates.k8s.io/v1beta1 2>/dev/null || true)"
if grep -q podcertificaterequests <<<"$RAW"; then
  good "certificates.k8s.io/v1beta1 serves podcertificaterequests"
else
  bad "no PodCertificateRequest API — the feature gates did not apply"
  say "  substrate mounts projected podcert volumes; without the gates the sources are"
  say "  silently dropped and postgres dies on a missing server certificate."
  say "  Recreate it with: solomog vind:create CLUSTER=<name> \\"
  say "    VCLUSTER_VALUES=bundles/kagent-substrate/helpers/vcluster-substrate.yaml"
fi

if kubectl --context "$CTX" get clustertrustbundles >/dev/null 2>&1; then
  good "ClusterTrustBundle resources are servable"
else
  bad "ClusterTrustBundle not served — gate ClusterTrustBundle=true is missing"
fi

# ── 3. Service-account issuer ────────────────────────────────────────────────
# substrate 0.0.9 runs in jwt auth mode and validates SA tokens against a configured
# issuer. Its default matches kubeadm-style clusters; a managed cluster needs an override,
# and the failure mode is ate-api-server rejecting every atelet.
WANT_ISSUER="https://kubernetes.default.svc.cluster.local"
OIDC="$(kubectl --context "$CTX" get --raw /.well-known/openid-configuration 2>/dev/null || true)"
GOT_ISSUER="$(printf '%s' "$OIDC" | sed -n 's/.*"issuer": *"\([^"]*\)".*/\1/p')"
if [ -z "$GOT_ISSUER" ]; then
  say "? could not read the SA issuer — continuing, substrate will use its default"
elif [ "$GOT_ISSUER" = "$WANT_ISSUER" ]; then
  good "service-account issuer is the kubeadm default"
else
  bad "service-account issuer is '$GOT_ISSUER', not '$WANT_ISSUER'"
  say "  export SUBSTRATE_SA_ISSUER='$GOT_ISSUER' and re-apply; 10-substrate.sh passes it through."
fi

# The issuer being right is NOT enough, and this is the check that earns its keep. ate-api-server
# validates bearer tokens by fetching the issuer's discovery document and then its jwks_uri. When
# --service-account-jwks-uri is unset, Kubernetes derives that URI from the apiserver's advertise
# address — 127.0.0.1:6443 on a vcluster standalone control plane, which inside a pod is that pod's
# own loopback. Everything looks healthy until an ActorTemplate silently never gets a golden
# snapshot, minutes later, with the real error buried in ate-controller.
JWKS_URI="$(printf '%s' "$OIDC" | sed -n 's/.*"jwks_uri": *"\([^"]*\)".*/\1/p')"
case "$JWKS_URI" in
  "")
    say "? could not read jwks_uri — continuing" ;;
  https://127.0.0.1*|https://localhost*|http://127.0.0.1*|http://localhost*)
    bad "jwks_uri is '$JWKS_URI' — a loopback address no pod can reach"
    say "  substrate will accept the install and then fail every token validation:"
    say "    invalid bearer token: while discovering keys from issuer: connection refused"
    say "  Recreate with: solomog vind:create CLUSTER=<name> \\"
    say "    VCLUSTER_VALUES=bundles/kagent-substrate/helpers/vcluster-substrate.yaml" ;;
  *)
    good "jwks_uri is pod-reachable ($JWKS_URI)" ;;
esac

# ── 4. A schedulable Linux node ──────────────────────────────────────────────
NODE_COUNT="$(kubectl --context "$CTX" get nodes --no-headers 2>/dev/null | grep -c ' Ready ' || true)"
if [ "${NODE_COUNT:-0}" -ge 1 ]; then
  good "${NODE_COUNT} Ready node(s)"
else
  bad "no Ready nodes after ${READY_WAIT}s"
  say "  kubectl --context $CTX get nodes"
fi

# ── 5. A model credential, or a deliberate ollama run ────────────────────────
# KAGENT_PROVIDER is solomog's own setting (.env, default openAI). The bundle follows it
# rather than inventing its own default, so the provider you configured for `solomog kagent`
# is the one the SandboxAgents use.
PROVIDER="${KAGENT_PROVIDER:-openAI}"
case "$PROVIDER" in
  anthropic)
    if [ -n "${CLAUDE_API_KEY:-}" ]; then
      good "provider anthropic (CLAUDE_API_KEY present)"
    else
      bad "provider anthropic but CLAUDE_API_KEY is empty in .env"
      say "  set it, or run with: export KAGENT_PROVIDER=ollama"
    fi ;;
  openai|openAI)
    if [ -n "${OPENAI_API_KEY:-}" ]; then
      good "provider openAI (OPENAI_API_KEY present)"
    else
      bad "provider openAI but OPENAI_API_KEY is empty in .env"
    fi ;;
  ollama)
    good "provider ollama (no key needed; must be reachable at host.docker.internal:11434)" ;;
  *)
    bad "KAGENT_PROVIDER='$PROVIDER' — use anthropic, openAI or ollama" ;;
esac

if [ "$FAIL" -ne 0 ]; then
  echo
  echo "    preflight failed — nothing was installed."
  exit 1
fi
echo "    preflight passed"
