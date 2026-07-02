# /llmfailover2 — verify eviction-based LLM failover across a mixed-error group.
#
# Failover here is EVICTION-based, not in-request retry. Priority group 1 has TWO mock
# providers — one returns 429 (rate_limit), one returns 503 (server_error). Each failing
# response evicts that provider (health policy, consecutiveFailures: 1); the triggering
# request still returns its error code to the client. So you see ~2 priming responses (a 429
# and a 503, in P2C order) as both providers drain, THEN failover to group 2 (OpenAI) → 200.
# A single call can't prove failover — prime, tolerate 429/503, retry for the 200.
#
# Passes when a 200 appears within a few attempts (failover reached OpenAI). Fails if it never
# recovers, or an unexpected status appears (misconfig).
# NOTE: the failover attempt calls the real OpenAI API (costs tokens) — expected for this test.
# NOTE: eviction settles a moment after `apply` — if a fresh apply still 503s on every attempt,
# give it a few seconds and re-run (there's a propagation delay from apply to working failover).
URL="https://$HOST/llmfailover2"
DATA='{"model":"gpt-4o-mini","messages":[{"role":"user","content":"tell me a simple 1 line joke"}]}'

code=000 body=""
for i in 1 2 3 4 5; do
  resp="$(curl -sS -w $'\n%{http_code}' "$URL" -H 'content-type: application/json' -d "$DATA")"
  code="${resp##*$'\n'}"          # last line = HTTP status
  body="${resp%$'\n'*}"           # everything before it = response body
  echo "attempt $i ($URL) → HTTP $code"
  case "$code" in
    200)     break ;;                 # failed over (or group 1 already evicted) — success
    429|503) sleep 1; continue ;;     # priming: a group-1 mock failed + got evicted, retry to fail over
    *)       echo "unexpected status $code (wanted 429/503 priming, then 200):"; echo "$body"; exit 1 ;;
  esac
done

if [ "$code" = "200" ]; then
  echo "✓ failed over — served by: $(printf '%s' "$body" | jq -r '.model // "?"' 2>/dev/null)"
  exit 0
fi
echo "✗ never failed over to 200 after priming — eviction/failover not working:"
echo "$body"
exit 1
