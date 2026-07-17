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
# Usage: CLUSTER=<name> [CONTEXT=<override>] BUNDLE=<name> test-bundle.sh
#   Context resolves from CLUSTER (registry/vind) or the CONTEXT override — see lib/target.sh.
# Env:
#   BUNDLE    (required) bundle name(s) whose tests/ to run. Space-separated for several
#             bundles, run left-to-right (BUNDLE and BUNDLES are interchangeable, like
#             CLUSTER/CLUSTERS — the Taskfile folds both into BUNDLE).
#   GATEWAY   gateway name for $HOST default (default agw)
#   HOST      base host for curls (default <GATEWAY>.<CLUSTER>.test)

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_DIR/scripts/lib/ui.sh"
source "$REPO_DIR/scripts/lib/gateway.sh"
# shellcheck source=lib/target.sh
source "$REPO_DIR/scripts/lib/target.sh"
CLUSTER="${CLUSTER:-cluster-one}"
CONTEXT="$(solomog_context "$CLUSTER")"   # CONTEXT override → registry (external) → vind default
BUNDLE="${BUNDLE:?Set BUNDLE=<name>. List with: solomog bundles:list}"
# Auto-detect the gateway (agw/kgw) from the cluster, like expose — so $HOST matches the
# cert expose minted. Override with GATEWAY=/HOST= for anything non-standard.
GATEWAY="${GATEWAY:-$(solomog_detect_gateway "$CONTEXT")}"
HOST="${HOST:-${GATEWAY}.${CLUSTER}.test}"
TS="$(date +%Y%m%d-%H%M%S)"

# Run one bundle's tests, capturing to its own run dir. Echoes "<pass> <fail>" on stdout
# (so the caller can tally) and prints progress/summary on stderr. Returns non-zero if any
# test failed.
test_one() {
  local bundle="$1" dir="" name log rc pass=0 fail=0
  local -a RESULTS=()

  # Resolve the tests dir (private overrides committed) — mirrors apply-bundle resolution.
  if   [[ -d "$REPO_DIR/bundles/private/$bundle/tests" ]]; then dir="$REPO_DIR/bundles/private/$bundle/tests"
  elif [[ -d "$REPO_DIR/bundles/$bundle/tests" ]];         then dir="$REPO_DIR/bundles/$bundle/tests"
  else
    echo "Error: no tests for bundle '$bundle' (looked for bundles[/private]/$bundle/tests/)." >&2
    return 1
  fi

  local files
  files="$(cd "$dir" && LC_ALL=C ls 2>/dev/null | grep -E '\.sh$' | LC_ALL=C sort || true)"
  if [[ -z "$files" ]]; then
    echo "Error: no *.sh tests in $dir" >&2
    return 1
  fi

  local run_dir="$REPO_DIR/.solomog/test-runs/${bundle}-${TS}"
  mkdir -p "$run_dir"

  echo "==> Testing bundle '$bundle' on ${CONTEXT}" >&2
  echo "    host=${HOST}" >&2
  echo "    results→ ${run_dir}" >&2

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    log="$run_dir/${name%.sh}.log"
    solomog_step "test: ${bundle}/${name}" >&2
    # Run the test with the targeting env; tee output to its log. PIPESTATUS[0] is the
    # test's exit (tee is last in the pipe and ~always 0). The if-guard keeps set -e from
    # aborting the whole run on a failing test — we want to run them all.
    if CONTEXT="$CONTEXT" CLUSTER="$CLUSTER" GATEWAY="$GATEWAY" HOST="$HOST" \
         bash "$dir/$name" 2>&1 | tee "$log" >&2; then
      rc=0
    else
      rc=${PIPESTATUS[0]}
    fi
    printf 'exit=%s\n' "$rc" >> "$log"
    if [[ $rc -eq 0 ]]; then
      echo "    ✓ PASS" >&2; pass=$((pass + 1)); RESULTS+=("PASS  ${name}")
    else
      echo "    ✗ FAIL (exit ${rc})" >&2; fail=$((fail + 1)); RESULTS+=("FAIL  ${name}  (exit ${rc})")
    fi
  done <<EOF
$files
EOF

  {
    printf 'bundle=%s  context=%s  host=%s  when=%s\n' "$bundle" "$CONTEXT" "$HOST" "$TS"
    printf '%s\n' "${RESULTS[@]}"
    printf 'passed=%s failed=%s\n' "$pass" "$fail"
  } > "$run_dir/summary"

  solomog_summary "Tests: ${bundle} — ${pass} passed, ${fail} failed" \
    "${RESULTS[@]}" \
    "results: ${run_dir}" >&2

  echo "$pass $fail"
  [[ $fail -eq 0 ]]
}

# BUNDLE may name several bundles (space-separated) — test each in order, tally across all.
total_pass=0; total_fail=0; any_err=0
for b in $BUNDLE; do
  # Capture the "<pass> <fail>" line; the if-guard keeps set -e from aborting on a failing
  # bundle so we run every bundle's tests and report a combined result.
  if counts="$(test_one "$b")"; then :; else any_err=1; fi
  # Last stdout line is the "<pass> <fail>" tally; default to 0 0 if the bundle errored
  # out before running anything (errors already went to stderr).
  counts="$(printf '%s\n' "$counts" | tail -n1)"
  [[ "$counts" =~ ^[0-9]+\ [0-9]+$ ]] || counts="0 0"
  total_pass=$((total_pass + ${counts%% *}))
  total_fail=$((total_fail + ${counts##* }))
done

# Combined verdict across all bundles (each bundle also printed its own summary above).
echo "" >&2
echo "── all bundles: ${total_pass} passed, ${total_fail} failed ──" >&2

[[ $total_fail -eq 0 && $any_err -eq 0 ]]   # non-zero exit if any test failed or a bundle errored
