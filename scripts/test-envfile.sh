#!/usr/bin/env bash
set -euo pipefail
#
# Fixture tests for scripts/lib/envfile.sh (no cluster, no secrets from the real .env).
# Run: bash scripts/test-envfile.sh

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/envfile.sh
source "$REPO_DIR/scripts/lib/envfile.sh"

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

assert_file_contains() {
  local label="$1" file="$2" needle="$3"
  if grep -F -- "$needle" "$file" >/dev/null; then
    pass "$label"
  else
    fail "$label (missing $(printf '%q' "$needle") in $file)"
  fi
}

assert_file_not_contains() {
  local label="$1" file="$2" needle="$3"
  if grep -F -- "$needle" "$file" >/dev/null; then
    fail "$label (unexpected $(printf '%q' "$needle") in $file)"
  else
    pass "$label"
  fi
}

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/test-envfile.XXXXXX")"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

EXAMPLE="$WORKDIR/example"
LIVE="$WORKDIR/live.env"

echo "==> parse: quoted empty + trailing comment"
_envfile_parse_key 'FOO=""      # a comment' || fail "parse FOO"
_envfile_split_rhs "$_ef_raw_rhs"
assert_eq "key" "$_ef_key" "FOO"
assert_eq "empty value" "$_ef_value" ""
assert_eq "comment kept" "$_ef_comment" "      # a comment"

echo "==> parse: unquoted value + trailing comment"
_envfile_parse_key 'OWNER=solomog                 # e.g. you@solo.io' || fail "parse OWNER"
_envfile_split_rhs "$_ef_raw_rhs"
assert_eq "owner value" "$_ef_value" "solomog"
case "$_ef_comment" in
  *'# e.g. you@solo.io') pass "owner comment" ;;
  *) fail "owner comment (got=$(printf '%q' "$_ef_comment"))" ;;
esac

echo "==> parse: special-char value (no false comment)"
_envfile_parse_key 'TOK=abc+/=def' || fail "parse TOK"
_envfile_split_rhs "$_ef_raw_rhs"
assert_eq "tok value" "$_ef_value" "abc+/=def"
assert_eq "tok no comment" "$_ef_comment" ""

echo "==> envfile_set preserves position + comment"
cat > "$LIVE" <<'EOF'
# header
AAA="alpha"                    # first
BBB=""                         # second
CCC=keepme                     # third
EOF

envfile_set "$LIVE" BBB "secret/+=value"
line_bbb="$(grep -n '^BBB=' "$LIVE" | head -1)"
assert_eq "BBB still near top (line 3)" "${line_bbb%%:*}" "3"
assert_file_contains "BBB value in place" "$LIVE" 'BBB=secret/+=value'
assert_file_contains "BBB comment kept" "$LIVE" '# second'
bbb_count="$(grep -c '^BBB=' "$LIVE" || true)"
assert_eq "single BBB line" "$bbb_count" "1"

echo "==> envfile_set refuses missing key"
if envfile_set "$LIVE" MISSING "x" 2>/dev/null; then
  fail "missing key should error"
else
  pass "missing key errors"
fi

echo "==> envfile_set refuses CLI-only"
if envfile_set "$LIVE" TOKEN_EXCHANGE "true" 2>/dev/null; then
  fail "CLI-only should error"
else
  pass "CLI-only refused"
fi

echo "==> envfile_sync overlays values, adds new keys, keeps orphans, drops CLI-only"
cat > "$EXAMPLE" <<'EOF'
# ─── Section ───
AAA=""                         # first
BBB=""                         # second
CCC=""                         # third
DDD=""                         # new from example
EOF
cat > "$LIVE" <<'EOF'
AAA=aval
BBB=bval
CCC=cval
ORPHAN=only-here
TOKEN_EXCHANGE=true
EOF

envfile_sync "$EXAMPLE" "$LIVE" >/dev/null

assert_file_contains "sync kept section header" "$LIVE" '# ─── Section ───'
assert_file_contains "sync overlay AAA" "$LIVE" 'AAA=aval'
assert_file_contains "sync overlay BBB" "$LIVE" 'BBB=bval'
assert_file_contains "sync new DDD from example" "$LIVE" 'DDD=""'
assert_file_contains "sync DDD comment" "$LIVE" '# new from example'
assert_file_contains "sync local-only section" "$LIVE" 'Local-only'
assert_file_contains "sync orphan preserved" "$LIVE" 'ORPHAN=only-here'
assert_file_not_contains "sync dropped TOKEN_EXCHANGE" "$LIVE" 'TOKEN_EXCHANGE='

pos_a="$(grep -n '^AAA=' "$LIVE" | head -1 | cut -d: -f1)"
pos_d="$(grep -n '^DDD=' "$LIVE" | head -1 | cut -d: -f1)"
if [ "$pos_a" -lt "$pos_d" ]; then
  pass "example key order preserved"
else
  fail "example key order (AAA@$pos_a DDD@$pos_d)"
fi

echo "==> envfile_diff reports missing / extra (no values)"
cat > "$EXAMPLE" <<'EOF'
AAA=
BBB=
EOF
cat > "$LIVE" <<'EOF'
AAA=secret-value-must-not-appear
CCC=other
EOF
diff_out="$(envfile_diff "$EXAMPLE" "$LIVE")"
printf '%s\n' "$diff_out" | grep -q 'BBB' && pass "diff lists missing BBB" || fail "diff missing BBB"
printf '%s\n' "$diff_out" | grep -q 'CCC' && pass "diff lists extra CCC" || fail "diff extra CCC"
printf '%s\n' "$diff_out" | grep -q 'secret-value-must-not-appear' && fail "diff leaked secret" || pass "diff does not print values"

echo "==> envfile_backup + mode 600"
b="$(envfile_backup "$LIVE")"
[ -f "$b" ] && pass "backup created: ${b##*/}" || fail "backup missing"
mode="$(stat -c %a "$b" 2>/dev/null || stat -f %Lp "$b")"
assert_eq "backup mode 600" "$mode" "600"

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "All envfile tests passed."
  exit 0
fi
echo "$FAIL envfile test(s) failed."
exit 1
