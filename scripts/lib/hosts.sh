#!/usr/bin/env bash
# /etc/hosts line management for expose/route-host — replace-or-add one host entry.
#
# Deliberately writes via `sudo tee /etc/hosts` (whole-file OVERWRITE) instead of the
# old sed-delete + tee-append pair: the dedup happens WITHOUT sudo (to stdout on the
# world-readable file), so the only privileged operation is one fixed, exactly-
# matchable command. That lets a passwordless setup be a single narrow sudoers rule:
#     <user> ALL=(root) NOPASSWD: /usr/bin/tee /etc/hosts
# installed once by `solomog setup:sudo` ([scripts/setup-sudo.sh]), which BUILDS that
# rule from $SOLOMOG_HOSTS_TEE below — so the command spec can never drift from the
# command actually run. (Interactive use is unchanged — sudo just prompts once.) The old
# append-only rule (`tee -a /etc/hosts`) is NOT enough: appends can't remove a stale
# line, and the resolver takes the FIRST match, so a changed LB IP would leave the old
# entry winning (this actually happened — three stacked agw entries, oldest first).
#
# Every line solomog writes is stamped `# solomog cluster=<CLUSTER>` (CLUSTER is
# required). Teardown / hosts:clean drop only exact-stamp lines — unmarked entries,
# including other *.test names, stay. Same ownership idea as the OPNsense DNS=real
# descr prefix (`solomog <cluster>/`).
#
# sudoers matches the FULLY-QUALIFIED path, and sudo resolves a bare `tee` through the
# caller's PATH (macOS sets no secure_path) — a brew coreutils `tee` earlier on PATH
# would silently stop matching the rule and start prompting again. Hence the absolute
# path here, as one variable shared with the installer.
if [ -z "${SOLOMOG_HOSTS_TEE:-}" ]; then
  if [ -x /usr/bin/tee ]; then
    SOLOMOG_HOSTS_TEE=/usr/bin/tee
  else
    SOLOMOG_HOSTS_TEE="$(command -v tee)"
  fi
fi

# Ownership comment written after the hostname. Exact string — cluster `a1` must
# never match `a10`. Trailing-comment compare trims surrounding whitespace only.
_solomog_hosts_stamp() {   # args: <cluster>
  printf 'solomog cluster=%s' "$1"
}

# Pull the trailing # comment from a hosts data line (awk). Sets `comment` to the
# text after `#` with leading/trailing space trimmed, or "" if the line has none.
# $0 is the full line — do not use this on full-comment lines (caller skips those).
_SOLOMOG_HOSTS_AWK_COMMENT='
  comment = ""
  for (i = 2; i <= NF; i++) {
    if (substr($i, 1, 1) == "#") {
      comment = substr($i, 2)
      for (j = i + 1; j <= NF; j++) comment = comment " " $j
      break
    }
  }
  gsub(/^[[:space:]]+|[[:space:]]+$/, "", comment)
'

# True when a hostname field is *.<cluster>.test (case-insensitive). Suffix match,
# not a regex — cluster `a1` does not match `foo.xa1.test`.
_SOLOMOG_HOSTS_AWK_DOT_TEST='
  function hosts_dot_test(name, cluster,    suffix, nlen, slen) {
    suffix = "." tolower(cluster) ".test"
    nlen = length(name)
    slen = length(suffix)
    return (nlen >= slen && substr(tolower(name), nlen - slen + 1) == suffix)
  }
'

# Pure dedup: hosts-file content on stdin → content with <host> removed on stdout.
# awk compares whole fields (no regex), so the dots in a hostname can never wildcard-
# match a different entry (the old sed pattern deleted near-miss names), and a
# shared-alias line keeps its other names — the whole line is dropped only when
# <host> was its last remaining name. Matching is case-INsensitive (resolvers are,
# and first-match wins — a stale ALL-CAPS entry would otherwise survive and shadow
# the new line). Full-comment lines pass through untouched. Pure (no /etc/hosts,
# no sudo) so it's fixture-testable; solomog_hosts_set below owns the privileged write.
_solomog_hosts_strip() {   # args: <host>  (content on stdin)
  awk -v h="$1" '
    BEGIN { lh = tolower(h) }
    /^[[:space:]]*#/ { print; next }              # commented-out lines are not data
    {
      # does this line name <host>? (names sit after the IP, before any # comment)
      found = 0
      for (i = 2; i <= NF; i++) {
        if (substr($i, 1, 1) == "#") break
        if (tolower($i) == lh) { found = 1; break }
      }
      if (!found) { print; next }
      # rebuild without <host>, preserving other names and a trailing comment
      line = $1; names = 0; incomment = 0; comment = ""
      for (i = 2; i <= NF; i++) {
        if (!incomment && substr($i, 1, 1) == "#") incomment = 1
        if (incomment) { comment = comment " " $i; continue }
        if (tolower($i) == lh) continue
        line = line " " $i; names++
      }
      if (names > 0) print line comment
    }
  '
}

# Drop data lines whose trailing comment is exactly `solomog cluster=<cluster>`.
# Unmarked lines stay, even when the hostname is *.<cluster>.test. Full-comment
# lines pass through. Pure (stdin → stdout) so it is fixture-testable.
_solomog_hosts_strip_cluster() {   # args: <cluster>  (content on stdin)
  awk -v stamp="$(_solomog_hosts_stamp "$1")" '
    /^[[:space:]]*#/ { print; next }
    {
      '"$_SOLOMOG_HOSTS_AWK_COMMENT"'
      if (comment == stamp) next
      print
    }
  '
}

# Data lines stamped for <cluster> (any hostname). Display + teardown logging.
_solomog_hosts_stamped() {   # args: <cluster>  (content on stdin)
  awk -v stamp="$(_solomog_hosts_stamp "$1")" '
    /^[[:space:]]*#/ { next }
    {
      '"$_SOLOMOG_HOSTS_AWK_COMMENT"'
      if (comment == stamp) print
    }
  '
}

# Unmarked *.<cluster>.test data lines — leftovers teardown must not delete.
_solomog_hosts_unmarked() {   # args: <cluster>  (content on stdin)
  awk -v stamp="$(_solomog_hosts_stamp "$1")" -v cluster="$1" '
    '"$_SOLOMOG_HOSTS_AWK_DOT_TEST"'
    /^[[:space:]]*#/ { next }
    {
      '"$_SOLOMOG_HOSTS_AWK_COMMENT"'
      if (comment == stamp) next
      for (i = 2; i <= NF; i++) {
        if (substr($i, 1, 1) == "#") break
        if (hosts_dot_test($i, cluster)) { print; next }
      }
    }
  '
}

# cluster:show: stamped lines for <cluster> plus unmarked *.<cluster>.test.
_solomog_hosts_lines_for() {   # args: <cluster>  (content on stdin)
  awk -v stamp="$(_solomog_hosts_stamp "$1")" -v cluster="$1" '
    '"$_SOLOMOG_HOSTS_AWK_DOT_TEST"'
    /^[[:space:]]*#/ { next }
    {
      '"$_SOLOMOG_HOSTS_AWK_COMMENT"'
      if (comment == stamp) { print; next }
      for (i = 2; i <= NF; i++) {
        if (substr($i, 1, 1) == "#") break
        if (hosts_dot_test($i, cluster)) { print; next }
      }
    }
  '
}

# Replace any existing line(s) for <host> with "<ip> <host> # solomog cluster=<CLUSTER>".
# CLUSTER must be set (the stamp is the only safe teardown selector). Needs sudo —
# passwordless after `solomog setup:sudo`, one prompt per sudo timestamp otherwise.
solomog_hosts_set() {   # args: <host> <ip>
  local host="$1" ip="$2" content cluster="${CLUSTER:-}"
  if [ -z "$cluster" ]; then
    echo "Error: CLUSTER is required to stamp /etc/hosts (solomog_hosts_set)." >&2
    return 1
  fi
  # Guard locally, not via the caller's errexit: if the strip fails (unreadable
  # /etc/hosts, awk error) an unguarded flow would tee EMPTY content over the file.
  content="$(_solomog_hosts_strip "$host" < /etc/hosts)" || {
    echo "Error: could not read/dedup /etc/hosts — refusing to overwrite it." >&2
    return 1
  }
  printf '%s\n%s %s # %s\n' "$content" "$ip" "$host" "$(_solomog_hosts_stamp "$cluster")" \
    | sudo "$SOLOMOG_HOSTS_TEE" /etc/hosts >/dev/null
}

# Remove every line stamped for <cluster>. Skips the privileged write when nothing
# matches. Prints unmarked *.<cluster>.test leftovers (does not delete them).
solomog_hosts_unset_cluster() {   # args: <cluster>
  local cluster="$1" content current stamped leftovers host
  if [ -z "$cluster" ]; then
    echo "Error: cluster name required to clean /etc/hosts (solomog_hosts_unset_cluster)." >&2
    return 1
  fi
  current="$(cat /etc/hosts)" || {
    echo "Error: could not read /etc/hosts — refusing to overwrite it." >&2
    return 1
  }
  content="$(printf '%s\n' "$current" | _solomog_hosts_strip_cluster "$cluster")" || {
    echo "Error: could not read/dedup /etc/hosts — refusing to overwrite it." >&2
    return 1
  }
  stamped="$(printf '%s\n' "$current" | _solomog_hosts_stamped "$cluster")"
  if [ "$content" != "$current" ]; then
    printf '%s\n' "$content" | sudo "$SOLOMOG_HOSTS_TEE" /etc/hosts >/dev/null || {
      echo "Error: could not write /etc/hosts — stamped entries for '${cluster}' were not removed." >&2
      return 1
    }
    echo "==> /etc/hosts: removed stamped entries for cluster=${cluster}"
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      host="$(printf '%s\n' "$line" | awk '{print $2}')"
      echo "    - ${host}"
    done <<EOF
$stamped
EOF
  else
    echo "==> /etc/hosts: no stamped entries for cluster=${cluster}"
  fi
  leftovers="$(printf '%s\n' "$content" | _solomog_hosts_unmarked "$cluster")"
  if [ -n "$leftovers" ]; then
    echo "    NOTE: unmarked *.${cluster}.test leftovers (not removed — solomog did not stamp them):"
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      echo "      ${line}"
    done <<EOF
$leftovers
EOF
  fi
  return 0
}
