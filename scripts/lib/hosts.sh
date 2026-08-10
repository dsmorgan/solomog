#!/usr/bin/env bash
# /etc/hosts line management for expose/route-host — replace-or-add one host entry.
#
# Deliberately writes via `sudo tee /etc/hosts` (whole-file OVERWRITE) instead of the
# old sed-delete + tee-append pair: the dedup happens WITHOUT sudo (sed to stdout on
# the world-readable file), so the only privileged operation is one fixed, exactly-
# matchable command. That lets a passwordless setup be a single narrow sudoers rule:
#     <user> ALL=(root) NOPASSWD: /usr/bin/tee /etc/hosts
# (Interactive use is unchanged — sudo just prompts once.) The old append-only rule
# (`tee -a /etc/hosts`) is NOT enough: appends can't remove a stale line, and the
# resolver takes the FIRST match, so a changed LB IP would leave the old entry
# winning (this actually happened — three stacked agw entries, oldest first).

# Replace any existing line(s) for <host> with "<ip> <host>". Needs sudo (see above).
solomog_hosts_set() {   # args: <host> <ip>
  local host="$1" ip="$2" content
  content="$(sed -e "/[[:space:]]${host}\$/d" -e "/[[:space:]]${host}[[:space:]]/d" /etc/hosts)"
  printf '%s\n%s %s\n' "$content" "$ip" "$host" | sudo tee /etc/hosts >/dev/null
}
