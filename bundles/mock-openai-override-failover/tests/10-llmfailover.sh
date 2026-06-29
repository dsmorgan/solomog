# /llmfailover — verify eviction-based LLM failover.
#
# Failover here is EVICTION-based, not in-request retry: the mock (priority group 1) returns
# 429 on every call. The FIRST request that hits it returns 429 to the client AND evicts the
# mock; subsequent requests (within the eviction window) fail over to group 2 (OpenAI) → 200.
# So a single call can't prove failover — we prime, tolerate the 429, then retry for the 200.
#
# Passes when a 200 appears within a few attempts (failover reached OpenAI). Fails if every
# attempt stays 429 (eviction/failover not working) or any other status appears (misconfig).
# NOTE: the failover attempt calls the real OpenAI API (costs tokens) — expected for this test.
URL="https://$HOST/llmfailover"
DATA='{"model":"gpt-4o-mini","messages":[{"role":"user","content":"tell me a simple 1 line joke"}]}'

code=000 body=""
for i in 1 2 3 4 5; do
  resp="$(curl -sS -w $'\n%{http_code}' "$URL" -H 'content-type: application/json' -d "$DATA")"
  code="${resp##*$'\n'}"          # last line = HTTP status
  body="${resp%$'\n'*}"           # everything before it = response body
  echo "attempt $i → HTTP $code"
  case "$code" in
    200) break ;;                 # failed over (or mock already evicted) — success
    429) sleep 1; continue ;;     # expected priming response: mock evicted, retry to fail over
    *)   echo "unexpected status $code (wanted 429 then 200):"; echo "$body"; exit 1 ;;
  esac
done

if [ "$code" = "200" ]; then
  echo "✓ failed over — served by: $(printf '%s' "$body" | jq -r '.model // "?"' 2>/dev/null)"
  exit 0
fi
echo "✗ never failed over to 200 after priming — eviction/failover not working:"
echo "$body"
exit 1
