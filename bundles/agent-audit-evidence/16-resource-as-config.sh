# Config + secrets for the leg-2 resource authorization server, and the gateway's leg-1/leg-2
# client credentials.
#
# Creates, in agent-evidence (the workload namespace):
#   * Secret    evidence-resource-as-signing   RSA key the AS signs the final token with (reused)
#   * ConfigMap evidence-resource-as-env       non-secret settings
#   * Secret    evidence-resource-as-client    the leg-2 client secret, as the AS expects it
# and, in agentgateway-system (where the gateway policies live):
#   * Secret    evidence-resource-client       the SAME leg-2 secret, for crossAppAccess leg 2
#   * Secret    evidence-priorauth-key / evidence-intake-key   the two agents' leg-1 PEM keys
#     (or evidence-priorauth / evidence-intake client secrets when XAA_AGENT_AUTH is not PrivateKeyJwt)
#
# The Okta side is shared with any other Cross App Access bundle on the same tenant, so those facts
# keep their XAA_* names. Everything this bundle decides for itself is EVIDENCE_*.
#
# .env / knobs (Okta, shared):
#   OKTA_DOMAIN               required  Okta org host, no scheme
#   XAA_AGENT_A_CLIENT_ID     required  priorauth-agent's Okta AI Agent id (wlp…)
#   XAA_AGENT_B_CLIENT_ID     required  intake-agent's Okta AI Agent id
#   XAA_AGENT_AUTH            optional  PrivateKeyJwt (AI Agents) | ClientSecretBasic | ClientSecretPost
#   XAA_AGENT_A_PRIVATE_KEY / XAA_AGENT_B_PRIVATE_KEY   PEM paths, when PrivateKeyJwt
#   XAA_AGENT_A_CLIENT_SECRET / XAA_AGENT_B_CLIENT_SECRET  otherwise
# .env / knobs (this bundle):
#   EVIDENCE_RESOURCE_AS_ISSUER  must equal the "Issuer URL" on the Okta resource app's Resource
#                                Server tab: Okta mints the ID-JAG with that as `aud`.
#                                default https://evidence-resource-as.agent-evidence.svc.cluster.local
#   EVIDENCE_RESOURCE_API        final token `aud` (default https://claims.evidence.test/mcp)
#   EVIDENCE_PRIORAUTH_ACTOR     the "Client ID at the Resource Authorization Server" on
#                                priorauth-agent's Okta connection (default priorauth-agent)
#   EVIDENCE_INTAKE_ACTOR        same for intake-agent (default intake-agent)
#   EVIDENCE_REVIEWERS           emails granted EVIDENCE_REVIEWER_GROUP (default XAA_PRIVILEGED_USERS)
#   EVIDENCE_REVIEWER_GROUP      default priorauth-reviewer
#   EVIDENCE_DEFAULT_GROUP       everyone else (default claims-staff)
# CONTEXT exported by apply-bundle.sh.
set -euo pipefail

: "${OKTA_DOMAIN:?set OKTA_DOMAIN in .env — Okta org host, no https://}"
: "${XAA_AGENT_A_CLIENT_ID:?set XAA_AGENT_A_CLIENT_ID in .env — priorauth-agent Okta AI Agent id (docs/OKTA-SETUP.md)}"
: "${XAA_AGENT_B_CLIENT_ID:?set XAA_AGENT_B_CLIENT_ID in .env — intake-agent Okta AI Agent id}"

NS=agent-evidence
GW_NS=agentgateway-system
AGENT_AUTH="${XAA_AGENT_AUTH:-ClientSecretBasic}"
ISSUER="${EVIDENCE_RESOURCE_AS_ISSUER:-https://evidence-resource-as.agent-evidence.svc.cluster.local}"
RESOURCE_API="${EVIDENCE_RESOURCE_API:-https://claims.evidence.test/mcp}"
RESOURCE_CLIENT_ID="${EVIDENCE_RESOURCE_CLIENT_ID:-evidence-gateway}"
PRIORAUTH_ACTOR="${EVIDENCE_PRIORAUTH_ACTOR:-priorauth-agent}"
INTAKE_ACTOR="${EVIDENCE_INTAKE_ACTOR:-intake-agent}"
REVIEWERS="${EVIDENCE_REVIEWERS:-${XAA_PRIVILEGED_USERS:-}}"
REVIEWER_GROUP="${EVIDENCE_REVIEWER_GROUP:-priorauth-reviewer}"
DEFAULT_GROUP="${EVIDENCE_DEFAULT_GROUP:-claims-staff}"
KEY_SECRET=evidence-resource-as-signing

if [ "$AGENT_AUTH" = "PrivateKeyJwt" ]; then
  : "${XAA_AGENT_A_PRIVATE_KEY:?XAA_AGENT_AUTH=PrivateKeyJwt needs XAA_AGENT_A_PRIVATE_KEY (PEM path)}"
  : "${XAA_AGENT_B_PRIVATE_KEY:?XAA_AGENT_AUTH=PrivateKeyJwt needs XAA_AGENT_B_PRIVATE_KEY (PEM path)}"
  for f in "$XAA_AGENT_A_PRIVATE_KEY" "$XAA_AGENT_B_PRIVATE_KEY"; do
    [ -r "$f" ] || { echo "✗ cannot read ${f}" >&2; exit 1; }
    grep -q 'BEGIN .*PRIVATE KEY' "$f" || { echo "✗ ${f} is not a PEM key; convert a JWK with helpers/xaa-jwk-to-pem.sh" >&2; exit 1; }
  done
else
  : "${XAA_AGENT_A_CLIENT_SECRET:?set XAA_AGENT_A_CLIENT_SECRET (or XAA_AGENT_AUTH=PrivateKeyJwt)}"
  : "${XAA_AGENT_B_CLIENT_SECRET:?set XAA_AGENT_B_CLIENT_SECRET}"
fi

# Reviewer entitlements, resolved resource-side: Okta cannot carry `groups` in an ID-JAG.
ENTITLEMENTS=$(
  printf '{'
  for u in $(printf '%s' "$REVIEWERS" | tr ',' ' '); do printf '"%s":["%s"],' "$u" "$REVIEWER_GROUP"; done
  printf '"*":["%s"]}' "$DEFAULT_GROUP"
)

echo "==> resource AS config (issuer ${ISSUER}, token aud ${RESOURCE_API})"

if kubectl --context "$CONTEXT" -n "$NS" get secret "$KEY_SECRET" >/dev/null 2>&1; then
  echo "    signing key: reusing Secret ${KEY_SECRET} (delete it to rotate)"
else
  TMPKEY="$(mktemp -t evidence-signing)"
  trap 'rm -f "$TMPKEY"' EXIT
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$TMPKEY" 2>/dev/null
  kubectl --context "$CONTEXT" create secret generic "$KEY_SECRET" -n "$NS" \
    --from-file=private.pem="$TMPKEY" --from-literal=kid="evidence-$(date +%Y%m%d%H%M%S)" \
    --dry-run=client -o yaml | kubectl --context "$CONTEXT" apply -f -
fi
SIGNING_KID=$(kubectl --context "$CONTEXT" -n "$NS" get secret "$KEY_SECRET" -o jsonpath='{.data.kid}' | base64 -d)

# Leg-2 client secret: ours on both ends. Reuse, else generate.
if kubectl --context "$CONTEXT" -n "$NS" get secret evidence-resource-as-client >/dev/null 2>&1; then
  RESOURCE_CLIENT_SECRET=$(kubectl --context "$CONTEXT" -n "$NS" get secret evidence-resource-as-client \
    -o jsonpath='{.data.RESOURCE_CLIENT_SECRET}' | base64 -d)
else
  RESOURCE_CLIENT_SECRET=$(openssl rand -hex 24)
fi

kubectl --context "$CONTEXT" create configmap evidence-resource-as-env -n "$NS" \
  --from-literal=OKTA_DOMAIN="$OKTA_DOMAIN" \
  --from-literal=RESOURCE_AS_ISSUER="$ISSUER" \
  --from-literal=RESOURCE_API_AUDIENCE="$RESOURCE_API" \
  --from-literal=RESOURCE_CLIENT_ID="$RESOURCE_CLIENT_ID" \
  --from-literal=SIGNING_KEY_PATH=/signing/private.pem \
  --from-literal=SIGNING_KID="$SIGNING_KID" \
  --from-literal=ENTITLEMENTS="$ENTITLEMENTS" \
  --from-literal=ACT_MODE=named \
  --from-literal=IDJAG_MAX_AGE_SECONDS=30 \
  --from-literal=ALLOWED_ACTORS="${PRIORAUTH_ACTOR},${INTAKE_ACTOR}" \
  --from-literal=STRICT_TYP=true \
  --dry-run=client -o yaml | kubectl --context "$CONTEXT" apply -f -

kubectl --context "$CONTEXT" create secret generic evidence-resource-as-client -n "$NS" \
  --from-literal=RESOURCE_CLIENT_SECRET="$RESOURCE_CLIENT_SECRET" \
  --dry-run=client -o yaml | kubectl --context "$CONTEXT" apply -f -
kubectl --context "$CONTEXT" create secret generic evidence-resource-client -n "$GW_NS" \
  --from-literal=client_secret="$RESOURCE_CLIENT_SECRET" \
  --dry-run=client -o yaml | kubectl --context "$CONTEXT" apply -f -

if [ "$AGENT_AUTH" = "PrivateKeyJwt" ]; then
  kubectl --context "$CONTEXT" create secret generic evidence-priorauth-key -n "$GW_NS" \
    --from-file=private_key="$XAA_AGENT_A_PRIVATE_KEY" --dry-run=client -o yaml | kubectl --context "$CONTEXT" apply -f -
  kubectl --context "$CONTEXT" create secret generic evidence-intake-key -n "$GW_NS" \
    --from-file=private_key="$XAA_AGENT_B_PRIVATE_KEY" --dry-run=client -o yaml | kubectl --context "$CONTEXT" apply -f -
else
  kubectl --context "$CONTEXT" create secret generic evidence-priorauth -n "$GW_NS" \
    --from-literal=client_secret="$XAA_AGENT_A_CLIENT_SECRET" --dry-run=client -o yaml | kubectl --context "$CONTEXT" apply -f -
  kubectl --context "$CONTEXT" create secret generic evidence-intake -n "$GW_NS" \
    --from-literal=client_secret="$XAA_AGENT_B_CLIENT_SECRET" --dry-run=client -o yaml | kubectl --context "$CONTEXT" apply -f -
fi

# envFrom is read at pod start, so a config change needs a restart. Harmless on first apply.
kubectl --context "$CONTEXT" -n "$NS" rollout restart deploy/evidence-resource-as 2>/dev/null || true

echo "✓ resource AS config applied (kid ${SIGNING_KID}, act mode named)"
echo "  actors:       priorauth=${PRIORAUTH_ACTOR}  intake=${INTAKE_ACTOR}"
echo "  entitlements: ${ENTITLEMENTS}"
