#!/usr/bin/env bash
set -euo pipefail
#
# Runs a bundle's tests and captures the results. Tests live in bundles/<BUNDLE>/tests/
# (or bundles/private/<BUNDLE>/tests/) as *.sh files, run in LC_ALL=C order. Each test is
# a shell script — exit 0 = pass, non-zero = fail — and inherits CONTEXT / CLUSTER /
# GATEWAY / HOST, so it can mix curl ("https://$HOST/anthropic") and kubectl checks
# ("kubectl --context $CONTEXT get httproute ..."). The captured commands + output are the
# record of what was validated.
#
# Every run is captured under .solomog/test-runs/<BUNDLE>-<timestamp>/ (gitignored): one
# <test>.log per test (output + exit code) plus a `summary`. Exits non-zero if any failed.
#
# Usage: test-bundle.sh <kube-context>
# Env:
#   BUNDLE    (required) bundle whose tests/ to run
#   GATEWAY   gateway name for $HOST default (default agw)
#   HOST      base host for curls (default <GATEWAY>.<CLUSTER>.test)

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_DIR/scripts/lib/ui.sh"
CONTEXT="${1:?Usage: test-bundle.sh <kube-context>}"
CLUSTER="${CONTEXT#vcluster-docker_}"
BUNDLE="${BUNDLE:?Set BUNDLE=<name>. List with: solomog bundles:list}"
GATEWAY="${GATEWAY:-agw}"
HOST="${HOST:-${GATEWAY}.${CLUSTER}.test}"

# Resolve the tests dir (private overrides committed) — mirrors apply-bundle resolution.
DIR=""
if   [[ -d "$REPO_DIR/bundles/private/$BUNDLE/tests" ]]; then DIR="$REPO_DIR/bundles/private/$BUNDLE/tests"
elif [[ -d "$REPO_DIR/bundles/$BUNDLE/tests" ]];         then DIR="$REPO_DIR/bundles/$BUNDLE/tests"
else
  echo "Error: no tests for bundle '$BUNDLE' (looked for bundles[/private]/$BUNDLE/tests/)." >&2
  exit 1
fi

FILES="$(cd "$DIR" && LC_ALL=C ls 2>/dev/null | grep -E '\.sh$' | LC_ALL=C sort || true)"
if [[ -z "$FILES" ]]; then
  echo "Error: no *.sh tests in $DIR" >&2
  exit 1
fi

TS="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$REPO_DIR/.solomog/test-runs/${BUNDLE}-${TS}"
mkdir -p "$RUN_DIR"

echo "==> Testing bundle '$BUNDLE' on ${CONTEXT}"
echo "    host=${HOST}"
echo "    results→ ${RUN_DIR}"

pass=0; fail=0; RESULTS=()
while IFS= read -r name; do
  [[ -z "$name" ]] && continue
  log="$RUN_DIR/${name%.sh}.log"
  solomog_step "test: ${name}"
  # Run the test with the targeting env; tee output to its log. PIPESTATUS[0] is the
  # test's exit (tee is last in the pipe and ~always 0). The if-guard keeps set -e from
  # aborting the whole run on a failing test — we want to run them all.
  if CONTEXT="$CONTEXT" CLUSTER="$CLUSTER" GATEWAY="$GATEWAY" HOST="$HOST" \
       bash "$DIR/$name" 2>&1 | tee "$log"; then
    rc=0
  else
    rc=${PIPESTATUS[0]}
  fi
  printf 'exit=%s\n' "$rc" >> "$log"
  if [[ $rc -eq 0 ]]; then
    echo "    ✓ PASS"; pass=$((pass + 1)); RESULTS+=("PASS  ${name}")
  else
    echo "    ✗ FAIL (exit ${rc})"; fail=$((fail + 1)); RESULTS+=("FAIL  ${name}  (exit ${rc})")
  fi
done <<EOF
$FILES
EOF

{
  printf 'bundle=%s  context=%s  host=%s  when=%s\n' "$BUNDLE" "$CONTEXT" "$HOST" "$TS"
  printf '%s\n' "${RESULTS[@]}"
  printf 'passed=%s failed=%s\n' "$pass" "$fail"
} > "$RUN_DIR/summary"

solomog_summary "Tests: ${BUNDLE} — ${pass} passed, ${fail} failed" \
  "${RESULTS[@]}" \
  "results: ${RUN_DIR}"

[[ $fail -eq 0 ]]   # non-zero exit if any test failed
