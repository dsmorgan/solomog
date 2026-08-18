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

# Replace any existing line(s) for <host> with "<ip> <host>". Needs sudo (see above) —
# passwordless after `solomog setup:sudo`, one prompt per sudo timestamp otherwise.
solomog_hosts_set() {   # args: <host> <ip>
  local host="$1" ip="$2" content
  # Guard locally, not via the caller's errexit: if the strip fails (unreadable
  # /etc/hosts, awk error) an unguarded flow would tee EMPTY content over the file.
  content="$(_solomog_hosts_strip "$host" < /etc/hosts)" || {
    echo "Error: could not read/dedup /etc/hosts — refusing to overwrite it." >&2
    return 1
  }
  printf '%s\n%s %s\n' "$content" "$ip" "$host" | sudo "$SOLOMOG_HOSTS_TEE" /etc/hosts >/dev/null
}
