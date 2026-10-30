#!/usr/bin/env bash
# solomog plugins — optional commands that live outside this repo.
# bash 3.2 compatible (macOS). Sourced by the solomog wrapper and scripts/lib/help.sh.
#
# A plugin is a directory holding a `plugin.conf` manifest, found up to two levels
# under plugins/ (gitignored; usually a clone of a separate repo) or under any
# directory in SOLOMOG_PLUGIN_PATH (colon-separated). Nothing in the base depends on
# a plugin; with none installed every function here is a quiet no-op.
#
# plugin.conf (KEY=VALUE, never sourced):
#   name=sessions                         plugin name
#   api=1                                 must equal SOLOMOG_PLUGIN_API
#   description=…                         one line, for help and `solomog plugins`
#   commands=sessions                     each needs an executable bin/solomog-<command>
#   hidden=true                           optional: keep out of the help index
#   doctor=sessions doctor                optional: health check run by `solomog plugins doctor`
#   test=tests/test-sessions.sh           optional: fixture tests run by `… doctor --test`
#
# A command runs as its own process with: SOLOMOG_ROOT, SOLOMOG_LIB, SOLOMOG_PLUGIN_API,
# SOLOMOG_PLUGIN_DIR (the plugin's directory), and SOLOMOG_PLUGIN_DATA
# (.solomog/plugins/<name>, for caches and state). That env is the whole contract —
# a plugin that sources other scripts/lib files does so at its own risk.

SOLOMOG_PLUGIN_API=1

_PLUGINS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PLUGINS_ROOT="$(cd "$_PLUGINS_LIB/../.." && pwd)"

# Print each plugin directory, one per line (sorted, deduplicated).
solomog_plugin_dirs() {
  local roots="${SOLOMOG_PLUGINS_DIR:-$_PLUGINS_ROOT/plugins}" r
  [ -n "${SOLOMOG_PLUGIN_PATH:-}" ] && roots="$roots:$SOLOMOG_PLUGIN_PATH"
  local IFS=:
  for r in $roots; do
    [ -d "$r" ] || continue
    find "$r" -mindepth 1 -maxdepth 3 -name plugin.conf -not -path '*/.*' 2>/dev/null |
      while IFS= read -r f; do dirname "$f"; done
  done | sort -u
}

# solomog_plugin_conf <dir> <key> → value (empty when absent).
solomog_plugin_conf() {
  sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*//p" "$1/plugin.conf" 2>/dev/null |
    tail -n1 | sed 's/[[:space:]]*#.*$//; s/[[:space:]]*$//'
}

# solomog_plugin_find <command> → plugin directory that declares it (first match).
solomog_plugin_find() {
  local cmd="$1" d c
  case "$cmd" in
    ''|*[!a-z0-9-]*) return 1 ;;   # plain words only — never a namespaced task like eks:create
  esac
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    for c in $(solomog_plugin_conf "$d" commands); do
      if [ "$c" = "$cmd" ]; then
        printf '%s' "$d"
        return 0
      fi
    done
  done <<EOF
$(solomog_plugin_dirs)
EOF
  return 1
}

# solomog_plugin_problem <dir> [command] → why it cannot run (empty = runnable).
solomog_plugin_problem() {
  local d="$1" cmd="${2:-}" api c
  api="$(solomog_plugin_conf "$d" api)"
  if [ "$api" != "$SOLOMOG_PLUGIN_API" ]; then
    printf 'plugin API %s, solomog speaks %s' "${api:-unset}" "$SOLOMOG_PLUGIN_API"
    return 0
  fi
  for c in ${cmd:-$(solomog_plugin_conf "$d" commands)}; do
    if [ ! -x "$d/bin/solomog-$c" ]; then
      printf 'bin/solomog-%s missing or not executable' "$c"
      return 0
    fi
  done
}

# Core task names — a plugin never shadows one. Overridable for hermetic tests.
_solomog_plugin_core_tasks() {
  if [ -n "${SOLOMOG_PLUGIN_CORE_TASKS+x}" ]; then
    printf '%s\n' $SOLOMOG_PLUGIN_CORE_TASKS
    return 0
  fi
  (cd "$_PLUGINS_ROOT" && task --list-all --json 2>/dev/null) |
    jq -r '.tasks[] | .name, (.aliases // [])[]' 2>/dev/null
}

solomog_plugin_shadowed() {
  _solomog_plugin_core_tasks | grep -qx -- "$1"
}

# solomog_plugin_exec <command> [args…] — replaces the shell; returns only when
# <command> is not a runnable plugin command (the caller then carries on as usual).
solomog_plugin_exec() {
  local cmd="$1" d name problem
  d="$(solomog_plugin_find "$cmd")" || return 1
  name="$(solomog_plugin_conf "$d" name)"; name="${name:-$(basename "$d")}"
  if solomog_plugin_shadowed "$cmd"; then
    echo "solomog: plugin '$name' declares '$cmd', which is a core task — running the core task" >&2
    return 1
  fi
  problem="$(solomog_plugin_problem "$d" "$cmd")"
  if [ -n "$problem" ]; then
    echo "solomog: plugin '$name' cannot run: $problem ($d)" >&2
    echo "  Check all plugins:  solomog plugins doctor" >&2
    exit 1
  fi
  shift
  export SOLOMOG_ROOT="$_PLUGINS_ROOT" SOLOMOG_LIB="$_PLUGINS_LIB" SOLOMOG_PLUGIN_API
  export SOLOMOG_PLUGIN_DIR="$d" SOLOMOG_PLUGIN_DATA="$_PLUGINS_ROOT/.solomog/plugins/$name"
  exec "$d/bin/solomog-$cmd" "$@"
}

# ─── `solomog plugins [doctor [--test]]` ──────────────────────────────────────

_solomog_plugin_rev() {
  local rev dirty="" top
  top="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || { printf '-'; return 0; }
  # Not its own repo: git fell through to the solomog checkout, whose rev means nothing here.
  [ "$(cd "$top" && pwd -P)" = "$(cd "$_PLUGINS_ROOT" && pwd -P)" ] && { printf '-'; return 0; }
  rev="$(git -C "$1" rev-parse --short HEAD 2>/dev/null)" || { printf 'no-commits'; return 0; }
  [ -n "$(git -C "$1" status --porcelain -- . 2>/dev/null)" ] && dirty="+dirty"
  printf '%s%s' "$rev" "$dirty"
}

solomog_plugins_list() {
  local d name n=0 problem state
  printf '%-12s %-22s %-14s %-6s %s\n' PLUGIN COMMANDS REV HELP STATUS
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    n=$((n + 1))
    name="$(solomog_plugin_conf "$d" name)"; name="${name:-$(basename "$d")}"
    problem="$(solomog_plugin_problem "$d")"
    state="${problem:-ok}"
    printf '%-12s %-22s %-14s %-6s %s\n' "$name" "$(solomog_plugin_conf "$d" commands)" \
      "$(_solomog_plugin_rev "$d")" \
      "$([ "$(solomog_plugin_conf "$d" hidden)" = "true" ] && echo hidden || echo shown)" "$state"
    printf '%-12s %s\n' "" "$(solomog_plugin_conf "$d" description)"
    printf '%-12s %s\n' "" "$d"
  done <<EOF
$(solomog_plugin_dirs)
EOF
  if [ "$n" -eq 0 ]; then
    echo "(no plugins installed — clone a plugin repo into ${SOLOMOG_PLUGINS_DIR:-$_PLUGINS_ROOT/plugins}/)"
  fi
}

# Exit 1 when any plugin is broken, its doctor fails, or (with --test) its tests fail.
solomog_plugins_doctor() {
  local with_test="" d name problem doc tst c fails=0 out
  [ "${1:-}" = "--test" ] && with_test=1
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    name="$(solomog_plugin_conf "$d" name)"; name="${name:-$(basename "$d")}"
    problem="$(solomog_plugin_problem "$d")"
    if [ -n "$problem" ]; then
      echo "FAIL  $name: $problem"
      fails=$((fails + 1))
      continue
    fi
    for c in $(solomog_plugin_conf "$d" commands); do
      if solomog_plugin_shadowed "$c"; then
        echo "FAIL  $name: command '$c' is shadowed by a core task"
        fails=$((fails + 1))
      fi
    done
    doc="$(solomog_plugin_conf "$d" doctor)"
    if [ -n "$doc" ]; then
      # shellcheck disable=SC2086
      set -- $doc
      if out="$(SOLOMOG_ROOT="$_PLUGINS_ROOT" SOLOMOG_LIB="$_PLUGINS_LIB" SOLOMOG_PLUGIN_API="$SOLOMOG_PLUGIN_API" \
                SOLOMOG_PLUGIN_DIR="$d" SOLOMOG_PLUGIN_DATA="$_PLUGINS_ROOT/.solomog/plugins/$name" \
                NO_COLOR=1 "$d/bin/solomog-$1" "${@:2}" 2>&1)"; then
        echo "ok    $name: doctor"
      else
        echo "FAIL  $name: doctor"
        printf '%s\n' "$out" | sed 's/^/        /'
        fails=$((fails + 1))
      fi
    else
      echo "ok    $name (no doctor declared)"
    fi
    tst="$(solomog_plugin_conf "$d" test)"
    if [ -n "$with_test" ] && [ -n "$tst" ]; then
      if out="$(NO_COLOR=1 bash "$d/$tst" 2>&1)"; then
        echo "ok    $name: tests"
      else
        echo "FAIL  $name: tests"
        printf '%s\n' "$out" | grep -E 'FAIL|failed' | sed 's/^/        /'
        fails=$((fails + 1))
      fi
    fi
  done <<EOF
$(solomog_plugin_dirs)
EOF
  [ "$fails" -eq 0 ]
}

# For the help index: "<command>\t<description>" for each shown (non-hidden) command.
solomog_plugins_help_rows() {
  local d c
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    [ "$(solomog_plugin_conf "$d" hidden)" = "true" ] && continue
    for c in $(solomog_plugin_conf "$d" commands); do
      printf '%s\t%s\n' "$c" "$(solomog_plugin_conf "$d" description)"
    done
  done <<EOF
$(solomog_plugin_dirs)
EOF
}
