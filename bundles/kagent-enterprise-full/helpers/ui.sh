#!/usr/bin/env bash
# Port-forward the kagent UI and print its URL. Runs until Ctrl-C.
#
#   bash helpers/ui.sh <cluster> [local-port]      # local port defaults to 8080
#
# With the bundled IdP the UI fetches an admin token from its own /autoauth/ route, so there's no
# login page. After a reinstall, hard-reload an open tab: the UI reads its config once per load.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
. "$REPO/scripts/lib/target.sh"
. "$HERE/env.sh"
CLUSTER="${1:?usage: ui.sh CLUSTER [LOCAL_PORT]}"
PORT="${2:-8080}"
CTX="$(solomog_context "$CLUSTER")"

kubectl --context "$CTX" -n "$KAGENT_NS" rollout status deploy/kagent-ui --timeout=60s >/dev/null
echo "kagent UI: http://localhost:${PORT}   (Ctrl-C to stop)"
exec kubectl --context "$CTX" -n "$KAGENT_NS" port-forward svc/kagent-ui "${PORT}:8080"
