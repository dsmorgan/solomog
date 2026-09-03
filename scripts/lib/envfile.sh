#!/usr/bin/env bash
# Shared .env helpers — backup, in-place set, sync-from-.env.example, diff.
# bash 3.2 compatible (macOS). Source from scripts that mutate .env.
#
# Usage:
#   source "$REPO_DIR/scripts/lib/envfile.sh"
#   envfile_backup                          # → .solomog/env-backups/<ts>.env
#   envfile_set KEY VALUE                   # in-place; preserves trailing comments
#   envfile_sync                            # rebuild .env from .env.example + overlay
#   envfile_diff                            # structural drift (no secret values)
#
# Design notes:
#   - .env.example is the canonical layout (sections + comments).
#   - Filter/rebuild (not sed s///) so values with /,+,=,#, etc. can't break rewrites.
#   - Empty values next to a trailing comment MUST be written as KEY=""  # comment
#     (go-task dotenv gotcha — see CLAUDE.md).
#   - CLI-only flags (TOKEN_EXCHANGE, OAUTH_ISSUER) are never written by sync.

# Keep this many timestamped backups under .solomog/env-backups/.
ENVFILE_BACKUP_KEEP="${ENVFILE_BACKUP_KEEP:-20}"

# Keys that must never persist via sync (CLI-only; see .env.example / Taskfile).
_ENVFILE_CLI_ONLY='TOKEN_EXCHANGE OAUTH_ISSUER'

_envfile_repo_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

_envfile_path() {
  printf '%s/.env' "$(_envfile_repo_dir)"
}

_envfile_example_path() {
  printf '%s/.env.example' "$(_envfile_repo_dir)"
}

_envfile_backup_dir() {
  printf '%s/.solomog/env-backups' "$(_envfile_repo_dir)"
}

# True if KEY is a CLI-only flag that must not be written into .env.
_envfile_is_cli_only() {
  local k="$1" x
  for x in $_ENVFILE_CLI_ONLY; do
    [ "$x" = "$k" ] && return 0
  done
  return 1
}

# Parse an assignment line into: _ef_key, _ef_raw_rhs (everything after first =).
# Returns 1 if the line is not KEY=VALUE.
_envfile_parse_key() {
  _ef_key=''
  _ef_raw_rhs=''
  case "$1" in
    ''|\#*) return 1 ;;
  esac
  # Must start with a valid env-var name then =
  case "$1" in
    [A-Za-z_]*) ;;
    *) return 1 ;;
  esac
  local line="$1" key rest
  key="${line%%=*}"
  # Reject if no = or key has whitespace / invalid chars
  [ "$key" = "$line" ] && return 1
  case "$key" in
    *[!A-Za-z0-9_]*|'') return 1 ;;
  esac
  rest="${line#*=}"
  _ef_key="$key"
  _ef_raw_rhs="$rest"
  return 0
}

# Split _ef_raw_rhs into _ef_value (unquoted) and _ef_comment (incl. leading spaces + #…, or '').
# Handles double/single quotes; trailing `  # comment` only outside quotes.
_envfile_split_rhs() {
  local rhs="${1-}"
  _ef_value=''
  _ef_comment=''
  _ef_was_quoted=0

  [ -z "$rhs" ] && return 0

  local i=0 len=${#rhs} c quote='' val='' first
  first="${rhs:0:1}"

  # Quoted value: consume until closing quote, remainder is the comment field.
  if [ "$first" = '"' ] || [ "$first" = "'" ]; then
    quote="$first"
    _ef_was_quoted=1
    i=1
    while [ "$i" -lt "$len" ]; do
      c="${rhs:$i:1}"
      if [ "$c" = '\' ] && [ "$quote" = '"' ] && [ "$((i+1))" -lt "$len" ]; then
        local n="${rhs:$((i+1)):1}"
        case "$n" in
          n) val="${val}"$'\n'; i=$((i+2)); continue ;;
          t) val="${val}"$'\t'; i=$((i+2)); continue ;;
          \\|\"|\$|\`) val="${val}${n}"; i=$((i+2)); continue ;;
        esac
      fi
      if [ "$c" = "$quote" ]; then
        i=$((i+1))
        break
      fi
      val="${val}${c}"
      i=$((i+1))
    done
    _ef_value="$val"
    _ef_comment="${rhs:$i}"
    return 0
  fi

  # Unquoted: value runs until whitespace+# (go-task trailing-comment form), or end.
  local comment_at=-1 prev
  i=0
  while [ "$i" -lt "$len" ]; do
    c="${rhs:$i:1}"
    if [ "$c" = '#' ] && [ "$i" -gt 0 ]; then
      prev="${rhs:$((i-1)):1}"
      case "$prev" in
        [[:space:]])
          # Walk back to the first whitespace of the run before #
          comment_at=$((i-1))
          while [ "$comment_at" -gt 0 ]; do
            prev="${rhs:$((comment_at-1)):1}"
            case "$prev" in
              [[:space:]]) comment_at=$((comment_at-1)) ;;
              *) break ;;
            esac
          done
          break
          ;;
      esac
    fi
    i=$((i+1))
  done

  if [ "$comment_at" -ge 0 ]; then
    _ef_value="${rhs:0:$comment_at}"
    _ef_comment="${rhs:$comment_at}"
  else
    _ef_value="$rhs"
    _ef_comment=''
  fi
}

# True when VALUE must be double-quoted in a dotenv assignment.
_envfile_needs_quotes() {
  local value="$1"
  [ -z "$value" ] && return 0
  case "$value" in
    *[[:space:]]*|*'#'*|*\"*|*"'"*|*'\'*) return 0 ;;
  esac
  # $ and ` — detect without ansi-C quoting pitfalls in case patterns
  printf '%s' "$value" | grep -q '[$`]' && return 0
  return 1
}

# Format KEY=VALUE [comment] for writing. Empty + comment → KEY=""  # …
_envfile_format_assignment() {
  local key="$1" value="$2" comment="${3-}"
  local rendered

  if [ -z "$value" ]; then
    # Always quote empties so a trailing comment can't become the value (dotenv gotcha).
    rendered="${key}=\"\""
  elif _envfile_needs_quotes "$value"; then
    local esc="$value"
    esc="${esc//\\/\\\\}"
    esc="${esc//\"/\\\"}"
    esc="${esc//\$/\\\$}"
    esc="${esc//\`/\\\`}"
    rendered="${key}=\"${esc}\""
  else
    rendered="${key}=${value}"
  fi

  if [ -n "$comment" ]; then
    # comment already includes leading whitespace + #…
    printf '%s%s\n' "$rendered" "$comment"
  else
    printf '%s\n' "$rendered"
  fi
}

# Look up KEY's unquoted value in file. Echoes value; returns 1 if missing.
# Sets _ef_found=1/0. Does not print a trailing newline in the value (printf).
envfile_get() {
  local file="$1" key="$2" line
  _ef_found=0
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    _envfile_parse_key "$line" || continue
    [ "$_ef_key" = "$key" ] || continue
    _envfile_split_rhs "$_ef_raw_rhs"
    _ef_found=1
    printf '%s' "$_ef_value"
    return 0
  done < "$file"
  return 1
}

# True if KEY= appears in file.
envfile_has() {
  local file="$1" key="$2" line
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    _envfile_parse_key "$line" || continue
    [ "$_ef_key" = "$key" ] && return 0
  done < "$file"
  return 1
}

# Copy .env → .solomog/env-backups/<timestamp>.env (mode 600). Prune to ENVFILE_BACKUP_KEEP.
# Echoes the backup path. No-op (return 1) if .env is missing.
envfile_backup() {
  local file="${1:-$(_envfile_path)}"
  local bdir stamp dest
  if [ ! -f "$file" ]; then
    echo "envfile_backup: $file not found" >&2
    return 1
  fi
  bdir="$(_envfile_backup_dir)"
  mkdir -p "$bdir"
  stamp="$(date +%Y%m%d-%H%M%S)"
  dest="${bdir}/${stamp}.env"
  # Collision: append a counter
  local n=1
  while [ -e "$dest" ]; do
    dest="${bdir}/${stamp}-${n}.env"
    n=$((n+1))
  done
  cp "$file" "$dest"
  chmod 600 "$dest"

  # Prune oldest beyond keep count (newest first via ls -t).
  local keep="${ENVFILE_BACKUP_KEEP:-20}" count=0 f
  # shellcheck disable=SC2012
  for f in $(ls -t "$bdir"/*.env 2>/dev/null); do
    count=$((count+1))
    if [ "$count" -gt "$keep" ]; then
      rm -f "$f"
    fi
  done

  printf '%s\n' "$dest"
}

# In-place update of KEY=VALUE, preserving trailing comment and file order.
# Atomic temp+mv. Errors if KEY is missing (run env:sync first) or CLI-only.
envfile_set() {
  local file="${ENVFILE:-$(_envfile_path)}"
  local key value
  # Allow: envfile_set FILE KEY VALUE  OR  envfile_set KEY VALUE (uses ENVFILE / default)
  if [ "$#" -eq 3 ]; then
    file="$1"; key="$2"; value="$3"
  elif [ "$#" -eq 2 ]; then
    key="$1"; value="$2"
  else
    echo "Usage: envfile_set [file] KEY VALUE" >&2
    return 2
  fi

  if _envfile_is_cli_only "$key"; then
    echo "envfile_set: refusing to write CLI-only key $key (pass it on the command line)" >&2
    return 1
  fi
  if [ ! -f "$file" ]; then
    echo "envfile_set: $file not found — copy .env.example to .env first (or run solomog env:sync)" >&2
    return 1
  fi
  if ! envfile_has "$file" "$key"; then
    echo "envfile_set: $key not found in $file — run: solomog env:sync" >&2
    return 1
  fi

  local tmp line
  tmp="$(mktemp "${file}.XXXXXX")"
  chmod 600 "$tmp"

  while IFS= read -r line || [ -n "$line" ]; do
    if _envfile_parse_key "$line" && [ "$_ef_key" = "$key" ]; then
      _envfile_split_rhs "$_ef_raw_rhs"
      _envfile_format_assignment "$key" "$value" "$_ef_comment" >> "$tmp"
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$file"

  mv "$tmp" "$file"
}

# Rebuild .env from .env.example structure, overlaying values from the live .env.
# Orphan keys (in .env but not example) go under a Local-only section (CLI-only skipped).
# Backs up first when a live .env exists.
envfile_sync() {
  local example="${1:-$(_envfile_example_path)}"
  local file="${2:-$(_envfile_path)}"
  local live_values new_count overlay_count orphan_count skipped_cli
  new_count=0; overlay_count=0; orphan_count=0; skipped_cli=0

  if [ ! -f "$example" ]; then
    echo "envfile_sync: $example not found" >&2
    return 1
  fi

  # Snapshot live values into a temp dir (one file per key) — bash 3.2 has no assoc arrays.
  live_values="$(mktemp -d "${TMPDIR:-/tmp}/envfile-vals.XXXXXX")"
  # Track which live keys were consumed (touched files under live_values).
  if [ -f "$file" ]; then
    envfile_backup "$file" >/dev/null
    local line
    while IFS= read -r line || [ -n "$line" ]; do
      _envfile_parse_key "$line" || continue
      _envfile_split_rhs "$_ef_raw_rhs"
      # Write value with a trailing newline marker file; use printf %s to keep exact bytes
      printf '%s' "$_ef_value" > "${live_values}/${_ef_key}"
    done < "$file"
  fi

  local tmp seen_keys
  tmp="$(mktemp "${file}.XXXXXX")"
  chmod 600 "$tmp"
  seen_keys="$(mktemp "${TMPDIR:-/tmp}/envfile-seen.XXXXXX")"

  local line key ex_comment ex_value live
  while IFS= read -r line || [ -n "$line" ]; do
    if ! _envfile_parse_key "$line"; then
      # Comments, blanks, malformed — copy verbatim from example
      printf '%s\n' "$line" >> "$tmp"
      continue
    fi
    key="$_ef_key"
    _envfile_split_rhs "$_ef_raw_rhs"
    ex_value="$_ef_value"
    ex_comment="$_ef_comment"
    printf '%s\n' "$key" >> "$seen_keys"

    if [ -f "${live_values}/${key}" ]; then
      live="$(cat "${live_values}/${key}")"
      _envfile_format_assignment "$key" "$live" "$ex_comment" >> "$tmp"
      overlay_count=$((overlay_count+1))
      rm -f "${live_values}/${key}"
    else
      # New from example — keep example default
      _envfile_format_assignment "$key" "$ex_value" "$ex_comment" >> "$tmp"
      new_count=$((new_count+1))
    fi
  done < "$example"

  # Orphans: still present under live_values
  local orphans=0
  for keyfile in "$live_values"/*; do
    [ -e "$keyfile" ] || continue
    key="$(basename "$keyfile")"
    if _envfile_is_cli_only "$key"; then
      echo "  note: dropping CLI-only key $key from .env (pass it on the command line)" >&2
      skipped_cli=$((skipped_cli+1))
      rm -f "$keyfile"
      continue
    fi
    orphans=$((orphans+1))
  done

  if [ "$orphans" -gt 0 ]; then
    {
      echo ""
      echo "# ─── Local-only (not in .env.example) ─────────────────────────────────────"
      echo "# Keys below were in your .env but are not in .env.example. Kept so sync is"
      echo "# non-destructive. Move them into .env.example (if shared) or delete when done."
    } >> "$tmp"
    for keyfile in "$live_values"/*; do
      [ -e "$keyfile" ] || continue
      key="$(basename "$keyfile")"
      live="$(cat "$keyfile")"
      _envfile_format_assignment "$key" "$live" "" >> "$tmp"
      orphan_count=$((orphan_count+1))
      rm -f "$keyfile"
    done
  fi

  # If no prior .env, still write
  mv "$tmp" "$file"
  chmod 600 "$file"
  rm -rf "$live_values"
  rm -f "$seen_keys"

  echo "✓ .env synced from .env.example"
  echo "    overlayed=${overlay_count}  new_from_example=${new_count}  local_only=${orphan_count}  dropped_cli_only=${skipped_cli}"
  echo "    backup under .solomog/env-backups/ (if a previous .env existed)"
}

# Structural drift report — never prints secret values.
envfile_diff() {
  local example="${1:-$(_envfile_example_path)}"
  local file="${2:-$(_envfile_path)}"
  local only_ex only_live

  if [ ! -f "$example" ]; then
    echo "envfile_diff: $example not found" >&2
    return 1
  fi
  if [ ! -f "$file" ]; then
    echo "envfile_diff: $file not found (copy .env.example → .env, or run solomog env:sync)" >&2
    return 1
  fi

  only_ex="$(mktemp "${TMPDIR:-/tmp}/envfile-ex.XXXXXX")"
  only_live="$(mktemp "${TMPDIR:-/tmp}/envfile-live.XXXXXX")"

  local line
  while IFS= read -r line || [ -n "$line" ]; do
    _envfile_parse_key "$line" || continue
    printf '%s\n' "$_ef_key"
  done < "$example" | LC_ALL=C sort -u > "$only_ex"

  while IFS= read -r line || [ -n "$line" ]; do
    _envfile_parse_key "$line" || continue
    printf '%s\n' "$_ef_key"
  done < "$file" | LC_ALL=C sort -u > "$only_live"

  echo "==> Keys only in .env.example (missing from .env — run solomog env:sync):"
  local miss
  miss="$(comm -23 "$only_ex" "$only_live")"
  if [ -z "$miss" ]; then
    echo "    (none)"
  else
    printf '%s\n' "$miss" | sed 's/^/    /'
  fi

  echo "==> Keys only in .env (not in .env.example — local-only or stale):"
  local extra
  extra="$(comm -13 "$only_ex" "$only_live")"
  if [ -z "$extra" ]; then
    echo "    (none)"
  else
    printf '%s\n' "$extra" | while IFS= read -r k; do
      if _envfile_is_cli_only "$k"; then
        echo "    $k  (CLI-only — remove from .env; pass on the command line)"
      else
        echo "    $k"
      fi
    done
  fi

  echo "==> Shared keys: $(comm -12 "$only_ex" "$only_live" | wc -l | tr -d ' ')"
  rm -f "$only_ex" "$only_live"

  # Whitespace lint. A value carrying leading/trailing whitespace survives dotenv and
  # helmfile's `| default` (so a "  " value silently defeats a fallback chain) and breaks
  # anything that passes it verbatim — `docker run -e KEY=<value>` most of all. Names only.
  echo "==> Values with leading/trailing whitespace (trim these):"
  local ws_found=0 k v trimmed
  while IFS= read -r line || [ -n "$line" ]; do
    _envfile_parse_key "$line" || continue
    k="$_ef_key"
    _envfile_split_rhs "$_ef_raw_rhs"
    v="$_ef_value"
    [ -n "$v" ] || continue
    trimmed="${v#"${v%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    if [ "$v" != "$trimmed" ]; then
      ws_found=1
      echo "    $k  (${#v} chars, ${#trimmed} after trim)"
    fi
  done < "$file"
  [ "$ws_found" -eq 0 ] && echo "    (none)"
  return 0
}
