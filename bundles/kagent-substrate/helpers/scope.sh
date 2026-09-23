#!/usr/bin/env bash
# Run substrate-scope against a cluster this bundle is installed on.
#
#   bash bundles/kagent-substrate/helpers/scope.sh kas               # the board
#   bash bundles/kagent-substrate/helpers/scope.sh kas --stimulate   # drive real traffic
#   bash bundles/kagent-substrate/helpers/scope.sh kas --sim         # no cluster needed
#
# scope is checked out into .solomog/substrate-scope (gitignored). It has no npm
# dependencies; node >= 18 is the whole requirement.
#
# The checkout is PINNED. scope is someone else's actively maintained repo, so tracking the
# tip of main means an upstream commit can change the demo between the run you rehearsed and
# the one you give. SCOPE_REF overrides the pin:
#
#   SCOPE_REF=main   bash helpers/scope.sh kas    # track upstream, to test a newer scope
#   SCOPE_REF=<sha>  bash helpers/scope.sh kas    # some other commit
#
# scope port-forwards svc/kagent-controller:8083 itself, so nothing needs forwarding here.
# It reads KUBE_CONTEXT for every kubectl call it makes — including `kubectl scale
# workerpool` from the UI's worker +/- buttons — so that variable is doing real work, not
# just selecting a read.
set -euo pipefail

CLUSTER="${1:?usage: scope.sh <cluster-name> [--stimulate|--sim] [extra args]}"
shift || true

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CHECKOUT="$REPO_DIR/.solomog/substrate-scope"
UPSTREAM="https://github.com/themsquared/substrate-scope.git"

# Pinned to the commit this bundle was exercised against: "kagent 0.10 compatibility +
# KUBE_CONTEXT pinning", 2026-09-17. That commit is also the one docs/findings.md describes
# when it lists where scope reads reply text.
SCOPE_REF="${SCOPE_REF:-5d275499e34cdf3384da81c027deb3df4170135d}"

command -v node >/dev/null || { echo "node not found — brew install node" >&2; exit 1; }
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
[ "$NODE_MAJOR" -ge 18 ] || { echo "node >= 18 required, found $(node -v)" >&2; exit 1; }

MODE=""
case "${1:-}" in
  --stimulate) MODE=stimulate; shift ;;
  --sim)       MODE=sim; shift ;;
esac

if [ ! -d "$CHECKOUT/.git" ]; then
  echo "==> Cloning substrate-scope into .solomog/substrate-scope"
  # Not --depth 1: a shallow clone cannot check out an arbitrary pinned commit. The repo is
  # a handful of files, so a full clone costs nothing.
  git clone --quiet "$UPSTREAM" "$CHECKOUT"
fi

# Refuse to clobber local edits. If you are testing a patch against scope, that work is worth
# more than this script's idea of which commit should be checked out.
if [ -n "$(git -C "$CHECKOUT" status --porcelain 2>/dev/null)" ]; then
  echo "==> substrate-scope has local changes — leaving the checkout alone"
  git -C "$CHECKOUT" status --short | sed 's/^/    /'
else
  git -C "$CHECKOUT" fetch --quiet origin 2>/dev/null || echo "    (fetch failed — using what is on disk)"
  case "$SCOPE_REF" in
    main|latest|HEAD)
      git -C "$CHECKOUT" checkout --quiet main 2>/dev/null || true
      git -C "$CHECKOUT" pull --ff-only --quiet 2>/dev/null || true
      echo "==> substrate-scope at upstream main ($(git -C "$CHECKOUT" rev-parse --short HEAD))" ;;
    *)
      if git -C "$CHECKOUT" checkout --quiet "$SCOPE_REF" 2>/dev/null; then
        echo "==> substrate-scope pinned at $(git -C "$CHECKOUT" rev-parse --short HEAD)"
      else
        echo "✗ SCOPE_REF='$SCOPE_REF' is not a commit in this checkout." >&2
        echo "  Try SCOPE_REF=main, or delete $CHECKOUT and re-run." >&2
        exit 1
      fi ;;
  esac
fi

if [ "$MODE" = "sim" ]; then
  echo "==> Simulated mode — no cluster is touched.  http://localhost:8123"
  exec node "$CHECKOUT/server.mjs" "$@"
fi

# shellcheck source=/dev/null
. "$REPO_DIR/scripts/lib/target.sh"
CTX="$(solomog_context "$CLUSTER")"
export KUBE_CONTEXT="$CTX"

kubectl --context "$CTX" get workerpools.ate.dev -A >/dev/null 2>&1 || {
  echo "✗ no ate.dev WorkerPools visible on context '$CTX'." >&2
  echo "  Apply the bundle first: solomog apply BUNDLE=kagent-substrate CLUSTER=$CLUSTER" >&2
  exit 1
}

if [ "$MODE" = "stimulate" ]; then
  # stimulate talks to the kagent controller API, which it expects already forwarded —
  # unlike server.mjs it does not forward for itself. Run the board in another terminal
  # first, or forward here.
  echo "==> Driving traffic at the SandboxAgents (Ctrl-C to stop)"
  echo "    Every chat is real: an actor restore, an LLM turn, a checkpoint."
  kubectl --context "$CTX" port-forward -n kagent svc/kagent-controller 8083:8083 >/dev/null 2>&1 &
  PF=$!
  trap 'kill $PF 2>/dev/null || true' EXIT
  sleep 3
  exec node "$CHECKOUT/stimulate.mjs" "$@"
fi

echo "==> substrate-scope live on context '$CTX'  →  http://localhost:8123"
echo "    Worker +/- and RESET POOL write to this cluster. AUTOSCALE is on by default"
echo "    and takes field ownership of WorkerPool.spec.replicas, so a later"
echo "    'solomog apply' may need --force-conflicts. Pass --no-autoscale to avoid that."
exec node "$CHECKOUT/server.mjs" --live "$@"
