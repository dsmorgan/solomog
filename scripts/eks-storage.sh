#!/usr/bin/env bash
set -euo pipefail
#
# Give an EKS cluster a working default StorageClass: the EBS CSI driver add-on, an IRSA role for
# its controller, and a default gp3 StorageClass. Run it after eks:create, before any bundle that
# creates PersistentVolumeClaims.
#
# Why this is needed: a fresh EKS cluster cannot provision a volume. EBS provisioning goes through
# the EBS CSI driver, which EKS installs only as an opt-in add-on, and on clusters created at 1.30
# or later EKS no longer marks its gp2 StorageClass as default. A PVC that names no StorageClass —
# substrate's postgres and rustfs, kagent's postgres — then sits Pending with no event that says why.
#
# It MUTATES AWS IAM (creates a role) and the cluster (add-on + StorageClass). Idempotent.
# eks:delete removes the role and releases the volumes this driver created.
#
# Env:
#   CLUSTER     (required) registered EKS cluster name, or CONTEXT for an unregistered one
#   EKS_REGION  explicit cluster-region knob (preferred); falls back to AWS_REGION
#   AWS_REGION  default: derived from the context ARN, else us-east-1
#
# Prereqs: aws CLI creds (solomog aws:refresh, or exported in the shell), eksctl, kubectl, jq.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/target.sh
source "$REPO_DIR/scripts/lib/target.sh"

CLUSTER="${CLUSTER:-}"
solomog_require_external "$CLUSTER" "eks:storage"
CTX="$(solomog_context "$CLUSTER")"
CLUSTER_NAME="${CTX##*/}"                      # arn:...:cluster/NAME → NAME
REGION="${EKS_REGION:-${AWS_REGION:-}}"
if [ -z "$REGION" ]; then REGION="$(printf '%s' "$CTX" | cut -d: -f4)"; fi
REGION="${REGION:-us-east-1}"
# An EMPTY AWS_REGION (the task's default "") makes the CLI build invalid endpoints, so always export.
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"

ADDON=aws-ebs-csi-driver
SA_NS=kube-system
SA=ebs-csi-controller-sa                       # the add-on's fixed controller ServiceAccount
SC=gp3
ROLE_NAME="solomog-${CLUSTER_NAME}-ebs-csi"    # eks:delete removes a role by exactly this name
POLICY_ARN="arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"

command -v eksctl >/dev/null || { echo "Error: eksctl not found (brew install eksctl)." >&2; exit 1; }
command -v jq     >/dev/null || { echo "Error: jq not found." >&2; exit 1; }

echo "==> EBS storage for ${CLUSTER_NAME} (${REGION}), context ${CTX}"
solomog_aws_preflight "eks:storage"   # reloads .env creds over stale shell copies; verifies via sts
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"

# ── 1. OIDC provider ─────────────────────────────────────────────────────────
# eks:create registers it with --with-oidc; this covers a cluster made some other way.
ISSUER="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
  --query 'cluster.identity.oidc.issuer' --output text)"
OIDC_HOST="${ISSUER#https://}"
if ! aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' --output text \
     | tr '\t' '\n' | grep -q "$OIDC_HOST"; then
  echo "==> associating IAM OIDC provider for the cluster"
  eksctl utils associate-iam-oidc-provider --cluster "$CLUSTER_NAME" --region "$REGION" --approve
else
  echo "    IAM OIDC provider already present"
fi
OIDC_ARN="arn:aws:iam::${ACCOUNT}:oidc-provider/${OIDC_HOST}"

# ── 2. IRSA role for the CSI controller ──────────────────────────────────────
# The AWS-managed policy is the one AWS documents for this add-on; nothing here is custom.
TRUST_DOC="$(cat <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Federated":"${OIDC_ARN}"},"Action":"sts:AssumeRoleWithWebIdentity","Condition":{"StringEquals":{"${OIDC_HOST}:aud":"sts.amazonaws.com","${OIDC_HOST}:sub":"system:serviceaccount:${SA_NS}:${SA}"}}}]}
EOF
)"
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "==> updating trust policy on role ${ROLE_NAME}"
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document "$TRUST_DOC"
else
  echo "==> creating role ${ROLE_NAME}"
  aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$TRUST_DOC" \
    --tags "Key=owner,Value=${OWNER:-solomog}" >/dev/null
fi
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN"
ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${ROLE_NAME}"

# ── 3. the add-on ────────────────────────────────────────────────────────────
# OVERWRITE lets the add-on take over fields a previous manual install left behind.
if aws eks describe-addon --cluster-name "$CLUSTER_NAME" --addon-name "$ADDON" --region "$REGION" >/dev/null 2>&1; then
  echo "==> updating add-on ${ADDON} (role ${ROLE_NAME})"
  aws eks update-addon --cluster-name "$CLUSTER_NAME" --addon-name "$ADDON" --region "$REGION" \
    --service-account-role-arn "$ROLE_ARN" --resolve-conflicts OVERWRITE >/dev/null
else
  echo "==> creating add-on ${ADDON} (role ${ROLE_NAME})"
  aws eks create-addon --cluster-name "$CLUSTER_NAME" --addon-name "$ADDON" --region "$REGION" \
    --service-account-role-arn "$ROLE_ARN" --resolve-conflicts OVERWRITE >/dev/null
fi
echo "    waiting for ${ADDON} to become ACTIVE (a few minutes on a new cluster)"
if ! aws eks wait addon-active --cluster-name "$CLUSTER_NAME" --addon-name "$ADDON" --region "$REGION"; then
  echo "Error: ${ADDON} did not become ACTIVE. Its health issues:" >&2
  aws eks describe-addon --cluster-name "$CLUSTER_NAME" --addon-name "$ADDON" --region "$REGION" \
    --query 'addon.health.issues' --output json >&2 || true
  exit 1
fi

# ── 4. the default StorageClass ──────────────────────────────────────────────
# Exactly one class may carry the default annotation. With two, the apiserver picks the newest,
# which hides the mistake until someone else's cluster behaves differently — so strip it from any
# other class first.
for other in $(kubectl --context "$CTX" get storageclass -o json \
    | jq -r --arg sc "$SC" '.items[] | select(.metadata.name != $sc)
        | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true")
        | .metadata.name'); do
  echo "    removing the default annotation from StorageClass ${other}"
  kubectl --context "$CTX" annotate storageclass "$other" storageclass.kubernetes.io/is-default-class- >/dev/null
done

# WaitForFirstConsumer creates the volume in the scheduled pod's availability zone. Immediate
# binding picks a zone first and can strand the pod on nodes in another one.
kubectl --context "$CTX" apply -f - >/dev/null <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${SC}
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  encrypted: "true"
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOF
echo "    StorageClass ${SC} is the default"

# ── 5. prove it: one PVC, one pod, bound, then removed ───────────────────────
# A WaitForFirstConsumer PVC never binds without a pod, so a PVC alone proves nothing.
SMOKE_NS=solomog-storage-check
echo "==> smoke test: provisioning a 1Gi volume through the default class"
kubectl --context "$CTX" create namespace "$SMOKE_NS" --dry-run=client -o yaml \
  | kubectl --context "$CTX" apply -f - >/dev/null
kubectl --context "$CTX" -n "$SMOKE_NS" apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: check
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: check
spec:
  restartPolicy: Never
  containers:
    - name: check
      image: public.ecr.aws/docker/library/busybox:1.36
      command: ["sh", "-c", "echo ok > /data/ok && cat /data/ok"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: check
EOF
if kubectl --context "$CTX" -n "$SMOKE_NS" wait pvc/check --for=jsonpath='{.status.phase}'=Bound --timeout=180s >/dev/null \
   && kubectl --context "$CTX" -n "$SMOKE_NS" wait pod/check --for=jsonpath='{.status.phase}'=Succeeded --timeout=120s >/dev/null; then
  echo "    ✓ volume bound and written"
  SMOKE_OK=true
else
  SMOKE_OK=false
  echo "    ✗ smoke test failed. What the PVC and pod report:" >&2
  kubectl --context "$CTX" -n "$SMOKE_NS" describe pvc/check pod/check 2>&1 | sed -n '/^Events:/,$p' >&2 || true
fi
# Deleting the namespace deletes the PVC, and reclaimPolicy Delete then deletes the EBS volume.
kubectl --context "$CTX" delete namespace "$SMOKE_NS" --wait=false >/dev/null
[ "$SMOKE_OK" = true ] || exit 1

echo ""
echo "✓ EBS storage ready on ${CLUSTER_NAME}: ${ADDON} (role ${ROLE_NAME}), default StorageClass ${SC}"
echo "  Check:  kubectl --context ${CTX} get storageclass"
