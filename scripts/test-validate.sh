#!/usr/bin/env bash
set -euo pipefail
#
# Fixture tests for scripts/lib/validate.sh (no cluster, no live `task --list`
# in the assertion cases). Harvest is checked against the committed env/Taskfile
# files only.
# Run: bash scripts/test-validate.sh

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/validate.sh
source "$REPO_DIR/scripts/lib/validate.sh"

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
    *) fail "$label (missing $(printf '%q' "$needle"))" ;;
  esac
}

assert_not_contains() {
  local label="$1" hay="$2" needle="$3"
  case "$hay" in
    *"$needle"*) fail "$label (unexpected $(printf '%q' "$needle"))" ;;
    *) pass "$label" ;;
  esac
}

# Isolate CLI-check cases from the developer's shell (and from each other).
unset SOLOMOG_ALLOW_UNKNOWN_VARS AGNTGATEWAY_VERSION 2>/dev/null || true

_validate_fixture() {
  _VALIDATE_FIXTURE=1
  _VALIDATE_NAMES=(agentgateway:ui expose apply monitoring stack)
  _VALIDATE_ALIASES=(delete cluster)
  _VALIDATE_KEYS=(CLUSTER CLUSTERS ROUTE BUNDLE BUNDLES AGENTGATEWAY_VERSION HOST SOLOMOG_ALLOW_UNKNOWN_VARS)
  TASKS=()
  VARS=()
}

_run_cli() {
  local out rc
  set +e
  out="$(solomog_validate_cli 2>&1)"
  rc=$?
  set -e
  _LAST_OUT="$out"
  _LAST_RC="$rc"
}

echo "==> suggest: monitor → monitoring (prefix, distance 3)"
got="$(printf '%s\n' monitoring expose apply | _solomog_validate_suggest monitor)"
assert_contains "suggests monitoring" "$got" "monitoring"
assert_contains "Did you mean prefix" "$got" "Did you mean:"

echo "==> suggest: AGNTGATEWAY_VERSION → AGENTGATEWAY_VERSION"
got="$(printf '%s\n' AGENTGATEWAY_VERSION CLUSTER ROUTE | _solomog_validate_suggest AGNTGATEWAY_VERSION)"
assert_contains "suggests AGENTGATEWAY_VERSION" "$got" "AGENTGATEWAY_VERSION"

echo "==> suggest: no match prints nothing"
got="$(printf '%s\n' expose apply | _solomog_validate_suggest zzzzzzzzzz)"
assert_eq "empty suggestions" "$got" ""

echo "==> harvest: versions.env commented pins and .env.example"
keys="$(_solomog_validate_keys_from_envfile "$REPO_DIR/versions.env")"$'\n'"$(_solomog_validate_keys_from_envfile "$REPO_DIR/.env.example")"
printf '%s\n' "$keys" | grep -qx 'AGENTGATEWAY_VERSION' && pass "harvest AGENTGATEWAY_VERSION" || fail "harvest AGENTGATEWAY_VERSION"
printf '%s\n' "$keys" | grep -qx 'ISTIO_VERSION_CLUSTER_TWO' && pass "harvest commented ISTIO_VERSION_CLUSTER_TWO" || fail "harvest commented ISTIO_VERSION_CLUSTER_TWO"
printf '%s\n' "$keys" | grep -qx 'SOLOMOG_SERIOUS' && pass "harvest SOLOMOG_SERIOUS" || fail "harvest SOLOMOG_SERIOUS"

echo "==> harvest: Taskfile env/vars knobs (CLI-only live here)"
tf="$(_solomog_validate_keys_from_taskfile "$REPO_DIR/Taskfile.yaml")"
printf '%s\n' "$tf" | grep -qx 'CLUSTER' && pass "harvest CLUSTER" || fail "harvest CLUSTER"
printf '%s\n' "$tf" | grep -qx 'ROUTE' && pass "harvest ROUTE" || fail "harvest ROUTE"
printf '%s\n' "$tf" | grep -qx 'BUNDLE' && pass "harvest BUNDLE" || fail "harvest BUNDLE"
printf '%s\n' "$tf" | grep -qx 'TOKEN_EXCHANGE' && pass "harvest TOKEN_EXCHANGE" || fail "harvest TOKEN_EXCHANGE"
printf '%s\n' "$tf" | grep -qx 'DRY_RUN' && pass "harvest DRY_RUN" || fail "harvest DRY_RUN"
vs="$(_solomog_validate_keys_from_taskfile "$REPO_DIR/taskfiles/vsphere.yaml")"
printf '%s\n' "$vs" | grep -qx 'NODES' && pass "harvest vsphere NODES" || fail "harvest vsphere NODES"

echo "==> harvest: summary prose is not a key"
printf '%s\n' "$tf" | grep -qx 'NOTE' && fail "NOTE from summary leaked into keys" || pass "NOTE not harvested"

echo "==> valid chain passes"
_validate_fixture
TASKS=(agentgateway:ui expose apply)
VARS=(ROUTE=true BUNDLES=citizens-audit-logging CLUSTER=clog2)
_run_cli
assert_eq "valid rc" "$_LAST_RC" "0"
assert_eq "valid silent" "$_LAST_OUT" ""

echo "==> aliases are accepted"
_validate_fixture
TASKS=(delete cluster)
VARS=()
_run_cli
assert_eq "alias rc" "$_LAST_RC" "0"

echo "==> unknown task monitor fails before any run"
_validate_fixture
TASKS=(agentgateway:ui monitor expose)
VARS=(ROUTE=true CLUSTER=clog2)
_run_cli
assert_eq "monitor rc" "$_LAST_RC" "1"
assert_contains "monitor error" "$_LAST_OUT" "unknown task 'monitor'"
assert_contains "monitor suggestion" "$_LAST_OUT" "monitoring"
assert_contains "monitor help hint" "$_LAST_OUT" "solomog help --all"

echo "==> unknown CLI KEY fails with suggestion"
_validate_fixture
TASKS=(expose)
VARS=(AGNTGATEWAY_VERSION=v1 CLUSTER=clog2)
_run_cli
assert_eq "typo key rc" "$_LAST_RC" "1"
assert_contains "typo key error" "$_LAST_OUT" "unknown variable 'AGNTGATEWAY_VERSION'"
assert_contains "typo key suggestion" "$_LAST_OUT" "AGENTGATEWAY_VERSION"

echo "==> task + key typos both reported"
_validate_fixture
TASKS=(monitor)
VARS=(AGNTGATEWAY_VERSION=v1)
_run_cli
assert_eq "both rc" "$_LAST_RC" "1"
assert_contains "both task" "$_LAST_OUT" "unknown task 'monitor'"
assert_contains "both key" "$_LAST_OUT" "unknown variable 'AGNTGATEWAY_VERSION'"

echo "==> escape hatch warns on unknown KEY and continues"
_validate_fixture
SOLOMOG_ALLOW_UNKNOWN_VARS=true
TASKS=(expose)
VARS=(NOT_A_REAL_KNOB=1 CLUSTER=clog2)
_run_cli
assert_eq "allow-unknown rc" "$_LAST_RC" "0"
assert_contains "allow-unknown warning" "$_LAST_OUT" "Warning: unknown variable 'NOT_A_REAL_KNOB'"
assert_contains "allow-unknown note" "$_LAST_OUT" "SOLOMOG_ALLOW_UNKNOWN_VARS"
unset SOLOMOG_ALLOW_UNKNOWN_VARS

echo "==> escape hatch does not forgive unknown tasks"
_validate_fixture
SOLOMOG_ALLOW_UNKNOWN_VARS=true
TASKS=(monitor)
VARS=()
_run_cli
assert_eq "allow-unknown still fails tasks" "$_LAST_RC" "1"
assert_contains "allow-unknown still names monitor" "$_LAST_OUT" "unknown task 'monitor'"
unset SOLOMOG_ALLOW_UNKNOWN_VARS

echo "==> prefix-exported KEY typo is caught"
_validate_fixture
export AGNTGATEWAY_VERSION=v1
TASKS=(expose)
VARS=(CLUSTER=clog2)
_run_cli
assert_eq "inherited typo rc" "$_LAST_RC" "1"
assert_contains "inherited typo error" "$_LAST_OUT" "environment variable 'AGNTGATEWAY_VERSION' looks like a typo"
assert_contains "inherited typo suggestion" "$_LAST_OUT" "AGENTGATEWAY_VERSION"
unset AGNTGATEWAY_VERSION

echo "==> HOME is not flagged as a HOST typo"
_validate_fixture
TASKS=(expose)
VARS=(CLUSTER=clog2)
_run_cli
assert_eq "HOME not a typo rc" "$_LAST_RC" "0"
assert_not_contains "HOME not mentioned" "$_LAST_OUT" "HOME"

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "All validate tests passed."
  exit 0
fi
echo "$FAIL validate test(s) failed."
exit 1
