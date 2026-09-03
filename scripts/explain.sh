#!/usr/bin/env bash
set -euo pipefail
#
# explain.sh — customer-shaped bash recipe for a solomog command line.
# Invoked by the wrapper as `solomog explain|wwit <tasks>…`. Never installs,
# never talks to a cluster, never writes secret values.
#
# Usage: explain.sh [task...] [KEY=VALUE...]
# Env (also accepted as KEY=VALUE args):
#   CLUSTER EDITION PRODUCTS ISTIO_MODE GATEWAY HOST NAME NAMESPACE CLASS CONFIG
#   BUNDLE BUNDLES TOKEN_EXCHANGE ROUTE ROUTE_PATH and the rest of the task knobs.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/validate.sh
source "$REPO_DIR/scripts/lib/validate.sh"
# shellcheck source=explain/products.sh
source "$REPO_DIR/scripts/explain/products.sh"
# shellcheck source=explain/expose.sh
source "$REPO_DIR/scripts/explain/expose.sh"
# shellcheck source=explain/apply.sh
source "$REPO_DIR/scripts/explain/apply.sh"
# shellcheck source=explain/tail.sh
source "$REPO_DIR/scripts/explain/tail.sh"

TASKS=()
VARS=()
for a in "$@"; do
  case "$a" in
    *=*) VARS+=("$a") ;;
    *)   TASKS+=("$a") ;;
  esac
done

# Pins first, then CLI KEY=VALUE so a one-off version override wins.
if [ -f "$REPO_DIR/versions.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$REPO_DIR/versions.env"
  set +a
fi
if [ ${#VARS[@]} -gt 0 ]; then
  for _v in "${VARS[@]}"; do
    _k="${_v%%=*}"
    case "$_k" in
      [A-Za-z_]*) export "$_v" ;;
    esac
  done
  unset _v _k
fi

EDITION="${EDITION:-enterprise}"
ISTIO_MODE="${ISTIO_MODE:-ambient}"
CLUSTER="${CLUSTER:-${CLUSTERS:-my-cluster}}"
case "$CLUSTER" in *" "*) CLUSTER="${CLUSTER%% *}" ;; esac
GATEWAY="${GATEWAY:-agw}"
HOST="${HOST:-${GATEWAY}.${CLUSTER}.test}"

explain_usage() {
  cat <<'EOF'
Usage: solomog explain <task> [task...] [KEY=VALUE...]
       solomog wwit    <task> [task...] [KEY=VALUE...]

Print a bash recipe of helm / kubectl / docker commands a customer would run
for the rest of the command line. Does not execute anything.

Recipes exist for:
  products   stack, agentgateway, kgateway, kagent, gloo-gateway, gloo-mesh,
             istio:ambient:single, istio:sidecar:single, kgateway:with-istio,
             agentgateway:ui
  gateway    expose
  bundles    apply
  apps       apps:utils, apps:mock-openai, apps:mcp-stripe, apps:bookinfo
  add-ons    portal, monitoring
  standalone standalone, standalone:validate

Other tasks emit a stub comment and continue.

Examples:
  solomog explain agentgateway CLUSTER=aaa
  solomog wwit agentgateway expose apply BUNDLE=llmroute CLUSTER=aaa
EOF
}

if [ ${#TASKS[@]} -eq 0 ]; then
  explain_usage
  exit 0
fi

if ! solomog_validate_cli; then
  exit 1
fi

# Rebuild the generating command for the header (no secret values).
_gen="solomog explain"
for _t in "${TASKS[@]}"; do
  _gen="${_gen} ${_t}"
done
if [ ${#VARS[@]} -gt 0 ]; then
  for _v in "${VARS[@]}"; do
    _n="${_v%%=*}"
    case "$(printf '%s' "$_n" | tr '[:lower:]' '[:upper:]')" in
      TOKEN_EXCHANGE|TOKEN_EXCHANGE_JWKS_URL|TOKEN_EXCHANGE_API_VALIDATOR|TOKEN_EXCHANGE_API_VALIDATOR_URL)
        _gen="${_gen} ${_v}" ;;
      *KEY*|*TOKEN*|*SECRET*|*PASSWORD*|*PASS*) _gen="${_gen} ${_n}=***" ;;
      *) _gen="${_gen} ${_v}" ;;
    esac
  done
fi
unset _t _v _n

_pins=""
[ -n "${AGENTGATEWAY_VERSION:-}" ] && _pins="${_pins}    agentgateway: ${AGENTGATEWAY_VERSION}"
[ -n "${KGATEWAY_VERSION:-}" ] && _pins="${_pins}    kgateway: ${KGATEWAY_VERSION}"
[ -n "${ISTIO_VERSION:-}" ] && _pins="${_pins}    istio: ${ISTIO_VERSION}"
[ -n "${GATEWAY_API_VERSION:-}" ] && _pins="${_pins}    gateway-api: ${GATEWAY_API_VERSION}"

cat <<EOF
#!/usr/bin/env bash
# Generated from: ${_gen}
# Edition: ${EDITION}${_pins}
# Assumes your kube context is already selected. Secrets are \$PLACEHOLDERS.
# This is a starting point — fill in license keys, edit hostnames, then run
# the pieces you need.

set -euo pipefail

EOF
unset _gen _pins

EXPLAIN_GWAPI_DONE=0
EXPLAIN_CLUSTER_NOTE=0

explain_section() {
  printf '\n# --- %s ----------------------------------------------------------\n' "$1"
}

explain_cluster_note() {
  [ "${EXPLAIN_CLUSTER_NOTE}" = 1 ] && return 0
  EXPLAIN_CLUSTER_NOTE=1
  echo "# A local Kubernetes cluster would be created here if you did not already have one."
}

explain_stub() {
  local t="$1"
  explain_section "$t"
  echo "# No customer-shaped recipe for '${t}' yet."
  echo "# See: solomog help ${t}"
  echo "explain: no recipe for ${t} yet" >&2
}

explain_dispatch() {
  local t="$1"
  case "$t" in
    stack|agentgateway|kgateway|kagent|gloo-gateway|gloo-mesh|agentgateway:ui|kgateway:with-istio)
      explain_task_products "$t" ;;
    istio:ambient:single)
      ISTIO_MODE=ambient
      explain_task_products istio:ambient:single ;;
    istio:sidecar:single)
      ISTIO_MODE=sidecar
      explain_task_products istio:sidecar:single ;;
    expose)
      explain_task_expose ;;
    apply)
      explain_task_apply ;;
    portal|monitoring)
      explain_task_addon "$t" ;;
    apps:utils|apps:mock-openai|apps:mcp-stripe|apps:bookinfo)
      explain_task_app "$t" ;;
    standalone|standalone:validate)
      explain_task_standalone "$t" ;;
    *)
      explain_stub "$t" ;;
  esac
}

for _t in "${TASKS[@]}"; do
  explain_dispatch "$_t"
done
unset _t
