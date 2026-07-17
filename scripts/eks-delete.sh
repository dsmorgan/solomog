#!/usr/bin/env bash
set -euo pipefail
#
# Safely tear down an EKS cluster solomog installed onto — the complement to eks:create.
#
# The trap this avoids: the Gateway's LoadBalancer Service creates an AWS ELB (+ ENIs + a
# k8s-elb-* SG) inside the cluster VPC. `eksctl delete cluster` does NOT clean those up, so the
# ENIs pin the subnets and the VPC delete fails (stack DELETE_FAILED) → orphaned VPC → burns a
# slot against the account VPC quota. So here we DELETE THE GATEWAYS / LB SERVICES FIRST, wait for
# AWS to drop the ELBs, THEN eksctl delete — and finally deregister from .solomog/contexts.
#
# Also self-heals the orphan case: any load balancers still in the cluster's VPC are deleted, and
# if eksctl can't run (control plane already gone) the eksctl-<name>-* CloudFormation stacks are
# deleted directly (disabling termination protection first).
#
# MUTATES AWS (deletes the cluster). EKS only. Requires aws creds IN THE SHELL + eksctl.
#
# Env:
#   CLUSTER    (required) the registered EKS cluster name (or set CONTEXT). No default — destructive.
#   AWS_REGION default: derived from the context ARN, else us-east-1
#   GATEWAY    gateway name (default agw) — informational; all Gateways + LB Services are removed

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/target.sh
source "$REPO_DIR/scripts/lib/target.sh"

CLUSTER="${CLUSTER:-}"
: "${CLUSTER:?set CLUSTER=<eks-cluster-name> — this DELETES a real EKS cluster, so no default}"
CTX="$(solomog_context "$CLUSTER")"
if ! solomog_is_external "$CLUSTER"; then
  echo "Error: eks:delete is for external EKS clusters (CLUSTER registered via eks:create, or CONTEXT set)." >&2
  echo "       For vind clusters use teardown/vind-teardown.sh." >&2
  exit 1
fi

CLUSTER_NAME="${CTX##*/}"                       # arn:...:cluster/NAME → NAME (the eksctl name)
REGION="${AWS_REGION:-}"; [ -z "$REGION" ] && REGION="$(printf '%s' "$CTX" | cut -d: -f4)"
REGION="${REGION:-us-east-1}"
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"

command -v aws    >/dev/null || { echo "Error: aws CLI not found." >&2; exit 1; }
command -v eksctl >/dev/null || { echo "Error: eksctl not found (brew install eksctl)." >&2; exit 1; }
aws sts get-caller-identity >/dev/null 2>&1 \
  || { echo "Error: no AWS creds in the shell (export AWS_PROFILE + eval export-credentials)." >&2; exit 1; }

echo "==> DELETING EKS cluster '${CLUSTER_NAME}' in ${REGION} (context ${CTX})"

# Find the cluster VPC by the eksctl tag — works even if the control plane is already gone.
VPC="$(aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=tag:alpha.eksctl.io/cluster-name,Values=${CLUSTER_NAME}" \
  --query 'Vpcs[0].VpcId' --output text 2>/dev/null || true)"
[ "$VPC" = "None" ] && VPC=""
echo "    cluster VPC: ${VPC:-<none found>}"

# 1. Delete Gateways + any LoadBalancer Services so AWS tears down the ELBs (frees the ENIs).
if kubectl --context "$CTX" version >/dev/null 2>&1; then
  echo "==> deleting Gateways + LoadBalancer Services (releases the ELBs)"
  kubectl --context "$CTX" delete gateway --all -A --ignore-not-found --timeout=60s 2>/dev/null || true
  kubectl --context "$CTX" get svc -A -o json 2>/dev/null \
    | jq -r '.items[] | select(.spec.type=="LoadBalancer") | "\(.metadata.namespace) \(.metadata.name)"' \
    | while read -r ns name; do
        [ -n "$name" ] && kubectl --context "$CTX" -n "$ns" delete svc "$name" --ignore-not-found 2>/dev/null || true
      done
else
  echo "    cluster API not reachable (already partly gone) — skipping in-cluster cleanup"
fi

# 2. Proactively delete any load balancers still in the VPC (covers orphans + in-flight teardown).
delete_lbs_in_vpc() {   # args: <vpc>
  local vpc="$1" name arn
  [ -z "$vpc" ] && return 0
  for name in $(aws elb describe-load-balancers --region "$REGION" \
      --query "LoadBalancerDescriptions[?VPCId=='$vpc'].LoadBalancerName" --output text 2>/dev/null); do
    echo "    deleting classic ELB $name"
    aws elb delete-load-balancer --region "$REGION" --load-balancer-name "$name" 2>/dev/null || true
  done
  for arn in $(aws elbv2 describe-load-balancers --region "$REGION" \
      --query "LoadBalancers[?VpcId=='$vpc'].LoadBalancerArn" --output text 2>/dev/null); do
    echo "    deleting v2 LB $arn"
    aws elbv2 delete-load-balancer --region "$REGION" --load-balancer-arn "$arn" 2>/dev/null || true
  done
}

# 3. Wait until no load balancers remain in the VPC (ELB deletion is what frees the subnets).
if [ -n "$VPC" ]; then
  echo "==> waiting for load balancers to drain from ${VPC}"
  elapsed=0
  while [ $elapsed -lt 180 ]; do
    delete_lbs_in_vpc "$VPC"
    c1=$(aws elb describe-load-balancers --region "$REGION" --query "length(LoadBalancerDescriptions[?VPCId=='$VPC'])" --output text 2>/dev/null || echo 0)
    c2=$(aws elbv2 describe-load-balancers --region "$REGION" --query "length(LoadBalancers[?VpcId=='$VPC'])" --output text 2>/dev/null || echo 0)
    [ "$c1" = "0" ] && [ "$c2" = "0" ] && { echo "    load balancers gone"; break; }
    echo "    still draining (elb=$c1 elbv2=$c2)... (${elapsed}s)"; sleep 15; elapsed=$((elapsed + 15))
  done
fi

# 4. Delete the cluster. eksctl is the clean path (handles both CFN stacks + termination protection);
#    if the control plane is already gone, fall back to deleting the eksctl-<name>-* stacks directly.
echo "==> eksctl delete cluster ${CLUSTER_NAME}"
if ! eksctl delete cluster --name "$CLUSTER_NAME" --region "$REGION" --disable-nodegroup-eviction 2>&1; then
  echo "==> eksctl delete didn't complete — cleaning any leftover eksctl-${CLUSTER_NAME}-* CFN stacks directly"
  for stack in $(aws cloudformation describe-stacks --region "$REGION" \
      --query "Stacks[?starts_with(StackName,'eksctl-${CLUSTER_NAME}-')].StackName" --output text 2>/dev/null); do
    echo "    stack ${stack}: disabling termination protection + deleting"
    aws cloudformation update-termination-protection --region "$REGION" \
      --stack-name "$stack" --no-enable-termination-protection 2>/dev/null || true
    aws cloudformation delete-stack --region "$REGION" --stack-name "$stack" 2>/dev/null || true
  done
  echo "    (stack deletion is async — check: aws cloudformation describe-stacks --stack-name eksctl-${CLUSTER_NAME}-cluster)"
fi

# 5. Deregister from the context registry.
solomog_deregister_context "$CLUSTER"

echo ""
echo "✓ teardown initiated for '${CLUSTER_NAME}'."
echo "  Verify the VPC is freed:  aws ec2 describe-vpcs --region ${REGION} --filters Name=tag:alpha.eksctl.io/cluster-name,Values=${CLUSTER_NAME} --query 'Vpcs[].VpcId'"
