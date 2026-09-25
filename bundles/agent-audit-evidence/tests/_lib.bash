# Shared helpers for the agent-audit-evidence tests.
#
# NOT named *.sh: the runner globs tests/*.sh, so a library with that extension would run as a test.
# Source it with:  . "$(dirname "$0")/_lib.bash"
# The runner exports CONTEXT / CLUSTER / GATEWAY / HOST and sources .env.

NS_GW=agentgateway-system
NS_APP=agent-evidence
HELPERS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../helpers" && pwd)"
PRIORAUTH_ACTOR="${EVIDENCE_PRIORAUTH_ACTOR:-priorauth-agent}"
INTAKE_ACTOR="${EVIDENCE_INTAKE_ACTOR:-intake-agent}"
SENSITIVE_TOOL="${EVIDENCE_SENSITIVE_TOOL:-approve_prior_auth}"
# What each agent DECLARES itself to be (X-Agent-Name, from its Deployment). Deliberately separate
# from the *_ACTOR values above, which are what Okta asserts in act.sub: the two can differ, and the
# evidence record keeps them apart for exactly that reason.
PRIORAUTH_NAME=priorauth-agent
INTAKE_NAME=intake-agent

# Self-skip, not fail, when the bundle's Okta side is not configured or nobody has logged in.
ev_require_login() {
  if [ -z "${XAA_AGENT_A_CLIENT_ID:-}" ] || [ -z "${XAA_LOGIN_CLIENT_ID:-}" ]; then
    echo "SKIP: Okta Cross App Access not configured (XAA_AGENT_A_CLIENT_ID / XAA_LOGIN_CLIENT_ID). See docs/OKTA-SETUP.md."
    exit 0
  fi
  local cache
  cache=$(bash "$HELPERS/xaa-token-path.sh" a 2>/dev/null) || {
    echo "SKIP: no reviewer login cached. Run:  bash bundles/agent-audit-evidence/helpers/xaa-login.sh"; exit 0; }
  local exp
  exp=$(jq -r '.id_token' "$cache" | ev_jwt_claims | jq -r '.exp // 0')
  if [ "$exp" -lt "$(date +%s)" ]; then
    echo "✗ the cached reviewer ID token expired $(( ( $(date +%s) - exp ) / 60 ))m ago." >&2
    echo "  Re-run:  bash bundles/agent-audit-evidence/helpers/xaa-login.sh" >&2
    exit 1
  fi
}

ev_id_token() { jq -r '.id_token' "$(bash "$HELPERS/xaa-token-path.sh" a)"; }

# Decode a JWT payload read from stdin (no verification: display only).
ev_jwt_claims() {
  local seg
  seg=$(cut -d. -f2 | tr '_-' '/+')
  case $(( ${#seg} % 4 )) in 2) seg="${seg}==" ;; 3) seg="${seg}=" ;; esac
  printf '%s' "$seg" | base64 -d 2>/dev/null
}

# A per-run marker. Tests send it as X-Agent-Version (landing in audit.declared.agent_version) so they
# can find THEIR log lines among everything else the gateway is logging.
ev_nonce() { echo "t$$-$(date +%s)"; }

ev_log_grep() {
  local pattern="$1" tries="${2:-10}" out=""
  local i=0
  while [ "$i" -lt "$tries" ]; do
    out=$(kubectl --context "$CONTEXT" logs -n "$NS_GW" "deploy/${GATEWAY}" --since=5m --tail=4000 2>/dev/null \
          | grep -F "$pattern" || true)
    [ -n "$out" ] && { printf '%s\n' "$out" | ev_norm; return 0; }
    i=$((i + 1))
    sleep 2
  done
  return 1
}

# Flatten a tracing-subscriber `fields` envelope, if there is one, so every test can treat the
# access log attributes as top-level JSON keys. Which shape the proxy emits depends on the
# subscriber, and a test that assumes one and gets the other reports a missing attribute that is
# right there — the worst possible failure mode for a bundle whose whole subject is attributes.
# Non-JSON lines (text format) pass through untouched.
ev_norm() {
  while IFS= read -r l; do
    printf '%s\n' "$l" \
      | jq -c 'if type == "object" and has("fields") and (.fields | type == "object")
               then (del(.fields) + .fields) else . end' 2>/dev/null \
      || printf '%s\n' "$l"
  done
}

# Assert a JSON access log line carries a field. The proxy is set to JSON by 02-parameters.sh, so
# a plain grep for the quoted key is enough and stays readable in the captured test log.
ev_has_field() {
  local line="$1" field="$2"
  case "$line" in
    *"\"${field}\""*) return 0 ;;
    *) return 1 ;;
  esac
}

# Substring test against a LARGE string, without a pipe.
#
# `printf '%s' "$big" | grep -q x` looks equivalent and is not: grep -q exits the moment it
# matches, printf takes SIGPIPE, and under `set -o pipefail` the pipeline reports 141 — so a
# successful match reads as a failure. It only shows up once the string is big enough that printf
# has not finished writing, which is exactly when a test is scanning a collector dump. Bash pattern
# matching has no pipeline and no such trap.
ev_contains() {
  case "$1" in
    *"$2"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Find the log line for a marker that also satisfies a jq filter — needed when one MCP session
# produces several requests under one marker and only one of them is the interesting one.
ev_log_select() {
  local pattern="$1" filter="$2" tries="${3:-10}" out=""
  local i=0
  while [ "$i" -lt "$tries" ]; do
    out=$(kubectl --context "$CONTEXT" logs -n "$NS_GW" "deploy/${GATEWAY}" --since=5m --tail=4000 2>/dev/null \
          | grep -F "$pattern" | ev_norm | jq -c "select(${filter})" 2>/dev/null || true)
    [ -n "$out" ] && { printf '%s\n' "$out" | tail -1; return 0; }
    i=$((i + 1))
    sleep 2
  done
  return 1
}

ev_report_field() {
  local line="$1" field="$2" label="${3:-$2}"
  local val
  val=$(printf '%s' "$line" | jq -r --arg f "$field" '(.[$f] // (.fields[$f]? // empty)) | if type == "array" or type == "object" then tojson else . end' 2>/dev/null || true)
  if [ -n "$val" ]; then
    printf '    %-34s %s\n' "$label" "$val"
    return 0
  fi
  printf '    %-34s (absent)\n' "$label"
  return 1
}
