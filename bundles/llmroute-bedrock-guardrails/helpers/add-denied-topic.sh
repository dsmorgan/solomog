#!/usr/bin/env bash
# Add a DENY topic to the Bedrock guardrail so the bundle's tests have a DETERMINISTIC block.
#
# Why a denied topic at all: the guardrail's stock content filters (VIOLENCE/HATE/INSULTS/...)
# block on classifier confidence, which makes a test prompt's verdict a judgement call that can
# drift between model versions. A topicPolicy DENY on a narrow, unambiguous subject blocks the
# same way every time — so a failing test means the guardrail wiring broke, not that a classifier
# scored 0.49 today.
#
# ⚠ `aws bedrock update-guardrail` is a FULL PUT, not a patch: any policy you omit from the call
# is DELETED from the guardrail. So this script reads the live config and re-sends everything it
# finds, with the topic added. To make that safe it REFUSES to run if the guardrail contains a
# policy type it does not know how to map back into the *Config request shape (see KNOWN_POLICIES)
# — better to stop and make someone extend this script than to quietly wipe a policy.
#
# Dry-run by DEFAULT: prints the exact payload it would send. Pass APPLY=true to mutate AWS.
#
# Usage (from anywhere; reads .env via solomog, or export the vars yourself):
#   bash bundles/llmroute-bedrock-guardrails/helpers/add-denied-topic.sh              # preview
#   APPLY=true bash bundles/llmroute-bedrock-guardrails/helpers/add-denied-topic.sh   # do it
#
# Env:
#   BEDROCK_GUARDRAIL_ID  (required) guardrail id — from .env
#   REGION                guardrail region                          default us-west-2
#   TOPIC_NAME            topic to add                              default InvestmentAdvice
#   APPLY                 true to actually call update-guardrail    default false
set -euo pipefail

ID="${BEDROCK_GUARDRAIL_ID:-}"
REGION="${REGION:-us-west-2}"
TOPIC_NAME="${TOPIC_NAME:-InvestmentAdvice}"
APPLY="${APPLY:-false}"

if [ -z "$ID" ]; then
  echo "Error: set BEDROCK_GUARDRAIL_ID (see .env). List what exists with:" >&2
  echo "       aws bedrock list-guardrails --region ${REGION}" >&2
  exit 1
fi

# Always edit DRAFT — published versions are immutable snapshots of it.
echo "==> reading live config: guardrail ${ID} (DRAFT) in ${REGION}"
LIVE="$(aws bedrock get-guardrail --guardrail-identifier "$ID" --guardrail-version DRAFT \
          --region "$REGION" --output json)"

# python3 exit codes: 0 = payload on stdout, 3 = topic already there, 1 = refused (see header).
set +e
PAYLOAD="$(TOPIC_NAME="$TOPIC_NAME" python3 -c '
import json, os, sys

live = json.load(sys.stdin)
topic_name = os.environ["TOPIC_NAME"]

# Policy keys this script can faithfully round-trip GET -> update request shape.
# Anything else present in the live guardrail is a hard error (see the header note).
KNOWN_POLICIES = {
    "contentPolicy", "sensitiveInformationPolicy", "topicPolicy",
    "wordPolicy", "contextualGroundingPolicy",
}
# Non-policy keys GET returns that update neither needs nor accepts.
READ_ONLY = {
    "createdAt", "updatedAt", "status", "statusReasons", "failureRecommendations",
    "guardrailArn", "guardrailId", "version", "name", "description",
    "blockedInputMessaging", "blockedOutputsMessaging", "kmsKeyArn",
    "crossRegionDetails",
}
unknown = set(live) - KNOWN_POLICIES - READ_ONLY
if unknown:
    sys.exit("refusing to update: unrecognized key(s) in the live guardrail: "
             + ", ".join(sorted(unknown))
             + "\n  This script would DROP them (update-guardrail is a full PUT)."
             + "\n  Extend KNOWN_POLICIES/mapping in add-denied-topic.sh first.")

req = {
    "name": live["name"],
    "blockedInputMessaging": live["blockedInputMessaging"],
    "blockedOutputsMessaging": live["blockedOutputsMessaging"],
}
if live.get("description"):
    req["description"] = live["description"]

# --- carry existing policies forward, GET shape -> *Config shape -------------------
def tier(node):
    # GET returns {"tier": {"tierName": "..."}}; update wants {"tierConfig": {...}}
    return {"tierConfig": node["tier"]} if "tier" in node else {}

if "contentPolicy" in live:
    cp = live["contentPolicy"]
    req["contentPolicyConfig"] = {
        "filtersConfig": [
            {k: f[k] for k in ("type", "inputStrength", "outputStrength") if k in f}
            for f in cp.get("filters", [])
        ],
        **tier(cp),
    }

if "sensitiveInformationPolicy" in live:
    sp = live["sensitiveInformationPolicy"]
    cfg = {}
    if sp.get("piiEntities"):
        cfg["piiEntitiesConfig"] = [
            {k: e[k] for k in ("type", "action") if k in e} for e in sp["piiEntities"]
        ]
    if sp.get("regexes"):
        cfg["regexesConfig"] = [
            {k: r[k] for k in ("name", "description", "pattern", "action") if k in r}
            for r in sp["regexes"]
        ]
    if cfg:
        req["sensitiveInformationPolicyConfig"] = cfg

if "wordPolicy" in live:
    wp = live["wordPolicy"]
    cfg = {}
    if wp.get("words"):
        cfg["wordsConfig"] = [{"text": w["text"]} for w in wp["words"]]
    if wp.get("managedWordLists"):
        cfg["managedWordListsConfig"] = [
            {"type": m["type"]} for m in wp["managedWordLists"]
        ]
    if cfg:
        req["wordPolicyConfig"] = cfg

if "contextualGroundingPolicy" in live:
    req["contextualGroundingPolicyConfig"] = {
        "filtersConfig": [
            {k: f[k] for k in ("type", "threshold") if k in f}
            for f in live["contextualGroundingPolicy"].get("filters", [])
        ]
    }

# --- add our topic (idempotent) ---------------------------------------------------
existing = live.get("topicPolicy", {}).get("topics", [])
topics = [
    {k: t[k] for k in ("name", "definition", "examples", "type") if k in t}
    for t in existing
]
if any(t.get("name") == topic_name for t in topics):
    sys.exit(3)   # nothing to do — the caller turns this into a clean no-op
else:
    topics.append({
        "name": topic_name,
        "definition": (
            "Requests for personalized financial or investment advice, including whether to "
            "buy, sell, or hold specific securities, funds, or crypto assets."
        ),
        "examples": [
            "Should I buy Tesla stock right now?",
            "Is now a good time to move my 401k into bonds?",
            "Which crypto should I invest my savings in?",
        ],
        "type": "DENY",
    })
req["topicPolicyConfig"] = {"topicsConfig": topics}

json.dump(req, sys.stdout, indent=2)
' <<<"$LIVE")"
rc=$?
set -e
case "$rc" in
  0) ;;
  3) echo "✓ topic '${TOPIC_NAME}' already present on guardrail ${ID} — nothing to do"; exit 0 ;;
  *) exit "$rc" ;;   # python printed the reason on stderr
esac

if [ "$APPLY" != "true" ]; then
  echo ""
  echo "--- DRY RUN. This is the full update-guardrail payload (every policy re-sent): ---"
  printf '%s\n' "$PAYLOAD"
  echo "--------------------------------------------------------------------------------"
  echo ""
  echo "Review it, then apply with:"
  echo "  APPLY=true bash bundles/llmroute-bedrock-guardrails/helpers/add-denied-topic.sh"
  exit 0
fi

echo "==> adding DENY topic '${TOPIC_NAME}' to guardrail ${ID}"
tmp="$(mktemp -t guardrail-update)"
trap 'rm -f "$tmp"' EXIT
printf '%s' "$PAYLOAD" > "$tmp"
aws bedrock update-guardrail --guardrail-identifier "$ID" --region "$REGION" \
  --cli-input-json "file://$tmp" >/dev/null

echo "==> waiting for READY"
for _ in $(seq 1 30); do
  st="$(aws bedrock get-guardrail --guardrail-identifier "$ID" --guardrail-version DRAFT \
          --region "$REGION" --query status --output text)"
  [ "$st" = "READY" ] && break
  sleep 2
done
echo "✓ guardrail ${ID} status=${st} — topic '${TOPIC_NAME}' added"
echo "  Verify:  aws bedrock get-guardrail --guardrail-identifier ${ID} --guardrail-version DRAFT \\"
echo "             --region ${REGION} --query 'topicPolicy.topics[].name'"
