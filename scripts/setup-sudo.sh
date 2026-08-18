#!/usr/bin/env bash
set -euo pipefail
#
# One-time per machine: make solomog's ONE privileged operation passwordless, so a long
# unattended run (`solomog stack …`, `solomog expose …`) never stalls halfway waiting for
# a sudo password while you are off doing something else.
#
# That operation is the whole-file /etc/hosts rewrite in scripts/lib/hosts.sh (pinning a
# gateway LoadBalancer IP to a .test hostname for expose / route-host / bundle hooks).
# Nothing else in solomog needs root.
#
# WHY THE RULE MATCHES: sudoers matches the fully-qualified command path AND its
# arguments, so the grant has to be byte-identical to what runs. Two things guarantee
# that here rather than hoping a comment stays true:
#   - hosts.sh calls the binary by ABSOLUTE path via $SOLOMOG_HOSTS_TEE (sudo would
#     otherwise resolve a bare `tee` through PATH — a brew coreutils tee would stop
#     matching and start prompting);
#   - this installer sources hosts.sh and builds the rule from that same variable.
# The single argument is why hosts.sh dedups unprivileged and overwrites the whole file:
# `tee -a` or `sed -i` would each need their own (looser) grant.
#
# TRADE-OFF, plainly: afterwards anything running as your user can rewrite /etc/hosts
# with no prompt — i.e. can redirect hostnames on this machine. It grants no shell, no
# other file, and no other command.
#
# Env:
#   CHECK=true    verify only — no writes, no prompt. Exit 0 = passwordless, 1 = not.
#   REMOVE=true   remove the sudoers fragment (prompts once for sudo).

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/hosts.sh
source "$REPO_DIR/scripts/lib/hosts.sh"   # → $SOLOMOG_HOSTS_TEE (the command to grant)

SUDOERS_FILE="/etc/sudoers.d/solomog"     # NO dot in the name — sudo ignores those
CHECK="${CHECK:-false}"
REMOVE="${REMOVE:-false}"
USER_NAME="$(id -un)"
RULE="${USER_NAME} ALL=(root) NOPASSWD: ${SOLOMOG_HOSTS_TEE} /etc/hosts"

VISUDO="$(command -v visudo || true)"
[ -z "$VISUDO" ] && VISUDO=/usr/sbin/visudo

if [[ "$CHECK" == "true" && "$REMOVE" == "true" ]]; then
  echo "Error: CHECK=true and REMOVE=true are mutually exclusive — pick one." >&2
  exit 1
fi

# Is the exact command allowed with no password RIGHT NOW? `-l <cmd>` is a read-only
# policy query (nothing runs); `-k` makes it ignore any cached sudo timestamp, so a
# password typed a minute ago cannot fake a pass. `-n` means never prompt.
hosts_write_is_passwordless() {
  sudo -k -n -l "$SOLOMOG_HOSTS_TEE" /etc/hosts >/dev/null 2>&1
}

# The managed fragment. Heredoc is unquoted (needs $RULE) so it must stay backtick-free:
# a backtick here would run as command substitution mid-install.
fragment() {
  cat <<EOF
# solomog — passwordless /etc/hosts rewrite. MANAGED FILE, do not hand-edit.
#
#   installed by:  solomog setup:sudo
#   verify:        solomog setup:sudo CHECK=true
#   remove:        solomog setup:sudo REMOVE=true
#
# Grants exactly one command with exactly one argument: the whole-file /etc/hosts
# rewrite in solomog scripts/lib/hosts.sh, which pins a gateway LoadBalancer IP to a
# .test hostname (expose / route-host / bundle hooks). The dedup that precedes the
# write is unprivileged, so nothing else needs root. Re-run the task rather than
# editing this file, so the rule keeps matching the command solomog actually runs.
${RULE}
EOF
}

# ─── REMOVE ────────────────────────────────────────────────────────────────────
if [[ "$REMOVE" == "true" ]]; then
  if [[ ! -e "$SUDOERS_FILE" ]]; then
    echo "==> Nothing to remove — ${SUDOERS_FILE} does not exist."
  else
    echo "==> Removing ${SUDOERS_FILE} (sudo)"
    sudo rm -f "$SUDOERS_FILE"
    echo "    ✓ removed"
  fi
  if hosts_write_is_passwordless; then
    echo "    NOTE: the /etc/hosts write is STILL passwordless — another sudoers rule"
    echo "          grants it (a broad NOPASSWD: ALL, or an MDM fragment in /etc/sudoers.d)."
  else
    echo "    sudo will prompt again for /etc/hosts edits."
  fi
  exit 0
fi

# ─── CHECK ─────────────────────────────────────────────────────────────────────
if [[ "$CHECK" == "true" ]]; then
  echo "==> Checking whether solomog can edit /etc/hosts without a password"
  echo "    command: sudo ${SOLOMOG_HOSTS_TEE} /etc/hosts   (user ${USER_NAME})"
  if hosts_write_is_passwordless; then
    echo "    ✓ allowed with no password$([[ -e "$SUDOERS_FILE" ]] && echo " (via ${SUDOERS_FILE})")"
    exit 0
  fi
  echo "    ✗ not allowed without a password — sudo will prompt during expose/route-host."
  [[ -e "$SUDOERS_FILE" ]] && echo "      (${SUDOERS_FILE} exists but is not taking effect — see below)"
  echo "      Fix: solomog setup:sudo"
  exit 1
fi

# ─── INSTALL ───────────────────────────────────────────────────────────────────
echo "==> Passwordless /etc/hosts edits for solomog"
echo "    user:    ${USER_NAME}"
echo "    command: sudo ${SOLOMOG_HOSTS_TEE} /etc/hosts   (whole-file rewrite; scripts/lib/hosts.sh)"
echo "    file:    ${SUDOERS_FILE}"

if hosts_write_is_passwordless; then
  if [[ -e "$SUDOERS_FILE" ]]; then
    echo "    ✓ Already set up — nothing to do."
  else
    echo "    ✓ Already passwordless via some OTHER sudoers rule (broad NOPASSWD or an MDM"
    echo "      fragment) — not installing a redundant one. Nothing to do."
  fi
  exit 0
fi

TMP="$(mktemp "${TMPDIR:-/tmp}/solomog-sudoers.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
fragment > "$TMP"

# Syntax-gate BEFORE it can reach /etc/sudoers.d: a malformed fragment there makes
# every later sudo (this shell included) fail, which is a bad afternoon.
if ! "$VISUDO" -cf "$TMP" >/dev/null 2>&1; then
  echo "" >&2
  echo "Error: generated sudoers fragment failed 'visudo -c' — refusing to install." >&2
  echo "       Rule was: ${RULE}" >&2
  "$VISUDO" -cf "$TMP" >&2 || true
  exit 1
fi
echo "    ✓ fragment parses (visudo -c)"

echo ""
echo "    Installing as root:wheel 0440 — sudo will prompt for your password now."
sudo install -m 0440 -o root -g wheel "$TMP" "$SUDOERS_FILE"
echo "    ✓ wrote ${SUDOERS_FILE}"

echo ""
if hosts_write_is_passwordless; then
  echo "✓ Done — solomog can now edit /etc/hosts unattended."
  echo "  Note: the first 'solomog expose' on a new machine also runs 'mkcert -install',"
  echo "        which may ask for your LOGIN KEYCHAIN password (separate, also one-time)."
  exit 0
fi

# Installed but still not passwordless — the fragment is being ignored. Diagnose rather
# than claim success; the usual cause is a sudoers with no @includedir for sudoers.d.
echo "⚠  Installed, but the /etc/hosts write is STILL not passwordless."
echo "   Check, in order:"
echo "     1. /etc/sudoers includes the drop-in dir:   sudo grep -n includedir /etc/sudoers"
echo "        (expected: '@includedir /private/etc/sudoers.d')"
echo "     2. the whole config still parses:            sudo visudo -c"
echo "     3. a later fragment in /etc/sudoers.d overrides it (last match wins):"
echo "        sudo ls /etc/sudoers.d"
echo "     4. the rule matches your user and command:   sudo cat ${SUDOERS_FILE}"
echo "        expected: ${RULE}"
echo "   Meanwhile solomog still works — sudo just prompts as before."
exit 1
