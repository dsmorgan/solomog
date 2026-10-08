# Live solomog runs — awareness only, never a lock.
#
# The wrapper writes one file per real command (the same commands that hit the
# audit log) at .solomog/runs/<pid>, and removes it on the way out. A second
# command prints the others and continues. `solomog clusters` prints them above
# the cluster table instead of that note: an eks:create is not in the table
# until eksctl returns and the context is registered.
#
# File (one record, pid is the filename):
#   start=<epoch>
#   tty=<ttysNNN or ??>
#   lstart=<ps lstart, to reject a recycled pid>
#   clusters=<space-separated CLUSTER/CLUSTERS names>
#   cmd=<redacted command line>
#
# Secret-looking values (the name matches KEY, TOKEN, SECRET, PASSWORD, or PASS)
# are redacted the same way as the audit log. Writing is best-effort: a failure
# here never fails the command. SOLOMOG_RUNS_DIR overrides the directory (tests).
# SOLOMOG_RUN_PID is the enclosing wrapper pid; scanners skip it so a run does
# not list itself.

_SOLOMOG_RUNS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

_solomog_runs_dir() {
  if [ -n "${SOLOMOG_RUNS_DIR:-}" ]; then
    printf '%s' "$SOLOMOG_RUNS_DIR"
  else
    printf '%s/.solomog/runs' "$_SOLOMOG_RUNS_ROOT"
  fi
}

# One argv word, with a secret-looking KEY=VALUE replaced by KEY=***.
solomog_run_redact_word() {
  local name
  case "${1:-}" in
    *=*)
      name="${1%%=*}"
      case "$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')" in
        *KEY*|*TOKEN*|*SECRET*|*PASSWORD*|*PASS*)
          printf '%s=***' "$name"
          return 0
          ;;
      esac
      ;;
  esac
  printf '%s' "${1:-}"
  return 0
}

# Join args with spaces, redacting secret-looking values.
solomog_run_redact_args() {
  local out="" a red
  for a in "$@"; do
    red="$(solomog_run_redact_word "$a")"
    out="${out:+$out }${red}"
  done
  printf '%s' "$out"
  return 0
}

# Space-separated cluster names from CLUSTER= / CLUSTERS= args, first-seen order.
solomog_run_clusters_from_args() {
  local a val w out="" seen=" "
  for a in "$@"; do
    case "$a" in
      CLUSTER=*|CLUSTERS=*)
        val="${a#*=}"
        val="${val#\"}"; val="${val%\"}"
        val="${val#\'}"; val="${val%\'}"
        # shellcheck disable=SC2086
        for w in $val; do
          case "$seen" in
            *" $w "*) ;;
            *)
              out="${out:+$out }$w"
              seen="${seen}${w} "
              ;;
          esac
        done
        ;;
    esac
  done
  printf '%s' "$out"
  return 0
}

# Names in $1 that also appear in $2. Order follows $1.
solomog_run_overlap() {
  local ours="${1:-}" theirs="${2:-}" name t out="" found
  # shellcheck disable=SC2086
  for name in $ours; do
    [ -n "$name" ] || continue
    found=0
    # shellcheck disable=SC2086
    for t in $theirs; do
      if [ "$t" = "$name" ]; then
        found=1
        break
      fi
    done
    if [ "$found" = 1 ]; then
      case " ${out} " in
        *" ${name} "*) ;;
        *) out="${out:+$out }${name}" ;;
      esac
    fi
  done
  printf '%s' "$out"
  return 0
}

# Whole seconds → 45s / 14m / 1h / 1h 5m. Bad input prints "?".
solomog_run_format_age() {
  local s="${1:-0}" mins
  case "$s" in
    ''|*[!0-9]*) printf '?' ; return 0 ;;
  esac
  if [ "$s" -ge 3600 ]; then
    mins=$(((s % 3600) / 60))
    if [ "$mins" -eq 0 ]; then
      printf '%dh' "$((s / 3600))"
    else
      printf '%dh %dm' "$((s / 3600))" "$mins"
    fi
  elif [ "$s" -ge 60 ]; then
    printf '%dm' "$((s / 60))"
  else
    printf '%ds' "$s"
  fi
  return 0
}

# True when every arg is a cluster:list alias, and there is at least one.
solomog_run_is_cluster_list() {
  local t
  [ "$#" -ge 1 ] || return 1
  for t in "$@"; do
    case "$t" in
      cluster:list|clusters:list|clusters|cluster) ;;
      *) return 1 ;;
    esac
  done
  return 0
}

_solomog_run_tty() {
  local tty
  tty="$(ps -p "$$" -o tty= 2>/dev/null)" || tty=""
  tty="$(printf '%s' "$tty" | tr -d '[:space:]')"
  case "$tty" in
    ''|'?') printf '??' ;;
    *) printf '%s' "$tty" ;;
  esac
}

_solomog_run_lstart() {
  local raw
  raw="$(ps -p "$1" -o lstart= 2>/dev/null)" || raw=""
  printf '%s' "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# kill -0 plus the recorded ps start time. A recycled pid fails the start-time
# check and the caller deletes the file. Empty recorded lstart falls back to
# "the command line still contains solomog".
_solomog_run_alive() {
  local pid="$1" want="${2:-}" got cmd
  kill -0 "$pid" 2>/dev/null || return 1
  if [ -z "$want" ]; then
    cmd="$(ps -p "$pid" -o command= 2>/dev/null)" || cmd=""
    case "$cmd" in
      *solomog*) return 0 ;;
      *) return 1 ;;
    esac
  fi
  got="$(_solomog_run_lstart "$pid")"
  # ps produced nothing; the pid is alive, so keep the record.
  [ -z "$got" ] && return 0
  [ "$got" = "$want" ]
}

_solomog_run_read() {
  _run_start=""
  _run_tty=""
  _run_lstart=""
  _run_clusters=""
  _run_cmd=""
  local line
  [ -r "${1:-}" ] || return 0
  while IFS= read -r line || [ -n "${line:-}" ]; do
    case "$line" in
      start=*) _run_start="${line#start=}" ;;
      tty=*) _run_tty="${line#tty=}" ;;
      lstart=*) _run_lstart="${line#lstart=}" ;;
      clusters=*) _run_clusters="${line#clusters=}" ;;
      cmd=*) _run_cmd="${line#cmd=}" ;;
    esac
  done < "$1"
  return 0
}

# Record this process. Best-effort: any failure returns 0 and the command proceeds.
solomog_run_begin() {
  local dir pid tty lstart clusters cmd tmp
  dir="$(_solomog_runs_dir)"
  mkdir -p "$dir" 2>/dev/null || return 0
  pid="$$"
  tty="$(_solomog_run_tty)"
  lstart="$(_solomog_run_lstart "$pid")"
  clusters="$(solomog_run_clusters_from_args "$@")"
  cmd="$(solomog_run_redact_args "$@")"
  cmd="$(printf '%s' "$cmd" | tr '\t\n\r' '   ')"
  tmp="$dir/.${pid}.tmp"
  if ! {
    printf 'start=%s\n' "$(date +%s)"
    printf 'tty=%s\n' "$tty"
    printf 'lstart=%s\n' "$lstart"
    printf 'clusters=%s\n' "$clusters"
    printf 'cmd=%s\n' "$cmd"
  } > "$tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 0
  fi
  if ! mv "$tmp" "$dir/$pid" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 0
  fi
  export SOLOMOG_RUN_PID="$pid"
  return 0
}

solomog_run_end() {
  local dir pid
  dir="$(_solomog_runs_dir)"
  pid="${SOLOMOG_RUN_PID:-$$}"
  rm -f "$dir/$pid" "$dir/.${pid}.tmp" 2>/dev/null || true
  return 0
}

# Drop the record on a normal exit and on the signals that stop a long create.
# end is idempotent, so a signal that also runs the EXIT trap deletes once.
solomog_run_arm_exit() {
  trap 'solomog_run_end; exit 130' INT
  trap 'solomog_run_end; exit 143' TERM
  trap 'solomog_run_end' EXIT
}

# Live runs except SOLOMOG_RUN_PID, oldest first.
# TSV: start, pid, tty, clusters, cmd. Stale files are removed.
solomog_run_scan() {
  local dir tmp f base pid
  dir="$(_solomog_runs_dir)"
  [ -d "$dir" ] || return 0
  tmp="$(mktemp "${TMPDIR:-/tmp}/solomog-runs.XXXXXX")" || return 0
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    case "$base" in
      *[!0-9]*) continue ;;
    esac
    pid="$base"
    if [ -n "${SOLOMOG_RUN_PID:-}" ] && [ "$pid" = "$SOLOMOG_RUN_PID" ]; then
      continue
    fi
    _solomog_run_read "$f"
    if ! _solomog_run_alive "$pid" "$_run_lstart"; then
      rm -f "$f" 2>/dev/null || true
      continue
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "${_run_start:-0}" "$pid" "${_run_tty:-??}" "${_run_clusters:-}" "${_run_cmd:-}" \
      >> "$tmp" || true
  done
  if [ -s "$tmp" ]; then
    sort -n -k1,1 "$tmp" || true
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 0
}

# Aligned "pid tty age command" lines. $1 is this command's cluster names;
# an overlap is appended as "same cluster: …". Empty when nothing else is running.
solomog_run_lines() {
  local mine="${1:-}"
  local raw start pid tty clusters cmd elapsed age hit suffix
  local pids=() ttys=() ages=() texts=()
  local w_pid w_tty w_age i n now s hold=""

  raw="$(solomog_run_scan)" || raw=""
  [ -n "$raw" ] || return 0
  now="$(date +%s)"
  # A heredoc would expand $ and backticks inside the command line. Read a
  # file instead so the recorded text stays literal.
  hold="$(mktemp "${TMPDIR:-/tmp}/solomog-runs.XXXXXX")" || return 0
  printf '%s\n\n' "$raw" > "$hold"
  while IFS="$(printf '\t')" read -r start pid tty clusters cmd; do
    [ -n "${pid:-}" ] || continue
    case "${start:-}" in
      ''|*[!0-9]*) age='?' ;;
      *)
        elapsed=$((now - start))
        [ "$elapsed" -lt 0 ] && elapsed=0
        age="$(solomog_run_format_age "$elapsed")"
        ;;
    esac
    hit="$(solomog_run_overlap "$mine" "${clusters:-}")"
    suffix=""
    [ -n "$hit" ] && suffix="  same cluster: ${hit}"
    pids[${#pids[@]}]="$pid"
    ttys[${#ttys[@]}]="${tty:-??}"
    ages[${#ages[@]}]="$age"
    texts[${#texts[@]}]="${cmd}${suffix}"
  done < "$hold"
  rm -f "$hold" 2>/dev/null || true
  n=${#pids[@]}
  [ "$n" -gt 0 ] || return 0
  w_pid=0; w_tty=0; w_age=0
  i=0
  while [ "$i" -lt "$n" ]; do
    s="${pids[$i]}"
    [ "${#s}" -gt "$w_pid" ] && w_pid=${#s}
    s="${ttys[$i]}"
    [ "${#s}" -gt "$w_tty" ] && w_tty=${#s}
    s="${ages[$i]}"
    [ "${#s}" -gt "$w_age" ] && w_age=${#s}
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt "$n" ]; do
    printf '  %-*s  %-*s  %-*s  %s\n' \
      "$w_pid" "${pids[$i]}" "$w_tty" "${ttys[$i]}" "$w_age" "${ages[$i]}" "${texts[$i]}"
    i=$((i + 1))
  done
  return 0
}

# Stderr note for a second command. $1 is this command's cluster names.
solomog_run_note() {
  local lines
  lines="$(solomog_run_lines "${1:-}")" || lines=""
  [ -n "$lines" ] || return 0
  printf 'Note: solomog is already running:\n%s\n' "$lines"
  return 0
}

# The block `solomog clusters` prints above the table. Omitted when empty.
solomog_run_section() {
  local lines
  lines="$(solomog_run_lines "")" || lines=""
  [ -n "$lines" ] || return 0
  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    printf '\033[1mRunning\033[0m\n%s\n\n' "$lines"
  else
    printf 'Running\n%s\n\n' "$lines"
  fi
  return 0
}
