#!/usr/bin/env bash
set -euo pipefail
#
# Fixture tests for scripts/lib/plugins.sh and the wrapper's plugin dispatch. Builds
# throwaway plugins in a temp dir; never touches plugins/ or .solomog/, and never
# reaches `task` (core task names are injected via SOLOMOG_PLUGIN_CORE_TASKS).
# Run: bash scripts/test-plugins.sh

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/solomog-test-plugins.XXXXXX")" && pwd)"  # no // from TMPDIR
trap 'rm -rf "$TMP"' EXIT
export SOLOMOG_PLUGINS_DIR="$TMP/plugins"
export SOLOMOG_PLUGIN_CORE_TASKS="stack expose apply"
unset SOLOMOG_PLUGIN_PATH || true

FAIL=0
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; FAIL=$((FAIL + 1)); }

assert_contains() {
  local label="$1" got="$2" want="$3"
  case "$got" in
    *"$want"*) pass "$label" ;;
    *) fail "$label (missing $(printf '%q' "$want"))"; printf '%s\n' "$got" | sed 's/^/        /' ;;
  esac
}

assert_not_contains() {
  local label="$1" got="$2" want="$3"
  case "$got" in
    *"$want"*) fail "$label (unexpected $(printf '%q' "$want"))" ;;
    *) pass "$label" ;;
  esac
}

# make_plugin <root> <name> <commands> [extra conf lines…]
make_plugin() {
  local root="$1" name="$2" cmds="$3" c
  shift 3
  mkdir -p "$root/$name/bin"
  {
    echo "name=$name"
    echo "api=1"
    echo "description=the $name plugin   # trailing comment is dropped"
    echo "commands=$cmds"
    for c in "$@"; do echo "$c"; done
  } > "$root/$name/plugin.conf"
  for c in $cmds; do
    cat > "$root/$name/bin/solomog-$c" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "fail" ]; then echo "broken on purpose"; exit 3; fi
echo "args=$* pwd=$PWD"
echo "root=$SOLOMOG_ROOT api=$SOLOMOG_PLUGIN_API"
echo "dir=$SOLOMOG_PLUGIN_DIR data=$SOLOMOG_PLUGIN_DATA"
SH
    chmod +x "$root/$name/bin/solomog-$c"
  done
}

wrapper() { bash "$REPO_DIR/solomog" "$@" 2>&1; }

echo "no plugins installed"
out="$(wrapper plugins)"
assert_contains "list says none" "$out" "no plugins installed"
out="$(source "$REPO_DIR/scripts/lib/plugins.sh"; solomog_plugins_help_rows)"
assert_contains "no help rows" "[$out]" "[]"

echo "dispatch"
make_plugin "$SOLOMOG_PLUGINS_DIR" hello "hello hi"
mkdir -p "$TMP/caller"
out="$(cd "$TMP/caller" && wrapper hello a b=c)"
assert_contains "args pass through, KEY=VALUE included" "$out" "args=a b=c"
assert_contains "runs in the caller's directory" "$out" "pwd=$TMP/caller"
assert_contains "SOLOMOG_ROOT is the repo" "$out" "root=$REPO_DIR api=1"
assert_contains "plugin dir and data dir" "$out" "dir=$SOLOMOG_PLUGINS_DIR/hello data=$REPO_DIR/.solomog/plugins/hello"
assert_contains "second command of the same plugin" "$(wrapper hi)" "args="
set +e; wrapper hello fail >/dev/null; rc=$?; set -e
[ "$rc" -eq 3 ] && pass "plugin exit code propagates" || fail "plugin exit code propagates (rc=$rc)"

echo "lookup rules"
(
  source "$REPO_DIR/scripts/lib/plugins.sh"
  solomog_plugin_find hello >/dev/null && pass "find by command" || fail "find by command"
  solomog_plugin_find "eks:create" >/dev/null && fail "namespaced names never match" || pass "namespaced names never match"
  solomog_plugin_find nope >/dev/null && fail "unknown command" || pass "unknown command"
  [ "$(solomog_plugin_conf "$SOLOMOG_PLUGINS_DIR/hello" description)" = "the hello plugin" ] &&
    pass "conf drops trailing comment" || fail "conf drops trailing comment"
)

echo "nested repo layout and SOLOMOG_PLUGIN_PATH"
make_plugin "$SOLOMOG_PLUGINS_DIR/some-repo" deep "deep"
make_plugin "$TMP/elsewhere" far "far"
assert_contains "two levels deep" "$(wrapper deep)" "dir=$SOLOMOG_PLUGINS_DIR/some-repo/deep"
assert_contains "SOLOMOG_PLUGIN_PATH" "$(SOLOMOG_PLUGIN_PATH="$TMP/elsewhere" wrapper far)" "dir=$TMP/elsewhere/far"

echo "core tasks win"
make_plugin "$SOLOMOG_PLUGINS_DIR" greedy "stack"
out="$(source "$REPO_DIR/scripts/lib/plugins.sh"; solomog_plugin_exec stack 2>&1; echo "returned=$?")"
assert_contains "exec declines a core name" "$out" "returned=1"
assert_contains "and says why" "$out" "is a core task"

echo "broken plugins fail loudly"
make_plugin "$SOLOMOG_PLUGINS_DIR" future "future" "api=2"
set +e; out="$(wrapper future)"; rc=$?; set -e
assert_contains "API mismatch named" "$out" "plugin API 2, solomog speaks 1"
[ "$rc" -eq 1 ] && pass "API mismatch exits 1" || fail "API mismatch exits 1 (rc=$rc)"
make_plugin "$SOLOMOG_PLUGINS_DIR" noexec "noexec"
chmod -x "$SOLOMOG_PLUGINS_DIR/noexec/bin/solomog-noexec"
assert_contains "non-executable named" "$(wrapper noexec)" "bin/solomog-noexec missing or not executable"

echo "help visibility"
make_plugin "$SOLOMOG_PLUGINS_DIR" secret "secret" "hidden=true"
out="$(source "$REPO_DIR/scripts/lib/plugins.sh"; solomog_plugins_help_rows)"
assert_contains "shown plugin in help" "$out" "hello"
assert_not_contains "hidden plugin not in help" "$out" "secret"
assert_contains "hidden plugin still runs" "$(wrapper secret)" "args="
out="$(wrapper plugins)"
assert_contains "list shows hidden ones" "$out" "secret"
assert_contains "list flags broken ones" "$out" "plugin API 2"

echo "doctor"
rm -rf "$SOLOMOG_PLUGINS_DIR"
make_plugin "$SOLOMOG_PLUGINS_DIR" good "good" "doctor=good" "test=t.sh"
printf 'echo "1 test(s) failed"; exit 1\n' > "$SOLOMOG_PLUGINS_DIR/good/t.sh"
set +e; out="$(wrapper plugins doctor)"; rc=$?; set -e
assert_contains "doctor ok" "$out" "ok    good: doctor"
[ "$rc" -eq 0 ] && pass "healthy doctor exits 0" || fail "healthy doctor exits 0 (rc=$rc)"
set +e; out="$(wrapper plugins doctor --test)"; rc=$?; set -e
assert_contains "--test runs plugin tests" "$out" "FAIL  good: tests"
[ "$rc" -eq 1 ] && pass "failing tests exit 1" || fail "failing tests exit 1 (rc=$rc)"
make_plugin "$SOLOMOG_PLUGINS_DIR" sick "sick" "doctor=sick fail"
set +e; out="$(wrapper plugins doctor)"; rc=$?; set -e
assert_contains "failing doctor reported with output" "$out" "broken on purpose"
[ "$rc" -eq 1 ] && pass "failing doctor exits 1" || fail "failing doctor exits 1 (rc=$rc)"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "All plugins tests passed."
else
  echo "$FAIL plugins test(s) failed"
  exit 1
fi
