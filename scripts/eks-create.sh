#!/usr/bin/env bash
set -euo pipefail
#
# Create the EKS cluster for the agentgateway EKS tier (folds phase4a-eks-runbook steps 1-2 into
# solomog). Runs `eksctl create cluster --with-oidc` then `aws eks update-kubeconfig`, and prints
# the resulting kube CONTEXT to hand to the rest of the flow (agentgateway → expose → apply →
# eks:irsa). Idempotent: if the cluster already exists it skips create and just (re)registers the
# context. Provisions REAL infra (~15-20 min, costs $) — David runs it.
#
# `--with-oidc` registers the IAM OIDC provider now, which `eks:irsa` needs later.
#
# Env:
#   CLUSTER        EKS cluster NAME (required — no vind default here; this makes a real cluster)
#   EKS_REGION     region for the cluster       preferred, explicit knob; falls back to AWS_REGION
#   AWS_REGION     region (fallback)            default us-east-1 if neither is set
#   EKS_VERSION    Kubernetes version           pinned in versions.env (EKS_VERSION), fallback 1.34
#   EKS_NODES      managed node count           default 2
#   EKS_NODE_TYPE  instance type                default m5.large (m8i.xlarge with EKS_NESTED_VIRT)
#   EKS_NESTED_VIRT  true = nodes expose /dev/kvm  default false. Launches the node group from a
#                  launch template with CpuOptions.NestedVirtualization=enabled, for microVM
#                  sandboxes (Cloud Hypervisor, Kata) without metal instances. EC2 offers it on
#                  m8i, c8i and r8i only. eks:delete removes the launch template.
#   OWNER          owner tag value (from .env)  default "solomog" — attributes the cluster
#
# Prereqs: eksctl, aws CLI with creds IN THE SHELL (export AWS_PROFILE + eval export-credentials),
# kubectl. One-time: `aws configure sso` if you haven't.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/target.sh
source "$REPO_DIR/scripts/lib/target.sh"

CLUSTER="${CLUSTER:-}"
: "${CLUSTER:?set CLUSTER=<eks-cluster-name> — this provisions a real EKS cluster, so no default}"

# Resolve + EXPORT region so every aws/eksctl call uses it. Prefer EKS_REGION (the explicit
# cluster-region knob) over AWS_REGION (which also drives the agentcore CLI toward the runtime's
# region, so we don't want to overload it in .env). The task passes both as "" when unset; an empty
# AWS_REGION makes the CLI build bad endpoints — same trap fixed in eks-irsa.sh.
REGION="${EKS_REGION:-${AWS_REGION:-}}"
if [ -n "${EKS_REGION:-}" ]; then   REGION_SRC="EKS_REGION"
elif [ -n "${AWS_REGION:-}" ]; then REGION_SRC="AWS_REGION"
else REGION="us-east-1";            REGION_SRC="DEFAULT (neither EKS_REGION nor AWS_REGION set)"; fi
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"

VERSION="${EKS_VERSION:-1.34}"   # normally supplied from versions.env via the task env
NODES="${EKS_NODES:-2}"
NESTED_VIRT="${EKS_NESTED_VIRT:-false}"
if [ "$NESTED_VIRT" = true ]; then NODE_TYPE="${EKS_NODE_TYPE:-m8i.xlarge}"; else NODE_TYPE="${EKS_NODE_TYPE:-m5.large}"; fi
case "$NESTED_VIRT:$NODE_TYPE" in
  false:*|true:m8i.*|true:c8i.*|true:r8i.*) ;;
  true:*) echo "Error: EKS_NESTED_VIRT=true needs an m8i, c8i or r8i instance type, got ${NODE_TYPE}." >&2; exit 1 ;;
  *) echo "Error: EKS_NESTED_VIRT must be true or false, got '${NESTED_VIRT}'." >&2; exit 1 ;;
esac
OWNER="${OWNER:-solomog}"        # owner tag (from .env); attributes the cluster in a shared account

command -v eksctl  >/dev/null || { echo "Error: eksctl not found (brew install eksctl)." >&2; exit 1; }
command -v kubectl >/dev/null || { echo "Error: kubectl not found." >&2; exit 1; }

solomog_aws_preflight "eks:create"   # reloads .env creds over stale shell copies; verifies via sts
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"

echo "==> EKS cluster '${CLUSTER}' in ${REGION} [region via ${REGION_SRC}] (account ${ACCOUNT}): k8s ${VERSION}, ${NODES}x ${NODE_TYPE}$([ "$NESTED_VIRT" = true ] && echo ", nested virtualization")"

# nested_virt_lt → the id of this cluster's launch template, created if absent. It carries only
# what the node group can't: the CPU option, plus the root volume and IMDSv2 settings EKS would
# otherwise default. No security groups, so EKS attaches the cluster security group.
nested_virt_lt() {
  local name="solomog-${CLUSTER}-nested-virt" id
  id="$(aws ec2 describe-launch-templates --launch-template-names "$name" --query 'LaunchTemplates[0].LaunchTemplateId' --output text 2>/dev/null || true)"
  if [ -z "$id" ] || [ "$id" = None ]; then
    id="$(aws ec2 create-launch-template --launch-template-name "$name" \
      --tag-specifications "ResourceType=launch-template,Tags=[{Key=owner,Value=${OWNER}}]" \
      --launch-template-data "{\"InstanceType\":\"${NODE_TYPE}\",\"CpuOptions\":{\"NestedVirtualization\":\"enabled\"},
        \"MetadataOptions\":{\"HttpTokens\":\"required\",\"HttpPutResponseHopLimit\":2},
        \"BlockDeviceMappings\":[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"VolumeSize\":80,\"VolumeType\":\"gp3\"}}],
        \"TagSpecifications\":[{\"ResourceType\":\"instance\",\"Tags\":[{\"Key\":\"owner\",\"Value\":\"${OWNER}\"}]}]}" \
      --query 'LaunchTemplate.LaunchTemplateId' --output text)"
    echo "    created launch template ${name} (${id})" >&2
  fi
  echo "$id"
}

if aws eks describe-cluster --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1; then
  echo "    cluster already exists — skipping create, just (re)registering the context"
  # Make sure the owner tag is present even on a pre-existing cluster.
  CLUSTER_ARN="$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" --query 'cluster.arn' --output text)"
  aws eks tag-resource --resource-arn "$CLUSTER_ARN" --tags "owner=${OWNER}" >/dev/null 2>&1 \
    && echo "    tagged owner=${OWNER}" || echo "    (could not tag owner — check perms)"
else
  echo "==> eksctl create cluster (this takes ~15-20 min), owner=${OWNER}"
  if [ "$NESTED_VIRT" = true ]; then
    # eksctl's flags can't set CPU options, so the node group comes from a config file that
    # names the launch template.
    LT="$(nested_virt_lt)"
    eksctl create cluster -f - <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: "${CLUSTER}"
  region: "${REGION}"
  version: "${VERSION}"
  tags:
    owner: "${OWNER}"
iam:
  withOIDC: true
managedNodeGroups:
  - name: nested-virt
    desiredCapacity: ${NODES}
    minSize: ${NODES}
    maxSize: ${NODES}
    launchTemplate:
      id: "${LT}"
EOF
  else
    eksctl create cluster \
      --name "$CLUSTER" --region "$REGION" --version "$VERSION" \
      --nodes "$NODES" --node-type "$NODE_TYPE" --managed --with-oidc \
      --tags "owner=${OWNER}"
  fi
fi

echo "==> registering kube context"
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"
CTX="arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${CLUSTER}"

# Record CLUSTER → CTX so the rest of solomog can just use CLUSTER=${CLUSTER} (no CONTEXT needed).
solomog_register_context "$CLUSTER" "$CTX"

echo ""
echo "✓ EKS cluster ready — context: ${CTX}"
echo "  Registered — now just use CLUSTER=${CLUSTER} for the rest of the flow:"
echo "    solomog eks:storage  CLUSTER=${CLUSTER}      # EBS CSI + default gp3 class, for any bundle with PVCs"
echo "    solomog agentgateway CLUSTER=${CLUSTER}"
echo "    solomog eks:irsa     CLUSTER=${CLUSTER}      # keyless AWS identity for the proxy"
echo "    solomog expose       CLUSTER=${CLUSTER}      # public LB + self-signed TLS"
echo "    solomog apply BUNDLE=<bundle> CLUSTER=${CLUSTER}"
