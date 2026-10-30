#!/usr/bin/env bash
set -euo pipefail
#
# Fixture tests for the 🗿 quip gate in scripts/lib/ui.sh (no cluster).
# Run: bash scripts/test-ui.sh

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export NO_COLOR=1
# shellcheck source=lib/ui.sh
source "$REPO_DIR/scripts/lib/ui.sh"

FAIL=0
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; FAIL=$((FAIL + 1)); }

assert_eq() {
  local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    pass "$label"
  else
    fail "$label (got=$(printf '%q' "$got") want=$(printf '%q' "$want"))"
  fi
}

in_list() {
  local needle="$1" x
  shift
  for x in "$@"; do
    [ "$x" = "$needle" ] && return 0
  done
  return 1
}

# Banner text after the shared prefix. Failure lines keep the " (exit N)" suffix
# out of the pool comparison; the caller checks that suffix separately.
quip_of() {
  local line="$1" prefix="🗿  solomog — "
  line="${line#*$'\n'}"
  case "$line" in
    "$prefix"*) printf '%s' "${line#"$prefix"}" ;;
    *) return 1 ;;
  esac
}

pool_quip() {
  local line="$1"
  line="${line% (exit *)}"
  printf '%s' "$line"
}

set_serious() {
  if [ "$1" = "<unset>" ]; then
    unset SOLOMOG_SERIOUS
  else
    SOLOMOG_SERIOUS="$1"
  fi
}

echo "==> quiet by default"
for val in "<unset>" "" "1" "true" "yes" "on" "TRUE" "maybe"; do
  set_serious "$val"
  assert_eq "intro [$val]" "$(solomog_intro)" ""
  assert_eq "intro destroy [$val]" "$(solomog_intro destroy)" ""
  assert_eq "outro ok [$val]" "$(solomog_outro 0)" ""
  assert_eq "outro fail [$val]" "$(solomog_outro 7)" ""
  assert_eq "outro destroy fail [$val]" "$(solomog_outro 7 destroy)" ""
done

echo "==> explicit negative prints a quip from the matching pool"
for val in "0" "false" "no" "off" "FALSE" "Off"; do
  set_serious "$val"
  intro="$(solomog_intro)"
  q="$(quip_of "$intro")" || { fail "intro [$val] (unparsed: $(printf '%q' "$intro"))"; q=""; }
  if [ -n "$q" ] && in_list "$q" "${_SM_START_QUIPS[@]}"; then
    pass "intro [$val]"
  elif [ -n "$q" ]; then
    fail "intro [$val] (quip not in start pool: $(printf '%q' "$q"))"
  fi

  intro="$(solomog_intro destroy)"
  q="$(quip_of "$intro")" || { fail "intro destroy [$val] (unparsed)"; q=""; }
  if [ -n "$q" ] && in_list "$q" "${_SM_DESTROY_START_QUIPS[@]}"; then
    pass "intro destroy [$val]"
  elif [ -n "$q" ]; then
    fail "intro destroy [$val] (quip not in destroy-start pool: $(printf '%q' "$q"))"
  fi

  outro="$(solomog_outro 0)"
  q="$(quip_of "$outro")" || { fail "outro ok [$val] (unparsed)"; q=""; }
  if [ -n "$q" ] && in_list "$q" "${_SM_WIN_QUIPS[@]}"; then
    pass "outro ok [$val]"
  elif [ -n "$q" ]; then
    fail "outro ok [$val] (quip not in win pool: $(printf '%q' "$q"))"
  fi

  outro="$(solomog_outro 0 destroy)"
  q="$(quip_of "$outro")" || { fail "outro destroy ok [$val] (unparsed)"; q=""; }
  if [ -n "$q" ] && in_list "$q" "${_SM_DESTROY_WIN_QUIPS[@]}"; then
    pass "outro destroy ok [$val]"
  elif [ -n "$q" ]; then
    fail "outro destroy ok [$val] (quip not in destroy-win pool: $(printf '%q' "$q"))"
  fi

  outro="$(solomog_outro 7)"
  q="$(quip_of "$outro")" || { fail "outro fail [$val] (unparsed)"; q=""; }
  case "$q" in
    *" (exit 7)") pass "outro fail suffix [$val]" ;;
    *) fail "outro fail suffix [$val] (got=$(printf '%q' "$q"))" ;;
  esac
  q="$(pool_quip "$q")"
  if in_list "$q" "${_SM_LOSS_QUIPS[@]}"; then
    pass "outro fail [$val]"
  else
    fail "outro fail [$val] (quip not in loss pool: $(printf '%q' "$q"))"
  fi

  outro="$(solomog_outro 7 destroy)"
  q="$(quip_of "$outro")" || { fail "outro destroy fail [$val] (unparsed)"; q=""; }
  case "$q" in
    *" (exit 7)") pass "outro destroy fail suffix [$val]" ;;
    *) fail "outro destroy fail suffix [$val] (got=$(printf '%q' "$q"))" ;;
  esac
  q="$(pool_quip "$q")"
  if in_list "$q" "${_SM_DESTROY_LOSS_QUIPS[@]}"; then
    pass "outro destroy fail [$val]"
  else
    fail "outro destroy fail [$val] (quip not in destroy-loss pool: $(printf '%q' "$q"))"
  fi
done

echo "==> _solomog_truthy stays affirmative-only"
if _solomog_truthy "1"; then pass "truthy 1"; else fail "truthy 1"; fi
if _solomog_truthy "true"; then pass "truthy true"; else fail "truthy true"; fi
if _solomog_truthy "0"; then fail "truthy 0"; else pass "truthy 0"; fi
if _solomog_truthy ""; then fail "truthy empty"; else pass "truthy empty"; fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "ok"
else
  echo "$FAIL failed"
  exit 1
fi
