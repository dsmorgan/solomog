#!/usr/bin/env bash
# Shared pretty-output helpers for solomog scripts. bash 3.2 compatible.
#
# Light-purple framed delimiters around each step, plus run-time tracking.
# Set NO_COLOR=1 to disable color (delimiters still print, just uncolored).
#
# Usage:
#   source "$REPO_DIR/scripts/lib/ui.sh"
#   solomog_clock_reset                       # start the run timer
#   solomog_step "Doing the thing"            # framed delimiter + elapsed marker
#   solomog_summary "Created X" "line" ...    # final framed delimiter + total time

if [ -z "${NO_COLOR:-}" ]; then
  _SM_P=$'\033[38;5;141m'   # light purple
  _SM_DIM=$'\033[38;5;97m'  # dimmer purple
  _SM_B=$'\033[1m'
  _SM_R=$'\033[0m'
else
  _SM_P='' ; _SM_DIM='' ; _SM_B='' ; _SM_R=''
fi

_SM_RULE='✦══════════════════════════════════════════════════════════✦'
_SM_TOP='╔════════════════════════════════════════════════════════════╗'
_SM_BOT='╚════════════════════════════════════════════════════════════╝'

# Reset the run timer (uses the bash SECONDS builtin).
solomog_clock_reset() { SECONDS=0; }

# solomog_step "<label>" — opening delimiter for a step; shows elapsed since reset.
solomog_step() {
  printf '\n%s%s%s\n'        "$_SM_P" "$_SM_RULE" "$_SM_R"
  printf '%s%s  ▶ %s%s  %s(+%ss)%s\n' "$_SM_P" "$_SM_B" "$1" "$_SM_R" "$_SM_DIM" "$SECONDS" "$_SM_R"
  printf '%s%s%s\n'          "$_SM_P" "$_SM_RULE" "$_SM_R"
}

# solomog_summary "<title>" "<line>" ... — final delimiter listing what was created + total time.
solomog_summary() {
  local title="$1"; shift
  printf '\n%s%s%s\n'    "$_SM_P" "$_SM_TOP" "$_SM_R"
  printf '%s%s  ✦ %s%s\n' "$_SM_P" "$_SM_B" "$title" "$_SM_R"
  local line
  for line in "$@"; do
    printf '%s     • %s%s\n' "$_SM_P" "$line" "$_SM_R"
  done
  printf '%s%s  ⏱  total run time: %ss%s\n' "$_SM_P" "$_SM_B" "$SECONDS" "$_SM_R"
  printf '%s%s%s\n'     "$_SM_P" "$_SM_BOT" "$_SM_R"
}
