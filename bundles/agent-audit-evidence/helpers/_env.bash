# Shared setup for the by-hand helpers. Helpers are not run by solomog, so nothing has loaded .env
# or resolved a context: do both here. CLUSTER is required (no silent default).
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
[ -f "$REPO_DIR/.env" ] && { set -a; . "$REPO_DIR/.env"; set +a; }
: "${CLUSTER:?set CLUSTER=<cluster name>, e.g. CLUSTER=audit bash $0}"
. "$REPO_DIR/scripts/lib/target.sh"
CONTEXT="${CONTEXT:-$(solomog_context "$CLUSTER")}"
GATEWAY="${GATEWAY:-agw}"
HOST="${HOST:-$(kubectl --context "$CONTEXT" get gateway "$GATEWAY" -n agentgateway-system \
  -o jsonpath='{.metadata.annotations.solomog\.io/host}' 2>/dev/null)}"
[ -n "$HOST" ] || { echo "✗ could not read the gateway host from Gateway/${GATEWAY} (run solomog expose)" >&2; exit 1; }
HELPERS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
