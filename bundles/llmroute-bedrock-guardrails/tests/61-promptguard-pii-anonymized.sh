# ATTACH POINT 2, the MASK path rather than the block path.
#
# The guardrail's sensitiveInformationPolicy sets EMAIL → ANONYMIZE (not BLOCK), so an email in
# the prompt should be rewritten before the model ever sees it, and the request should still
# succeed. That is a different code path from 60-: ApplyGuardrail returns modified content
# instead of a deny, and the gateway has to substitute it into the outbound request.
#
# The prompt asks the model to echo the address back, so the original can only appear in the
# response if the anonymization did NOT happen. Assert: request succeeds (not 403) AND the
# literal address is absent.
#
# If this fails with the address present, the interesting question is whether the gateway
# forwards ApplyGuardrail's masked output or only acts on its allow/deny verdict — worth
# checking against the response guard too before calling it a product bug.
set -euo pipefail
out="$(mktemp)"; trap 'rm -f "$out"' EXIT
EMAIL="dave.tester@example.com"

code="$(curl -sS -o "$out" -w '%{http_code}' "https://$HOST/bedrock/guard/promptguard" \
  -H 'content-type: application/json' \
  -d "{\"model\":\"\",\"messages\":[{\"role\":\"user\",\"content\":\"Repeat this email address back to me exactly, with no other words: ${EMAIL}\"}]}")"

echo "HTTP $code"; cat "$out"; echo

if [ "$code" = "403" ]; then
  echo "FAIL: guardrail BLOCKED the request, but EMAIL is configured as ANONYMIZE (mask)." >&2
  echo "  Check the PII action on the guardrail:" >&2
  echo "    aws bedrock get-guardrail --guardrail-identifier \$BEDROCK_GUARDRAIL_ID \\" >&2
  echo "      --guardrail-version \$BEDROCK_GUARDRAIL_VERSION --region us-west-2 \\" >&2
  echo "      --query 'sensitiveInformationPolicy.piiEntities'" >&2
  exit 1
fi
if [ "$code" != "200" ]; then
  echo "FAIL: expected 200 (masked and forwarded), got ${code}" >&2
  exit 1
fi
if grep -qF "$EMAIL" "$out"; then
  echo "FAIL: the literal email survived into the response — it was NOT anonymized" >&2
  exit 1
fi
echo "PASS: request succeeded and the email did not come back verbatim"
