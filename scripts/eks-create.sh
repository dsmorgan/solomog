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
#   AWS_REGION     default us-east-1
#   EKS_VERSION    Kubernetes version           default 1.31
#   EKS_NODES      managed node count           default 2
#   EKS_NODE_TYPE  instance type                default m5.large
#
# Prereqs: eksctl, aws CLI with creds IN THE SHELL (export AWS_PROFILE + eval export-credentials),
# kubectl. One-time: `aws configure sso` if you haven't.

CLUSTER="${CLUSTER:-}"
: "${CLUSTER:?set CLUSTER=<eks-cluster-name> — this provisions a real EKS cluster, so no default}"

# Resolve + EXPORT region so every aws/eksctl call uses it (the task passes AWS_REGION=""; an empty
# AWS_REGION makes the CLI build bad endpoints — same trap fixed in eks-irsa.sh).
REGION="${AWS_REGION:-us-east-1}"
[ -z "$REGION" ] && REGION="us-east-1"
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"

VERSION="${EKS_VERSION:-1.31}"
NODES="${EKS_NODES:-2}"
NODE_TYPE="${EKS_NODE_TYPE:-m5.large}"

command -v eksctl  >/dev/null || { echo "Error: eksctl not found (brew install eksctl)." >&2; exit 1; }
command -v aws     >/dev/null || { echo "Error: aws CLI not found." >&2; exit 1; }
command -v kubectl >/dev/null || { echo "Error: kubectl not found." >&2; exit 1; }

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)" \
  || { echo "Error: 'aws sts get-caller-identity' failed — put AWS creds in the shell first" >&2;
       echo "       (export AWS_PROFILE + eval \"\$(aws configure export-credentials --format env)\")." >&2; exit 1; }

echo "==> EKS cluster '${CLUSTER}' in ${REGION} (account ${ACCOUNT}): k8s ${VERSION}, ${NODES}x ${NODE_TYPE}"

if aws eks describe-cluster --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1; then
  echo "    cluster already exists — skipping create, just (re)registering the context"
else
  echo "==> eksctl create cluster (this takes ~15-20 min)"
  eksctl create cluster \
    --name "$CLUSTER" --region "$REGION" --version "$VERSION" \
    --nodes "$NODES" --node-type "$NODE_TYPE" --managed --with-oidc
fi

echo "==> registering kube context"
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"
CTX="arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${CLUSTER}"

echo ""
echo "✓ EKS cluster ready — context: ${CTX}"
echo "  Next (thread this CONTEXT through the flow):"
echo "    solomog agentgateway CONTEXT=${CTX}"
echo "    solomog expose       CONTEXT=${CTX}         # public LB + self-signed TLS"
echo "    solomog apply BUNDLE=<bundle> CONTEXT=${CTX}"
echo "    solomog eks:irsa     CONTEXT=${CTX}         # keyless AWS identity for the proxy"
