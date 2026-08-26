#!/usr/bin/env bash
# Grouped CLI help for solomog — index, group pages, prefix pages, --all.
# bash 3.2 compatible (macOS). Source from scripts/list.sh and the solomog wrapper.
#
# Usage:
#   source "$REPO_DIR/scripts/lib/help.sh"
#   solomog_help_index                 # bare `solomog` / `solomog help`
#   solomog_help_dispatch <topic...>   # `solomog help <group|task|--all>`
#
# Catalog: scripts/help-catalog.txt (TAB-separated). Membership is prefix-plus-map
# so a new apps:foo lands in `apps` with no catalog edit. Do not `set -e` here —
# the wrapper that sources this file does not run under errexit.

_HELP_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_HELP_ROOT="$(cd "$_HELP_LIB/../.." && pwd)"
_HELP_CATALOG="${SOLOMOG_HELP_CATALOG:-$_HELP_ROOT/scripts/help-catalog.txt}"

_HELP_LOADED=""

# ─── colours (TTY only; same contract as the old list.sh) ─────────────────────

_solomog_help_colors() {
  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    HELP_G=$'\033[32m'
    HELP_B=$'\033[1m'
    HELP_R=$'\033[0m'
  else
    HELP_G=''; HELP_B=''; HELP_R=''
  fi
}

# ─── load catalog + task --list ───────────────────────────────────────────────

_solomog_help_load() {
  [ -n "$_HELP_LOADED" ] && return 0
  _HELP_GROUP_NAMES=(); _HELP_GROUP_BLURBS=(); _HELP_GROUP_TITLES=()
  _HELP_ALIAS_FROM=(); _HELP_ALIAS_TO=()
  _HELP_PREFIX_K=(); _HELP_PREFIX_G=()
  _HELP_LEAD_G=(); _HELP_LEAD_T=()
  _HELP_SEE_G=(); _HELP_SEE_L=()
  _HELP_PTITLE_K=(); _HELP_PTITLE_V=()
  _HELP_NAMES=(); _HELP_DESCS=(); _HELP_ALIASES=()

  [ -f "$_HELP_CATALOG" ] || {
    echo "solomog: help catalog missing: $_HELP_CATALOG" >&2
    return 1
  }

  local kind a b c rest
  # IFS= read keeps TABs; comments and blanks skipped.
  while IFS= read -r rest || [ -n "$rest" ]; do
    case "$rest" in
      ''|'#'*) continue ;;
    esac
    IFS=$'\t' read -r kind a b c <<EOF
$rest
EOF
    case "$kind" in
      group)
        _HELP_GROUP_NAMES+=("$a")
        _HELP_GROUP_BLURBS+=("$b")
        _HELP_GROUP_TITLES+=("$c")
        ;;
      alias)  _HELP_ALIAS_FROM+=("$a"); _HELP_ALIAS_TO+=("$b") ;;
      prefix) _HELP_PREFIX_K+=("$a");   _HELP_PREFIX_G+=("$b") ;;
      lead)   _HELP_LEAD_G+=("$a");     _HELP_LEAD_T+=("$b") ;;
      see)    _HELP_SEE_G+=("$a");      _HELP_SEE_L+=("$b") ;;
      ptitle) _HELP_PTITLE_K+=("$a");   _HELP_PTITLE_V+=("$b") ;;
    esac
  done < "$_HELP_CATALOG"

  local json name desc al
  json="$(task --list --json 2>/dev/null)" || {
    echo "solomog: could not list tasks (is go-task installed?)" >&2
    return 1
  }
  while IFS=$'\t' read -r name desc al; do
    [ "$name" = "default" ] && continue
    _HELP_NAMES+=("$name")
    _HELP_DESCS+=("$desc")
    _HELP_ALIASES+=("$al")
  done <<EOF
$(printf '%s' "$json" | jq -r '.tasks[] | [.name, .desc, (.aliases // [] | join(","))] | @tsv')
EOF

  _HELP_LOADED=1
}

_solomog_help_lookup() {   # args: needle  arr_keys_name  arr_vals_name → print val
  local needle="$1" i=0
  eval "local n=\${#$2[@]}"
  while [ "$i" -lt "$n" ]; do
    eval "local k=\${$2[$i]}"
    if [ "$k" = "$needle" ]; then
      eval "printf '%s' \"\${$3[$i]}\""
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

solomog_help_group_of() {   # args: <task> → group name (empty if unmapped)
  local name="$1" key
  case "$name" in
    *:*) key="${name%%:*}" ;;
    *)   key="$name" ;;
  esac
  _solomog_help_lookup "$key" _HELP_PREFIX_K _HELP_PREFIX_G || true
}

solomog_help_is_group() {
  local t="$1"
  _solomog_help_lookup "$t" _HELP_GROUP_NAMES _HELP_GROUP_NAMES >/dev/null && return 0
  _solomog_help_lookup "$t" _HELP_ALIAS_FROM _HELP_ALIAS_TO >/dev/null && return 0
  return 1
}

solomog_help_resolve_group() {
  local t="$1" g
  g="$(_solomog_help_lookup "$t" _HELP_ALIAS_FROM _HELP_ALIAS_TO)" && {
    printf '%s' "$g"
    return 0
  }
  printf '%s' "$t"
}

_solomog_help_desc() {
  _solomog_help_lookup "$1" _HELP_NAMES _HELP_DESCS || true
}

_solomog_help_is_lead() {
  local g="$1" name="$2" i=0
  while [ "$i" -lt ${#_HELP_LEAD_G[@]} ]; do
    [ "${_HELP_LEAD_G[$i]}" = "$g" ] && [ "${_HELP_LEAD_T[$i]}" = "$name" ] && return 0
    i=$((i + 1))
  done
  return 1
}

# Print a group's tasks: lead list first (catalog order), then the rest A-Z.
_solomog_help_ordered_members() {
  local g="$1" i=0 name
  while [ "$i" -lt ${#_HELP_LEAD_G[@]} ]; do
    if [ "${_HELP_LEAD_G[$i]}" = "$g" ]; then
      name="${_HELP_LEAD_T[$i]}"
      if [ "$(solomog_help_group_of "$name")" = "$g" ] && _solomog_help_lookup "$name" _HELP_NAMES _HELP_NAMES >/dev/null; then
        printf '%s\n' "$name"
      fi
    fi
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt ${#_HELP_NAMES[@]} ]; do
    name="${_HELP_NAMES[$i]}"
    if [ "$(solomog_help_group_of "$name")" = "$g" ] && ! _solomog_help_is_lead "$g" "$name"; then
      printf '%s\n' "$name"
    fi
    i=$((i + 1))
  done | LC_ALL=C sort
}

_solomog_help_prefix_members() {
  local p="$1" i=0 name
  while [ "$i" -lt ${#_HELP_NAMES[@]} ]; do
    name="${_HELP_NAMES[$i]}"
    case "$name" in
      "$p"|"$p":*) printf '%s\n' "$name" ;;
    esac
    i=$((i + 1))
  done | LC_ALL=C sort
}

_solomog_help_cols() {
  local c="${COLUMNS:-}"
  if [ -z "$c" ] || [ "$c" -lt 40 ] 2>/dev/null; then
    c="$(tput cols 2>/dev/null)" || c=80
  fi
  [ "$c" -gt 0 ] 2>/dev/null || c=80
  printf '%s' "$c"
}

# Print aligned "  name  desc" rows. Names in green+bold when colour is on.
# Clip the description so an 80-col window never wraps a row.
_solomog_help_print_rows() {
  local w=0 name desc avail clip cols
  for name in "$@"; do
    [ ${#name} -gt "$w" ] && w=${#name}
  done
  [ "$w" -gt 32 ] && w=32
  cols="$(_solomog_help_cols)"
  avail=$((cols - 2 - w - 2))
  [ "$avail" -lt 20 ] && avail=20
  for name in "$@"; do
    desc="$(_solomog_help_desc "$name")"
    if [ ${#desc} -gt "$avail" ]; then
      clip=$((avail - 3))
      [ "$clip" -lt 1 ] && clip=1
      desc="${desc:0:$clip}..."
    fi
    printf "  %s%-*s%s  %s\n" "$HELP_G$HELP_B" "$w" "$name" "$HELP_R" "$desc"
  done
}

# bash 3.2: ${var:0:n} exists. Good.

# ─── pages ────────────────────────────────────────────────────────────────────

solomog_help_index() {
  _solomog_help_load || return 1
  _solomog_help_colors
  local i=0

  printf '%s%s%s\n' "$HELP_B" "solomog — Solo.io product labs (vind / EKS / vSphere)" "$HELP_R"
  printf '\n'
  printf '  solomog <task> [KEY=value ...]\n'
  printf '  solomog help <group|task>     details\n'
  printf '  solomog help --all            every task, grouped\n'
  printf '\n'
  printf '%sStart here%s\n' "$HELP_B" "$HELP_R"
  printf "  %s%-12s%s  install products onto a cluster\n" "$HELP_G$HELP_B" "stack" "$HELP_R"
  printf "  %s%-12s%s  Gateway + TLS + hostname\n" "$HELP_G$HELP_B" "expose" "$HELP_R"
  printf "  %s%-12s%s  custom config bundle\n" "$HELP_G$HELP_B" "apply" "$HELP_R"
  printf "  %s%-12s%s  destroy named clusters\n" "$HELP_G$HELP_B" "teardown" "$HELP_R"
  printf '\n'
  printf '%sGroups%s                             solomog help <group>\n' "$HELP_B" "$HELP_R"
  while [ "$i" -lt ${#_HELP_GROUP_NAMES[@]} ]; do
    printf "  %s%-10s%s  %s\n" "$HELP_G$HELP_B" "${_HELP_GROUP_NAMES[$i]}" "$HELP_R" "${_HELP_GROUP_BLURBS[$i]}"
    i=$((i + 1))
  done
}

solomog_help_group() {
  local g="$1" title members i=0 line
  _solomog_help_load || return 1
  _solomog_help_colors
  title="$(_solomog_help_lookup "$g" _HELP_GROUP_NAMES _HELP_GROUP_TITLES)" || title="$g"
  printf '%s%s%s\n\n' "$HELP_B" "$title" "$HELP_R"
  members="$(_solomog_help_ordered_members "$g")"
  if [ -z "$members" ]; then
    printf '  (no tasks in this group)\n'
  else
    # shellcheck disable=SC2086
    set -- $members
    _solomog_help_print_rows "$@"
  fi
  printf '\n'
  while [ "$i" -lt ${#_HELP_SEE_G[@]} ]; do
    [ "${_HELP_SEE_G[$i]}" = "$g" ] && printf '%s\n' "${_HELP_SEE_L[$i]}"
    i=$((i + 1))
  done
  printf 'Task details:     solomog help <task>\n'
}

solomog_help_prefix() {
  local p="$1" title members parent
  _solomog_help_load || return 1
  _solomog_help_colors
  title="$(_solomog_help_lookup "$p" _HELP_PTITLE_K _HELP_PTITLE_V)" || title="$p — matching $p:*"
  printf '%s%s%s\n\n' "$HELP_B" "$title" "$HELP_R"
  members="$(_solomog_help_prefix_members "$p")"
  if [ -z "$members" ]; then
    printf '  (no tasks)\n'
  else
    # shellcheck disable=SC2086
    set -- $members
    _solomog_help_print_rows "$@"
  fi
  printf '\n'
  printf 'Task details:     solomog help <task>\n'
  parent="$(solomog_help_group_of "$p")"
  [ -z "$parent" ] && parent="$(solomog_help_group_of "${p}:x")"
  if [ -n "$parent" ] && [ "$parent" != "$p" ]; then
    printf 'See also:         solomog help %s\n' "$parent"
  fi
}

solomog_help_all() {
  local i=0 g members name unassigned=""
  _solomog_help_load || return 1
  _solomog_help_colors
  while [ "$i" -lt ${#_HELP_GROUP_NAMES[@]} ]; do
    g="${_HELP_GROUP_NAMES[$i]}"
    [ "$i" -gt 0 ] && printf '\n'
    printf '%s%s%s\n\n' "$HELP_B" "${_HELP_GROUP_TITLES[$i]}" "$HELP_R"
    members="$(_solomog_help_ordered_members "$g")"
    if [ -n "$members" ]; then
      # shellcheck disable=SC2086
      set -- $members
      _solomog_help_print_rows "$@"
    fi
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt ${#_HELP_NAMES[@]} ]; do
    name="${_HELP_NAMES[$i]}"
    [ -z "$(solomog_help_group_of "$name")" ] && unassigned="$unassigned$name"$'\n'
    i=$((i + 1))
  done
  if [ -n "$unassigned" ]; then
    printf '\n%sOther%s\n\n' "$HELP_B" "$HELP_R"
    # shellcheck disable=SC2086
    set -- $unassigned
    _solomog_help_print_rows "$@"
  fi
}

# `task --summary` appends resolved vars:/env: (license keys, tokens). Strip that
# trailer; summaries use "Variables:" so this cannot clip real help content.
_solomog_help_filter_summary() {
  awk '
    /^(vars|env):/ { skip=1; next }
    /^task:/       { skip=0; print; next }
    !skip          { print }'
}

solomog_help_task_summary() {
  local out rc
  out="$(task --summary "$@" 2>&1)"
  rc=$?
  printf '%s\n' "$out" | _solomog_help_filter_summary
  [ "$rc" -eq 0 ] || return "$rc"
  _solomog_help_related "$1"
}

_solomog_help_related() {
  local topic="$1" pre siblings="" i=0 name
  _solomog_help_load || return 0
  case "$topic" in
    *:*) pre="${topic%%:*}" ;;
    *)   pre="$topic" ;;
  esac
  # Group footer even when there is no other `pre:*` sibling (setup:sudo → setup).
  if solomog_help_is_group "$pre" && [ "$pre" != "$topic" ]; then
    printf '\nRelated: solomog help %s\n' "$pre"
    return 0
  fi
  while [ "$i" -lt ${#_HELP_NAMES[@]} ]; do
    name="${_HELP_NAMES[$i]}"
    case "$name" in
      "$pre":*)
        [ "$name" != "$topic" ] && siblings="${siblings:+$siblings }$name"
        ;;
    esac
    i=$((i + 1))
  done
  [ -n "$siblings" ] || return 0
  printf '\nRelated: %s\n' "$siblings"
}

solomog_help_unknown() {
  local t="$1" names="" i=0
  _solomog_help_load || true
  while [ "$i" -lt ${#_HELP_GROUP_NAMES[@]} ]; do
    names="${names:+$names }${_HELP_GROUP_NAMES[$i]}"
    i=$((i + 1))
  done
  echo "solomog: unknown help topic '$t'" >&2
  echo "Groups:       $names" >&2
  echo "Full catalog: solomog help --all" >&2
  echo "Task details: solomog help <task>" >&2
  return 1
}

# True when `topic` is a real go-task name or alias (cluster, delete, …).
_solomog_help_is_task() {
  local t="$1" i=0 al
  while [ "$i" -lt ${#_HELP_NAMES[@]} ]; do
    [ "${_HELP_NAMES[$i]}" = "$t" ] && return 0
    al="${_HELP_ALIASES[$i]}"
    while [ -n "$al" ]; do
      case "$al" in
        *,*)
          [ "${al%%,*}" = "$t" ] && return 0
          al="${al#*,}"
          ;;
        *)
          [ "$al" = "$t" ] && return 0
          al=""
          ;;
      esac
    done
    i=$((i + 1))
  done
  return 1
}

solomog_help_dispatch() {
  local topic="$1" members
  [ -n "$topic" ] || { solomog_help_index; return 0; }
  case "$topic" in
    --all|-a|all)
      solomog_help_all
      return 0
      ;;
  esac
  _solomog_help_load || return 1
  if solomog_help_is_group "$topic"; then
    solomog_help_group "$(solomog_help_resolve_group "$topic")"
    return 0
  fi
  if _solomog_help_is_task "$topic"; then
    solomog_help_task_summary "$@"
    return $?
  fi
  members="$(_solomog_help_prefix_members "$topic")"
  if [ -n "$members" ]; then
    solomog_help_prefix "$topic"
    return 0
  fi
  solomog_help_unknown "$topic"
}
