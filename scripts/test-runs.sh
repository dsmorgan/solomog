#!/usr/bin/env bash
set -euo pipefail
#
# Fixture tests for scripts/lib/runs.sh (no cluster). Live-pid cases use this
# process and a short-lived sleep; nothing is written under the repo .solomog/.
# Run: bash scripts/test-runs.sh

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/runs.sh
source "$REPO_DIR/scripts/lib/runs.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/solomog-test-runs.XXXXXX")"
export SOLOMOG_RUNS_DIR="$TMP/runs"
mkdir -p "$SOLOMOG_RUNS_DIR"
unset SOLOMOG_RUN_PID || true
SLEEP_PID=""

cleanup() {
  if [ -n "${SLEEP_PID:-}" ]; then
    kill "$SLEEP_PID" 2>/dev/null || true
    wait "$SLEEP_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

FAIL=0
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; FAIL=$((FAIL + 1)); }

assert_eq() {
  local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    pass "$label"
  else
    fail "$label (got=$(printf '%q' "$got") want=$(printf '%q' "$want"))"
  fi
}

assert_contains() {
  local label="$1" hay="$2" needle="$3"
  case "$hay" in
    *"$needle"*) pass "$label" ;;
    *) fail "$label (missing $(printf '%q' "$needle") in $(printf '%q' "$hay"))" ;;
  esac
}

assert_not_contains() {
  local label="$1" hay="$2" needle="$3"
  case "$hay" in
    *"$needle"*) fail "$label (unexpected $(printf '%q' "$needle"))" ;;
    *) pass "$label" ;;
  esac
}

lstart_of() {
  ps -p "$1" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

write_run() {   # pid start lstart tty clusters cmd
  local pid="$1"
  printf 'start=%s\ntty=%s\nlstart=%s\nclusters=%s\ncmd=%s\n' \
    "$2" "$4" "$3" "$5" "$6" > "$SOLOMOG_RUNS_DIR/$pid"
}

echo "==> redact"
assert_eq "secret names" \
  "$(solomog_run_redact_args eks:create CLUSTER=dmorgan-agw AWS_SECRET_ACCESS_KEY=hunter TOKEN=abc SOLO_LICENSE_KEY=k PASSWORD=p REGION=us-east-2)" \
  "eks:create CLUSTER=dmorgan-agw AWS_SECRET_ACCESS_KEY=*** TOKEN=*** SOLO_LICENSE_KEY=*** PASSWORD=*** REGION=us-east-2"
assert_eq "non-assignment untouched" \
  "$(solomog_run_redact_word 'not a secret')" "not a secret"

echo "==> cluster names"
assert_eq "CLUSTER and CLUSTERS, quotes stripped, dupes dropped" \
  "$(solomog_run_clusters_from_args eks:create CLUSTER=foo CLUSTERS="a foo" CLUSTER='"b"')" \
  "foo a b"
assert_eq "overlap follows the new command" \
  "$(solomog_run_overlap "b a c" "a z")" "a"
assert_eq "prefix is not a match" \
  "$(solomog_run_overlap "a" "ab")" ""
assert_eq "longer name is not a shorter one" \
  "$(solomog_run_overlap "ab" "a")" ""

echo "==> age"
assert_eq "seconds" "$(solomog_run_format_age 0)" "0s"
assert_eq "under a minute" "$(solomog_run_format_age 59)" "59s"
assert_eq "minutes" "$(solomog_run_format_age 60)" "1m"
assert_eq "fourteen minutes" "$(solomog_run_format_age 840)" "14m"
assert_eq "exact hour" "$(solomog_run_format_age 3600)" "1h"
assert_eq "hour and minutes" "$(solomog_run_format_age 3900)" "1h 5m"
assert_eq "bad age" "$(solomog_run_format_age -3)" "?"

echo "==> cluster-list detection"
if solomog_run_is_cluster_list clusters; then pass "clusters"; else fail "clusters"; fi
if solomog_run_is_cluster_list cluster; then pass "cluster"; else fail "cluster"; fi
if solomog_run_is_cluster_list clusters:list; then pass "clusters:list"; else fail "clusters:list"; fi
if solomog_run_is_cluster_list cluster:list; then pass "cluster:list"; else fail "cluster:list"; fi
if solomog_run_is_cluster_list clusters cluster:list; then pass "two list aliases"; else fail "two list aliases"; fi
if solomog_run_is_cluster_list cluster:show; then fail "show is not list"; else pass "show is not list"; fi
if solomog_run_is_cluster_list clusters eks:create; then fail "mixed chain is not list-only"; else pass "mixed chain is not list-only"; fi
if solomog_run_is_cluster_list; then fail "empty is not list"; else pass "empty is not list"; fi

echo "==> begin / end"
if (
  solomog_run_begin eks:create CLUSTER=dmorgan-agw AWS_SECRET_ACCESS_KEY=hunter2 TOKEN=abc
  f="$SOLOMOG_RUNS_DIR/$$"
  if [ ! -f "$f" ]; then
    echo "  FAIL  begin wrote no file"
    exit 1
  fi
  body="$(cat "$f")"
  case "$body" in
    *hunter2*|*TOKEN=abc*) echo "  FAIL  secret landed in the run file"; exit 1 ;;
  esac
  if ! printf '%s\n' "$body" | grep -F -q 'cmd=eks:create CLUSTER=dmorgan-agw AWS_SECRET_ACCESS_KEY=*** TOKEN=***'; then
    echo "  FAIL  redacted cmd missing ($body)"
    exit 1
  fi
  case "$body" in
    *"clusters=dmorgan-agw"*) ;;
    *) echo "  FAIL  clusters line missing ($body)"; exit 1 ;;
  esac
  if [ "${SOLOMOG_RUN_PID:-}" != "$$" ]; then
    echo "  FAIL  SOLOMOG_RUN_PID not exported"
    exit 1
  fi
  solomog_run_end
  if [ -f "$f" ]; then
    echo "  FAIL  end left the file"
    exit 1
  fi
  exit 0
); then
  pass "record redacts, exports the pid, and end removes the file"
else
  fail "record redacts, exports the pid, and end removes the file"
fi

echo "==> scan"
sleep 60 &
SLEEP_PID=$!
disown "$SLEEP_PID" 2>/dev/null || true
SELF_LSTART="$(lstart_of "$$")"
SLEEP_LSTART="$(lstart_of "$SLEEP_PID")"
write_run "$$" "1000" "$SELF_LSTART" "ttys001" "dmorgan-agw" "eks:create CLUSTER=dmorgan-agw REGION=us-east-2"
write_run "$SLEEP_PID" "2000" "$SLEEP_LSTART" "ttys002" "a11" "stack PRODUCTS=istio CLUSTER=a11"
write_run "999999" "500" "not-a-start" "ttys000" "" "gone CLUSTER=nope"
printf 'leave me\n' > "$SOLOMOG_RUNS_DIR/notes"

# SOLOMOG_RUN_PID unset: this process's fixture is listed along with the sleeper.
unset SOLOMOG_RUN_PID || true
SCAN="$(solomog_run_scan)"
want_self="$(printf '1000\t%s\tttys001\tdmorgan-agw\teks:create CLUSTER=dmorgan-agw REGION=us-east-2' "$$")"
want_sleep="$(printf '2000\t%s\tttys002\ta11\tstack PRODUCTS=istio CLUSTER=a11' "$SLEEP_PID")"
assert_contains "oldest first" "$SCAN" "$want_self"
assert_contains "second run" "$SCAN" "$want_sleep"
# The dead pid's line must not appear. Its start time is unique.
assert_not_contains "dead pid dropped" "$SCAN" "999999"
if [ -f "$SOLOMOG_RUNS_DIR/999999" ]; then
  fail "dead pid file removed"
else
  pass "dead pid file removed"
fi
if [ -f "$SOLOMOG_RUNS_DIR/notes" ]; then
  pass "non-pid file kept"
else
  fail "non-pid file kept"
fi
# Order: line 1 is the older start.
first="$(printf '%s\n' "$SCAN" | head -n 1)"
assert_contains "sort by start" "$first" "eks:create CLUSTER=dmorgan-agw"

echo "==> self is omitted"
export SOLOMOG_RUN_PID="$$"
SCAN="$(solomog_run_scan)"
assert_not_contains "own pid hidden" "$SCAN" "eks:create CLUSTER=dmorgan-agw"
assert_contains "other pid still listed" "$SCAN" "stack PRODUCTS=istio CLUSTER=a11"
if [ -f "$SOLOMOG_RUNS_DIR/$$" ]; then
  pass "own file kept while hidden"
else
  fail "own file kept while hidden"
fi

echo "==> recycled pid"
unset SOLOMOG_RUN_PID || true
write_run "$$" "1000" "Thu Jan  1 00:00:00 1970" "ttys001" "dmorgan-agw" "eks:create CLUSTER=stale"
SCAN="$(solomog_run_scan)"
assert_not_contains "mismatched lstart dropped" "$SCAN" "eks:create CLUSTER=stale"
if [ -f "$SOLOMOG_RUNS_DIR/$$" ]; then
  fail "mismatched file removed"
else
  pass "mismatched file removed"
fi

echo "==> note and section"
unset SOLOMOG_RUN_PID || true
write_run "$SLEEP_PID" "$(($(date +%s) - 840))" "$SLEEP_LSTART" "ttys003" "dmorgan-agw other" \
  "eks:create CLUSTER=dmorgan-agw REGION=us-east-2"
# This process is not a run. Point the self-pid at nothing live.
export SOLOMOG_RUN_PID="$$"
NOTE="$(solomog_run_note "other")"
assert_contains "note header" "$NOTE" "Note: solomog is already running:"
assert_contains "note command" "$NOTE" "eks:create CLUSTER=dmorgan-agw REGION=us-east-2"
assert_contains "note age" "$NOTE" "14m"
assert_contains "same cluster" "$NOTE" "same cluster: other"
NOTE_NONE="$(solomog_run_note "somewhere-else")"
assert_not_contains "no suffix without overlap" "$NOTE_NONE" "same cluster:"
SECTION="$(solomog_run_section)"
assert_contains "section header" "$SECTION" "Running"
assert_contains "section command" "$SECTION" "eks:create CLUSTER=dmorgan-agw REGION=us-east-2"
assert_not_contains "section has no same-cluster suffix" "$SECTION" "same cluster:"
# Command substitution strips the trailing blank line, so mark the end first.
marked="$(solomog_run_section; printf 'X')"
case "$marked" in
  *$'\n\n'X) pass "section ends with a blank line" ;;
  *) fail "section ends with a blank line ($(printf '%q' "$marked"))" ;;
esac

# Nothing else running → both stay quiet. Remove the sleeper's record.
rm -f "$SOLOMOG_RUNS_DIR/$SLEEP_PID"
assert_eq "quiet note" "$(solomog_run_note "dmorgan-agw")" ""
assert_eq "quiet section" "$(solomog_run_section)" ""

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "All runs lib tests passed."
else
  echo "${FAIL} test(s) FAILED."
  exit 1
fi
