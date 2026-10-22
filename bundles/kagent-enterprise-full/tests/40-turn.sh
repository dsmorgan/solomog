#!/usr/bin/env bash
# One turn through the assistant: the reply carries a canary only the mock model could have
# echoed, and the mock's log shows the request.
. "$(dirname "$0")/../helpers/checks.sh"

canary="canary-${RANDOM}${RANDOM}"
if turn assistant "Please file ${canary}" && grep -q "ECHO.*${canary}" <<<"$TURN_OUT"; then
  ok "turn completed: reply echoes ${canary}"
else
  no "turn didn't return ${canary}:"; printf '%s\n' "$TURN_OUT" | tail -8 | sed 's/^/      /'
fi
[ -n "$(mock_log "$MOCK_NS" mock-llm "$canary")" ] && ok "the mock model received the turn" || no "no request with ${canary} in the mock model's log"
# Leave a marker for tests/60 to find in ClickHouse.
mkdir -p "${TMPDIR:-/tmp}/kef-${CLUSTER}" && echo "$canary" > "${TMPDIR:-/tmp}/kef-${CLUSTER}/last-canary"
exit "$fail"
