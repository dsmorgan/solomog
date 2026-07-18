#!/usr/bin/env bash
set -euo pipefail
#
# Give the agentgateway proxy a KEYLESS AWS identity on EKS via IRSA, replacing the short-lived
# SSO temp creds the 30-/05- bundle hooks inject as env (they expire every ≤12h and need a
# `aws:refresh` + rollout restart — the recurring demo pain). After this, the proxy signs SigV4
# to AgentCore with an IAM role assumed through the cluster's OIDC provider — nothing to rotate.
#
# This is uc05 "Trust path A". It MUTATES AWS IAM (creates a policy + role) and the proxy
# Deployment. Idempotent / re-runnable. EKS only (needs CONTEXT set to an external context).
#
# Env:
#   CONTEXT   (required) external EKS kube context, e.g. arn:aws:eks:us-east-1:<acct>:cluster/<name>
#   CLUSTER   ignored when CONTEXT is set (label only)
#   GATEWAY   proxy Deployment name (default: agw); its ServiceAccount is auto-detected
#   AWS_REGION  default us-east-1 (or derived from the context ARN)
#   AGENTCORE_RUNTIME_ARN[_2]  runtime ARNs to scope the invoke policy to (from .env). If unset,
#                              falls back to a runtime/* wildcard in the account/region.
#
# Prereqs: aws CLI with creds IN THE SHELL (export AWS_PROFILE + eval export-credentials — same
# as any agentcore/eksctl step), eksctl, kubectl, jq.
#
# To revert to env creds: re-run the bundle's cred hook (solomog aws:refresh apply BUNDLE=...),
# remove the SA annotation (`kubectl annotate sa <sa> -n <ns> eks.amazonaws.com/role-arn-`), and
# restart. The IAM role/policy can be left in place (harmless) or deleted manually.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/target.sh
source "$REPO_DIR/scripts/lib/target.sh"

CLUSTER="${CLUSTER:-}"
solomog_require_external "$CLUSTER" "eks:irsa"
CTX="$(solomog_context "$CLUSTER")"

GW="${GATEWAY:-agw}"
NS=agentgateway-system
CLUSTER_NAME="${CTX##*/}"                      # arn:...:cluster/NAME → NAME
# region: prefer AWS_REGION, else field 4 of the context ARN (arn:aws:eks:<region>:...)
REGION="${AWS_REGION:-}"
if [ -z "$REGION" ]; then REGION="$(printf '%s' "$CTX" | cut -d: -f4)"; fi
REGION="${REGION:-us-east-1}"
# Export it so every `aws` call uses it. The task passes AWS_REGION="" (its `default ""`), and an
# EMPTY AWS_REGION makes the CLI build "sts..amazonaws.com" (Invalid endpoint) — worse than unset.
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"

command -v aws    >/dev/null || { echo "Error: aws CLI not found." >&2; exit 1; }
command -v eksctl >/dev/null || { echo "Error: eksctl not found (brew install eksctl)." >&2; exit 1; }

echo "==> IRSA for proxy '${GW}' on ${CLUSTER_NAME} (${REGION}), context ${CTX}"

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)" \
  || { echo "Error: 'aws sts get-caller-identity' failed — ensure AWS creds are in the shell" >&2;
       echo "       (export AWS_PROFILE + eval \"\$(aws configure export-credentials --format env)\")." >&2; exit 1; }
SA="$(kubectl --context "$CTX" -n "$NS" get deploy "$GW" -o jsonpath='{.spec.template.spec.serviceAccountName}')"
: "${SA:?could not detect the proxy ServiceAccount from deploy/${GW}}"
echo "    account=${ACCOUNT}  serviceAccount=${NS}/${SA}"

# ── 1. OIDC provider ─────────────────────────────────────────────────────────
ISSUER="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
  --query 'cluster.identity.oidc.issuer' --output text)"
OIDC_HOST="${ISSUER#https://}"                 # oidc.eks.<region>.amazonaws.com/id/<ID>
if ! aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' --output text \
     | tr '\t' '\n' | grep -q "$OIDC_HOST"; then
  echo "==> associating IAM OIDC provider for the cluster"
  eksctl utils associate-iam-oidc-provider --cluster "$CLUSTER_NAME" --region "$REGION" --approve
else
  echo "    IAM OIDC provider already present"
fi
OIDC_ARN="arn:aws:iam::${ACCOUNT}:oidc-provider/${OIDC_HOST}"

# ── 2. permissions policy (InvokeAgentRuntime, scoped to the runtimes) ────────
# Build the resource list from the runtime ARNs in .env, wildcarding the churny -<id> suffix
# (runtime/<name>-* survives redeploys). Fall back to all runtimes in-account/region.
RESOURCES=""
add_res() { local a="$1"; RESOURCES="${RESOURCES:+$RESOURCES,}\"${a%-*}-*\""; }
[ -n "${AGENTCORE_RUNTIME_ARN:-}" ]   && add_res "$AGENTCORE_RUNTIME_ARN"
[ -n "${AGENTCORE_RUNTIME_ARN_2:-}" ] && add_res "$AGENTCORE_RUNTIME_ARN_2"
[ -z "$RESOURCES" ] && RESOURCES="\"arn:aws:bedrock-agentcore:${REGION}:${ACCOUNT}:runtime/*\""
echo "    invoke policy resources: ${RESOURCES}"

POLICY_NAME="solomog-${CLUSTER_NAME}-agentcore-invoke"
POLICY_ARN="arn:aws:iam::${ACCOUNT}:policy/${POLICY_NAME}"
POLICY_DOC="$(cat <<EOF
{"Version":"2012-10-17","Statement":[{"Sid":"InvokeAgentCoreRuntime","Effect":"Allow","Action":["bedrock-agentcore:InvokeAgentRuntime","bedrock-agentcore:InvokeAgentRuntimeForUser"],"Resource":[${RESOURCES}]}]}
EOF
)"
if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  echo "==> updating policy ${POLICY_NAME} (new default version)"
  aws iam create-policy-version --policy-arn "$POLICY_ARN" \
    --policy-document "$POLICY_DOC" --set-as-default >/dev/null
else
  echo "==> creating policy ${POLICY_NAME}"
  aws iam create-policy --policy-name "$POLICY_NAME" --policy-document "$POLICY_DOC" >/dev/null
fi

# ── 3. role + web-identity trust (scoped to this SA) ──────────────────────────
ROLE_NAME="solomog-${CLUSTER_NAME}-${GW}"
TRUST_DOC="$(cat <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Federated":"${OIDC_ARN}"},"Action":"sts:AssumeRoleWithWebIdentity","Condition":{"StringEquals":{"${OIDC_HOST}:aud":"sts.amazonaws.com","${OIDC_HOST}:sub":"system:serviceaccount:${NS}:${SA}"}}}]}
EOF
)"
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "==> updating trust policy on role ${ROLE_NAME}"
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document "$TRUST_DOC"
else
  echo "==> creating role ${ROLE_NAME}"
  aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$TRUST_DOC" >/dev/null
fi
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN"
ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${ROLE_NAME}"

# ── 4. wire the SA → role, drop the static env creds, restart ─────────────────
echo "==> annotating ServiceAccount ${NS}/${SA} with the role"
kubectl --context "$CTX" -n "$NS" annotate sa "$SA" \
  "eks.amazonaws.com/role-arn=${ROLE_ARN}" --overwrite

# Static env creds would OVERRIDE web-identity in the SDK chain — remove them so IRSA takes over.
# (Leaves AWS_REGION alone; the `-` suffix removes an env var if present, no-op otherwise.)
echo "==> removing injected static AWS creds from deploy/${GW} (IRSA replaces them)"
kubectl --context "$CTX" -n "$NS" set env deploy/"$GW" \
  AWS_ACCESS_KEY_ID- AWS_SECRET_ACCESS_KEY- AWS_SESSION_TOKEN- >/dev/null

kubectl --context "$CTX" -n "$NS" rollout restart deploy/"$GW"
kubectl --context "$CTX" -n "$NS" rollout status  deploy/"$GW" --timeout=120s

echo ""
echo "✓ IRSA wired: ${NS}/${SA} → ${ROLE_ARN}"
echo "  The proxy now signs to AgentCore with a keyless role — no more ≤12h cred expiry."
echo "  (The bundle 05-/30- cred hooks are now unnecessary on this cluster.)"
echo "  Verify (the proxy image is distroless, so read the pod spec, not \`exec env\`):"
echo "    kubectl --context $CTX -n $NS get pods -o yaml | grep -E 'AWS_ROLE_ARN|AWS_WEB_IDENTITY|AWS_ACCESS_KEY_ID'"
echo "    → expect AWS_ROLE_ARN + AWS_WEB_IDENTITY_TOKEN_FILE, and NO AWS_ACCESS_KEY_ID"
