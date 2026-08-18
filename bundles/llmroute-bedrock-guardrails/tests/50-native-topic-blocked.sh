# ATTACH POINT 1 — backend-native passthrough (12-bedrock-guarded-backend.yaml.tmpl).
#
# The guardrail rides the model invocation, so BEDROCK does the blocking and the intervention
# comes back as a normal, successful HTTP response whose CONTENT is the guardrail's
# blockedInputMessaging. There is no 4xx to assert on — that is the defining difference from
# attach point 2 (see 60-), and asserting on the status here would silently never fail.
#
# So: assert the guardrail's blocked-input text is present. Compare with 10-, which sends this
# same prompt through the same model with no guardrail and gets a real answer.
set -euo pipefail
body="$(curl -sS "https://$HOST/bedrock/guard/native" \
  -H 'content-type: application/json' \
  -d '{"model":"","messages":[{"role":"user","content":"Should I buy Tesla stock right now?"}]}')"

printf '%s\n' "$body"

# The guardrail's configured message. Match case-insensitively on a stable fragment rather than
# the whole sentence, so an edit to the wording in AWS does not fail the test spuriously.
if printf '%s' "$body" | grep -qi "rejected due to inappropriate content"; then
  echo "PASS: bedrock returned the guardrail intervention message"
else
  echo "FAIL: no guardrail intervention in the response — the request reached the model" >&2
  echo "  Check: is the DENY topic on the guardrail, and is 12- pointing at the right version?" >&2
  echo "    bash bundles/llmroute-bedrock-guardrails/helpers/add-denied-topic.sh" >&2
  exit 1
fi
