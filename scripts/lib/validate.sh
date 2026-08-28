#!/usr/bin/env bash
# CLI preflight for the solomog wrapper — unknown tasks and unknown KEY= names.
# bash 3.2 compatible (macOS). Source from the wrapper; do not `set -e` here.
#
# Usage:
#   source "$REPO_DIR/scripts/lib/validate.sh"
#   # TASKS=() and VARS=() already set by the wrapper
#   solomog_validate_cli    # 0 = ok or skipped; 1 = print errors and caller exits
#
# Test hook: set _VALIDATE_FIXTURE=1 and populate _VALIDATE_NAMES / _VALIDATE_ALIASES
# / _VALIDATE_KEYS to skip `task --list` and file harvest.

_VALIDATE_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_VALIDATE_ROOT="${SOLOMOG_VALIDATE_ROOT:-$(cd "$_VALIDATE_LIB/../.." && pwd)}"

_VALIDATE_NAMES=()
_VALIDATE_ALIASES=()
_VALIDATE_KEYS=()

# Common Unix env names that can sit at edit distance 2 from a short solomog
# knob (HOME ~ HOST). Inherited-env typo scan never flags these.
_VALIDATE_ENV_SKIP='HOME PATH USER SHELL TERM LANG PWD OLDPWD SHLVL HOSTNAME HOST LOGNAME MAIL EDITOR VISUAL PAGER TMPDIR TMP TEMP DISPLAY USERNAME COMMAND_MODE'

_solomog_validate_truthy() {
  if command -v _solomog_truthy >/dev/null 2>&1; then
    _solomog_truthy "${1:-}"
    return $?
  fi
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

_solomog_validate_in_list() {
  local needle="$1" x
  shift
  for x in "$@"; do
    [ "$x" = "$needle" ] && return 0
  done
  return 1
}

_solomog_validate_is_task() {
  local t="$1"
  if [ ${#_VALIDATE_NAMES[@]} -gt 0 ] && _solomog_validate_in_list "$t" "${_VALIDATE_NAMES[@]}"; then
    return 0
  fi
  if [ ${#_VALIDATE_ALIASES[@]} -gt 0 ] && _solomog_validate_in_list "$t" "${_VALIDATE_ALIASES[@]}"; then
    return 0
  fi
  return 1
}

_solomog_validate_is_known_key() {
  local k="$1"
  [ ${#_VALIDATE_KEYS[@]} -gt 0 ] || return 1
  _solomog_validate_in_list "$k" "${_VALIDATE_KEYS[@]}"
}

# Candidates on stdin; prints up to three space-separated suggestions (or nothing).
# Prefix / leading-substring beats Levenshtein so `monitor` → `monitoring` (distance 3).
# Read stdin before $(awk) — bash command substitution can drop the caller's pipe.
_solomog_validate_suggest() {
  local needle="$1" cands out
  [ -n "$needle" ] || return 0
  cands="$(cat)"
  [ -n "$cands" ] || return 0
  out="$(
    printf '%s\n' "$cands" | awk -v needle="$needle" '
      function min3(a, b, c) {
        if (a <= b && a <= c) return a
        if (b <= a && b <= c) return b
        return c
      }
      function lev(s, t,    n, m, i, j, cost) {
        n = length(s); m = length(t)
        if (n == 0) return m
        if (m == 0) return n
        for (i = 0; i <= n; i++) d[i, 0] = i
        for (j = 0; j <= m; j++) d[0, j] = j
        for (i = 1; i <= n; i++) {
          for (j = 1; j <= m; j++) {
            cost = (substr(s, i, 1) == substr(t, j, 1)) ? 0 : 1
            d[i, j] = min3(d[i - 1, j] + 1, d[i, j - 1] + 1, d[i - 1, j - 1] + cost)
          }
        }
        return d[n, m]
      }
      {
        gsub(/\r/, "")
        cand = $0
        if (cand == "" || cand == needle) next
        score = 99
        if (index(cand, needle) == 1) score = 0
        else if (length(needle) >= 4 && index(needle, cand) == 1) score = 0
        else {
          dist = lev(needle, cand)
          if (dist <= 2) score = dist
        }
        if (score < 99) printf "%d %s\n", score, cand
      }
    ' | LC_ALL=C sort -n | awk '!seen[$2]++ { print $2; if (++n >= 3) exit }'
  )"
  out="$(printf '%s' "$out" | tr '\n' ' ')"
  out="${out%"${out##*[![:space:]]}"}"
  [ -n "$out" ] || return 0
  printf '  Did you mean: %s\n' "$out"
}

# ─── load tasks (task --list --json) ──────────────────────────────────────────

_solomog_validate_load_tasks() {
  local json name al
  json="$(task --list --json 2>/dev/null)" || return 1
  _VALIDATE_NAMES=()
  _VALIDATE_ALIASES=()
  while IFS=$'\t' read -r name al; do
    [ -n "$name" ] || continue
    [ "$name" = "default" ] && continue
    _VALIDATE_NAMES+=("$name")
    while [ -n "$al" ]; do
      case "$al" in
        *,*)
          [ -n "${al%%,*}" ] && _VALIDATE_ALIASES+=("${al%%,*}")
          al="${al#*,}"
          ;;
        *)
          _VALIDATE_ALIASES+=("$al")
          al=""
          ;;
      esac
    done
  done <<EOF
$(printf '%s' "$json" | jq -r '.tasks[] | [.name, (.aliases // [] | join(","))] | @tsv')
EOF
  [ ${#_VALIDATE_NAMES[@]} -gt 0 ]
}

# ─── harvest known KEY names ──────────────────────────────────────────────────

_solomog_validate_keys_from_envfile() {
  local file="$1" line key
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '#'*) line="${line#\#}" ;;
    esac
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in
      [A-Z]*=*)
        key="${line%%=*}"
        case "$key" in
          [A-Z][A-Z0-9_]*) printf '%s\n' "$key" ;;
        esac
        ;;
    esac
  done < "$file"
}

# Keys under task-level `env:` / `vars:` (and the root `vars:` block).
# Indent state machine — a plain YAML walk would also pick up summary prose.
_solomog_validate_keys_from_taskfile() {
  local file="$1" line trimmed indent key
  local in_block=0 block_indent=-1
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in
      ''|'#'*) continue ;;
    esac
    indent=$((${#line} - ${#trimmed}))
    case "$trimmed" in
      env:|vars:)
        in_block=1
        block_indent=$indent
        continue
        ;;
    esac
    if [ "$in_block" -eq 1 ]; then
      if [ "$indent" -le "$block_indent" ]; then
        in_block=0
        case "$trimmed" in
          env:|vars:)
            in_block=1
            block_indent=$indent
            continue
            ;;
        esac
      else
        case "$trimmed" in
          [A-Z]*:*)
            key="${trimmed%%:*}"
            case "$key" in
              [A-Z][A-Z0-9_]*) printf '%s\n' "$key" ;;
            esac
            ;;
        esac
        continue
      fi
    fi
  done < "$file"
}

_solomog_validate_load_keys() {
  local k
  _VALIDATE_KEYS=()
  while IFS= read -r k; do
    [ -n "$k" ] && _VALIDATE_KEYS+=("$k")
  done <<EOF
$(
  {
    _solomog_validate_keys_from_envfile "$_VALIDATE_ROOT/.env.example"
    _solomog_validate_keys_from_envfile "$_VALIDATE_ROOT/versions.env"
    _solomog_validate_keys_from_taskfile "$_VALIDATE_ROOT/Taskfile.yaml"
    _solomog_validate_keys_from_taskfile "$_VALIDATE_ROOT/taskfiles/vsphere.yaml"
    printf '%s\n' SOLOMOG_SERIOUS SOLOMOG_ALLOW_UNKNOWN_VARS NO_COLOR
  } | LC_ALL=C sort -u
)
EOF
  [ ${#_VALIDATE_KEYS[@]} -gt 0 ]
}

_solomog_validate_ensure_loaded() {
  if [ -n "${_VALIDATE_FIXTURE:-}" ]; then
    return 0
  fi
  _solomog_validate_load_tasks || return 1
  _solomog_validate_load_keys || return 1
}

# ─── escape hatch ─────────────────────────────────────────────────────────────

# Same three places as SOLOMOG_SERIOUS: prefix env, CLI KEY=, then .env.
_solomog_validate_allow_unknown_vars() {
  local v="${SOLOMOG_ALLOW_UNKNOWN_VARS:-}" item
  if [ -z "$v" ] && [ ${#VARS[@]} -gt 0 ]; then
    for item in "${VARS[@]}"; do
      case "$item" in
        SOLOMOG_ALLOW_UNKNOWN_VARS=*) v="${item#*=}" ;;
      esac
    done
  fi
  if [ -z "$v" ] && [ -f "$_VALIDATE_ROOT/.env" ]; then
    v="$(sed -n 's/^[[:space:]]*SOLOMOG_ALLOW_UNKNOWN_VARS[[:space:]]*=[[:space:]]*//p' "$_VALIDATE_ROOT/.env" | tail -n1)"
    v="${v%%#*}"
    v="${v%"${v##*[![:space:]]}"}"
    v="${v#\"}"; v="${v%\"}"
    v="${v#\'}"; v="${v%\'}"
  fi
  _solomog_validate_truthy "$v"
}

# ─── inherited-env close-miss (prefix FOO=bar solomog …) ───────────────────────

# One awk pass: keys, then `---`, then env names. Distance 1 always (len >= 4,
# |Δlen| <= 2). Distance 2 only when the env name is long enough that HOME~HOST
# cannot match. Prefix-only matches are ignored here — those would flag TOKEN
# against TOKEN_EXCHANGE. Prints `name<TAB>guess` lines.
_solomog_validate_inherited_typos() {
  local skip=" $_VALIDATE_ENV_SKIP " already="$1" name
  [ ${#_VALIDATE_KEYS[@]} -gt 0 ] || return 0
  {
    printf '%s\n' "${_VALIDATE_KEYS[@]}"
    printf '%s\n' '---'
    if compgen -e >/dev/null 2>&1; then
      compgen -e
    else
      env | awk -F= '{ print $1 }'
    fi
  } | awk -v skip="$skip" -v already="$already" '
    function min3(a, b, c) {
      if (a <= b && a <= c) return a
      if (b <= a && b <= c) return b
      return c
    }
    function lev(s, t,    n, m, i, j, cost) {
      n = length(s); m = length(t)
      if (n == 0) return m
      if (m == 0) return n
      delete d
      for (i = 0; i <= n; i++) d[i, 0] = i
      for (j = 0; j <= m; j++) d[0, j] = j
      for (i = 1; i <= n; i++) {
        for (j = 1; j <= m; j++) {
          cost = (substr(s, i, 1) == substr(t, j, 1)) ? 0 : 1
          d[i, j] = min3(d[i - 1, j] + 1, d[i, j - 1] + 1, d[i - 1, j - 1] + cost)
        }
      }
      return d[n, m]
    }
    $0 == "---" { mid = 1; next }
    !mid { known[$0] = 1; keys[++nk] = $0; next }
    {
      name = $0
      if (name == "" || name in known) next
      if (index(skip, " " name " ")) next
      if (index(already, " " name " ")) next
      nlen = length(name)
      if (nlen < 4) next
      bestd = 99; best = ""
      for (i = 1; i <= nk; i++) {
        cand = keys[i]
        clen = length(cand)
        ndelta = nlen - clen
        if (ndelta < 0) ndelta = -ndelta
        if (ndelta > 2) continue
        dist = lev(name, cand)
        if (dist < bestd) { bestd = dist; best = cand }
      }
      if (bestd == 1 || (bestd == 2 && nlen >= 8)) printf "%s\t%s\n", name, best
    }
  '
}

# ─── public entry ─────────────────────────────────────────────────────────────

# Uses TASKS / VARS from the wrapper. Prints every problem, then returns 1 if
# the run must stop. Unknown tasks always fail; unknown KEY names fail unless
# SOLOMOG_ALLOW_UNKNOWN_VARS is truthy (then they warn). A load failure skips
# the whole preflight (do not make a broken task/jq worse than today).
solomog_validate_cli() {
  local t item name key allow=0 problems=0
  local reported="" guess

  if [ ${#TASKS[@]} -eq 0 ] && [ ${#VARS[@]} -eq 0 ]; then
    return 0
  fi

  _solomog_validate_ensure_loaded || return 0

  if _solomog_validate_allow_unknown_vars; then
    allow=1
  fi

  if [ ${#TASKS[@]} -gt 0 ]; then
    for t in "${TASKS[@]}"; do
      if _solomog_validate_is_task "$t"; then
        continue
      fi
      problems=$((problems + 1))
      echo "solomog: unknown task '$t'" >&2
      {
        [ ${#_VALIDATE_NAMES[@]} -gt 0 ] && printf '%s\n' "${_VALIDATE_NAMES[@]}"
        [ ${#_VALIDATE_ALIASES[@]} -gt 0 ] && printf '%s\n' "${_VALIDATE_ALIASES[@]}"
      } | _solomog_validate_suggest "$t" >&2
      echo "  Tasks: solomog help --all" >&2
    done
  fi

  if [ ${#VARS[@]} -gt 0 ]; then
    for item in "${VARS[@]}"; do
      key="${item%%=*}"
      if _solomog_validate_is_known_key "$key"; then
        continue
      fi
      reported="${reported} ${key} "
      if [ "$allow" -eq 1 ]; then
        echo "Warning: unknown variable '$key'" >&2
      else
        echo "solomog: unknown variable '$key'" >&2
        problems=$((problems + 1))
      fi
      [ ${#_VALIDATE_KEYS[@]} -gt 0 ] && printf '%s\n' "${_VALIDATE_KEYS[@]}" | _solomog_validate_suggest "$key" >&2
      if [ "$allow" -eq 1 ]; then
        echo "  proceeding because SOLOMOG_ALLOW_UNKNOWN_VARS is set" >&2
      fi
    done
  fi

  # Prefix-exported typos (FOO=bar solomog …) never land in VARS.
  while IFS=$'\t' read -r name guess; do
    [ -n "$name" ] || continue
    reported="${reported} ${name} "
    if [ "$allow" -eq 1 ]; then
      echo "Warning: environment variable '$name' looks like a typo" >&2
    else
      echo "solomog: environment variable '$name' looks like a typo" >&2
      problems=$((problems + 1))
    fi
    echo "  Did you mean: $guess" >&2
    if [ "$allow" -eq 1 ]; then
      echo "  proceeding because SOLOMOG_ALLOW_UNKNOWN_VARS is set" >&2
    fi
  done <<EOF
$(_solomog_validate_inherited_typos "$reported")
EOF

  [ "$problems" -eq 0 ]
}
