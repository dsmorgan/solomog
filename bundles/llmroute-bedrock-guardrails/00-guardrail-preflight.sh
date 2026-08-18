# Fail fast, BEFORE anything is written to the cluster, on the three ways this bundle silently
# half-works. Runs first (00-) on purpose: 01-api-keys.sh would otherwise push expired
# credentials into bedrock-secret, and the symptom only surfaces much later as an opaque
# 403 "The security token included in the request is expired" from Bedrock, via the gateway,
# in a test log. Naming the cause here costs one API call.
#
# Checks:
#   1. AWS credentials actually work            → solomog_aws_preflight (the repo-wide helper;
#      it reloads .env over stale exported AWS_* and prints the aws:refresh fix)
#   2. BEDROCK_GUARDRAIL_ID / _VERSION are set  → they feed the %%BEDROCK_GUARDRAIL_*%% tokens
#      in 12-/42-; unset renders a literal token and apply-bundle.sh errors less helpfully
#   3. The guardrail exists, is READY, and carries the DENY topic the tests assert on
#      (escape hatch: SKIP_TOPIC_CHECK=true)
set -euo pipefail

# shellcheck source=../../scripts/lib/target.sh
. "$SOLOMOG_LIB/target.sh"

REGION="${GUARDRAIL_REGION:-us-west-2}"   # must match the region pinned in 10-/12-/42-
TOPIC_NAME="${TOPIC_NAME:-InvestmentAdvice}"

# 1. credentials — exits with the refresh hint if they are dead
solomog_aws_preflight "apply BUNDLE=llmroute-bedrock-guardrails"

# 2. guardrail coordinates
if [ -z "${BEDROCK_GUARDRAIL_ID:-}" ] || [ -z "${BEDROCK_GUARDRAIL_VERSION:-}" ]; then
  {
    echo "Error: BEDROCK_GUARDRAIL_ID and BEDROCK_GUARDRAIL_VERSION must be set in .env."
    echo "  They are new keys, so add them to your .env first:"
    echo "    solomog env:sync            # adds the keys from .env.example, keeps your values"
    echo "  Then set them. To find an existing guardrail:"
    echo "    aws bedrock list-guardrails --region ${REGION}"
    echo "  Use the ID column (not the name, not the arn); version DRAFT is fine while iterating."
  } >&2
  exit 1
fi

# 3. guardrail is real, READY, and in the right region
echo "==> checking guardrail ${BEDROCK_GUARDRAIL_ID} (${BEDROCK_GUARDRAIL_VERSION}) in ${REGION}"
if ! GR="$(aws bedrock get-guardrail \
             --guardrail-identifier "$BEDROCK_GUARDRAIL_ID" \
             --guardrail-version "$BEDROCK_GUARDRAIL_VERSION" \
             --region "$REGION" --output json 2>&1)"; then
  {
    echo "Error: cannot read guardrail ${BEDROCK_GUARDRAIL_ID} version ${BEDROCK_GUARDRAIL_VERSION} in ${REGION}."
    echo "  aws said: ${GR}"
    echo "  A guardrail is REGIONAL — it must live in the same region as the Bedrock backends"
    echo "  that reference it (this bundle pins ${REGION}). List them with:"
    echo "    aws bedrock list-guardrails --region ${REGION}"
  } >&2
  exit 1
fi

STATUS="$(printf '%s' "$GR" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))')"
if [ "$STATUS" != "READY" ]; then
  echo "Error: guardrail ${BEDROCK_GUARDRAIL_ID} status is ${STATUS}, expected READY." >&2
  exit 1
fi

if [ "${SKIP_TOPIC_CHECK:-false}" != "true" ]; then
  TOPICS="$(printf '%s' "$GR" | python3 -c '
import json, sys
gr = json.load(sys.stdin)
print(" ".join(t.get("name", "") for t in gr.get("topicPolicy", {}).get("topics", [])))')"
  case " $TOPICS " in
    *" $TOPIC_NAME "*) ;;
    *)
      {
        echo "Error: guardrail ${BEDROCK_GUARDRAIL_ID} has no DENY topic named ${TOPIC_NAME}."
        echo "  The bundle tests assert on it, because a topic DENY blocks deterministically"
        echo "  while the content filters block on classifier confidence."
        echo "  Add it (previews the full payload first, mutates nothing until APPLY=true):"
        echo "    bash bundles/llmroute-bedrock-guardrails/helpers/add-denied-topic.sh"
        echo "    APPLY=true bash bundles/llmroute-bedrock-guardrails/helpers/add-denied-topic.sh"
        echo "  Or skip this check: SKIP_TOPIC_CHECK=true (the topic-block tests will then fail)."
        echo "  Topics currently on the guardrail: ${TOPICS:-<none>}"
      } >&2
      exit 1 ;;
  esac
fi

echo "✓ preflight: creds OK · guardrail ${BEDROCK_GUARDRAIL_ID}/${BEDROCK_GUARDRAIL_VERSION} READY in ${REGION} · topic ${TOPIC_NAME} present"
