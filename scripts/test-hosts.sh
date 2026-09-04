#!/usr/bin/env bash
set -euo pipefail
#
# Fixture tests for scripts/lib/hosts.sh (no sudo, no /etc/hosts write).
# Run: bash scripts/test-hosts.sh

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/hosts.sh
source "$REPO_DIR/scripts/lib/hosts.sh"

FAIL=0
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

assert_eq() {
  local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    pass "$label"
  else
    fail "$label (got=$(printf '%q' "$got") want=$(printf '%q' "$want"))"
  fi
}

assert_fails_with() {   # label, expected-stderr-fragment, then the command
  local label="$1" needle="$2" out rc=0; shift 2
  out="$("$@" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    fail "$label (expected failure, got rc=0)"
  elif printf '%s' "$out" | grep -F -- "$needle" >/dev/null; then
    pass "$label"
  else
    fail "$label (rc=$rc but missing $(printf '%q' "$needle") in: $out)"
  fi
}

echo "==> _solomog_hosts_stamp"
assert_eq "stamp form" "$(_solomog_hosts_stamp "a1")" "solomog cluster=a1"
if [ "$(_solomog_hosts_stamp "a1")" = "$(_solomog_hosts_stamp "a10")" ]; then
  fail "a1 stamp equals a10"
else
  pass "a1 stamp differs from a10"
fi

echo "==> _solomog_hosts_strip (replace-or-add by hostname)"
HOSTS_FIXTURE="$(printf '%s\n' \
  '# managed by hand' \
  '127.0.0.1 localhost' \
  '# 10.0.0.9 agw.s1.test old-note' \
  '9.9.9.9 agwXs1Ytest' \
  '1.2.3.4 keepme agw.s1.test other' \
  '5.6.7.8 agw.s1.test' \
  '2.2.2.2 keepme2 agw.s1.test # trailing comment' \
  '7.7.7.7 AGW.S1.TEST' \
  '3.3.3.3 agw-s1.test')"
GOT="$(printf '%s\n' "$HOSTS_FIXTURE" | _solomog_hosts_strip "agw.s1.test")"
assert_eq "strip: exact/case-insensitive removed, aliases+comments+near-misses kept" "$GOT" "$(printf '%s\n' \
  '# managed by hand' \
  '127.0.0.1 localhost' \
  '# 10.0.0.9 agw.s1.test old-note' \
  '9.9.9.9 agwXs1Ytest' \
  '1.2.3.4 keepme other' \
  '2.2.2.2 keepme2 # trailing comment' \
  '3.3.3.3 agw-s1.test')"
assert_eq "strip: absent host leaves content untouched" \
  "$(printf '%s\n' "$HOSTS_FIXTURE" | _solomog_hosts_strip "not-there.test")" "$HOSTS_FIXTURE"

echo "==> _solomog_hosts_strip_cluster (stamp only — never hostname)"
STAMP_FIXTURE="$(printf '%s\n' \
  '# managed by hand' \
  '127.0.0.1 localhost' \
  '10.0.0.1 agw.a1.test # solomog cluster=a1' \
  '10.0.0.1 ui.agw.a1.test # solomog cluster=a1' \
  '10.0.0.2 agw.a10.test # solomog cluster=a10' \
  '10.0.0.3 agw.a1.test' \
  '10.0.0.4 custom.example.com # solomog cluster=a1' \
  '10.0.0.5 keepme agw.a1.test other' \
  '10.0.0.6 foo.a1.test # not solomog cluster=a1' \
  '# 10.0.0.9 agw.a1.test # solomog cluster=a1')"
GOT="$(printf '%s\n' "$STAMP_FIXTURE" | _solomog_hosts_strip_cluster "a1")"
assert_eq "strip_cluster: exact stamp removed, unmarked and a10 kept" "$GOT" "$(printf '%s\n' \
  '# managed by hand' \
  '127.0.0.1 localhost' \
  '10.0.0.2 agw.a10.test # solomog cluster=a10' \
  '10.0.0.3 agw.a1.test' \
  '10.0.0.5 keepme agw.a1.test other' \
  '10.0.0.6 foo.a1.test # not solomog cluster=a1' \
  '# 10.0.0.9 agw.a1.test # solomog cluster=a1')"
assert_eq "strip_cluster: absent cluster leaves content untouched" \
  "$(printf '%s\n' "$STAMP_FIXTURE" | _solomog_hosts_strip_cluster "nope")" "$STAMP_FIXTURE"

echo "==> _solomog_hosts_unmarked (leftover hint — not a delete list)"
GOT="$(printf '%s\n' "$STAMP_FIXTURE" | _solomog_hosts_unmarked "a1")"
assert_eq "unmarked: * .a1.test without the stamp" "$GOT" "$(printf '%s\n' \
  '10.0.0.3 agw.a1.test' \
  '10.0.0.5 keepme agw.a1.test other' \
  '10.0.0.6 foo.a1.test # not solomog cluster=a1')"
assert_eq "unmarked: a10 does not pick a1 leftovers" \
  "$(printf '%s\n' "$STAMP_FIXTURE" | _solomog_hosts_unmarked "a10")" ""

echo "==> _solomog_hosts_lines_for (cluster:show)"
GOT="$(printf '%s\n' "$STAMP_FIXTURE" | _solomog_hosts_lines_for "a1")"
assert_eq "lines_for: stamped (any host) plus unmarked * .a1.test" "$GOT" "$(printf '%s\n' \
  '10.0.0.1 agw.a1.test # solomog cluster=a1' \
  '10.0.0.1 ui.agw.a1.test # solomog cluster=a1' \
  '10.0.0.3 agw.a1.test' \
  '10.0.0.4 custom.example.com # solomog cluster=a1' \
  '10.0.0.5 keepme agw.a1.test other' \
  '10.0.0.6 foo.a1.test # not solomog cluster=a1')"

echo "==> _solomog_hosts_stamped"
GOT="$(printf '%s\n' "$STAMP_FIXTURE" | _solomog_hosts_stamped "a1")"
assert_eq "stamped: only exact cluster=a1" "$GOT" "$(printf '%s\n' \
  '10.0.0.1 agw.a1.test # solomog cluster=a1' \
  '10.0.0.1 ui.agw.a1.test # solomog cluster=a1' \
  '10.0.0.4 custom.example.com # solomog cluster=a1')"

echo "==> solomog_hosts_set / unset refuse empty CLUSTER (no /etc/hosts write)"
CLUSTER="" assert_fails_with "set without CLUSTER" "CLUSTER is required" \
  solomog_hosts_set "agw.a1.test" "10.0.0.1"
assert_fails_with "unset without cluster" "cluster name required" \
  solomog_hosts_unset_cluster ""

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "All hosts lib tests passed."
else
  echo "${FAIL} test(s) FAILED."
  exit 1
fi
