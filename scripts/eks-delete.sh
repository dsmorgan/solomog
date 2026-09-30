#!/usr/bin/env bash
set -euo pipefail
#
# Safely tear down EKS cluster(s) solomog installed onto — the complement to eks:create.
#
# The trap this avoids: the Gateway's LoadBalancer Service creates an AWS ELB (+ ENIs + a
# k8s-elb-* SG) inside the cluster VPC. `eksctl delete cluster` does NOT clean those up, so the
# ENIs pin the subnets and the VPC delete fails (stack DELETE_FAILED) → orphaned VPC → burns a
# slot against the account VPC quota. So here we DELETE THE GATEWAYS / LB SERVICES FIRST, wait for
# AWS to drop the ELBs, THEN eksctl delete — then deregister from .solomog/contexts and remove the
# ARN-named kubeconfig entries (the vcluster-style context cleanup eksctl skips for those).
#
# Same idea for storage: namespaces holding PVCs are deleted first, so the EBS CSI driver deletes
# their volumes while it still runs, and the eks:storage IAM role is removed after the cluster.
#
# Also self-heals the orphan case: any load balancers still in the cluster's VPC are deleted, and
# if eksctl can't run (control plane already gone) the eksctl-<name>-* CloudFormation stacks are
# deleted directly (disabling termination protection first).
#
# MUTATES AWS (deletes the cluster). EKS only. Requires aws creds IN THE SHELL + eksctl.
#
# Env:
#   CLUSTER / CLUSTERS  registered EKS cluster name(s), space-separated (required — destructive).
#                       Non-eks names are refused (use that type's delete, or `solomog teardown`).
#                       CONTEXT= is the escape hatch for one unregistered kube context.
#   FORCE               "true" skips the confirmation prompt
#   EKS_REGION          explicit cluster-region knob (preferred); falls back to AWS_REGION
#   AWS_REGION          default: derived from the context ARN, else us-east-1
#   GATEWAY             gateway name (default agw) — informational; all Gateways + LB Services are removed

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/target.sh
source "$REPO_DIR/scripts/lib/target.sh"

CLUSTER="${CLUSTER:-${CLUSTERS:-}}"
solomog_require_cluster_list "$CLUSTER" "eks:delete"

NAMES=()
for n in $CLUSTER; do
  [ -n "$n" ] && NAMES+=("$n")
done

# Type-guard: every name must be registered eks, except CONTEXT= on a single
# unregistered name (the kube-context escape hatch).
if [ -n "${CONTEXT:-}" ]; then
  if [ "${#NAMES[@]}" -ne 1 ]; then
    echo "Error: CONTEXT= with eks:delete takes one CLUSTER name (one kube context)." >&2
    exit 1
  fi
  _typ="$(solomog_cluster_type "${NAMES[0]}")"
  case "$_typ" in
    eks|vind) ;;   # registered eks, or unregistered (CONTEXT supplies the kube context)
    *) solomog_require_kind "${NAMES[0]}" "eks" "eks:delete" ;;
  esac
else
  for n in "${NAMES[@]}"; do
    solomog_require_kind "$n" "eks" "eks:delete"
  done
fi

command -v eksctl >/dev/null || { echo "Error: eksctl not found (brew install eksctl)." >&2; exit 1; }
solomog_aws_preflight "eks:delete"   # reloads .env creds over stale shell copies; verifies via sts

echo "About to DESTROY EKS cluster(s) — real AWS resources: ${CLUSTER}"
if [ "${FORCE:-false}" != "true" ]; then
  printf "Proceed? [y/N] "
  read -r ANSWER
  [[ "$ANSWER" =~ ^[Yy] ]] || { echo "Aborted — nothing destroyed."; exit 1; }
fi

# REGION is set per cluster in delete_one; helpers close over it.
REGION=""

# Proactively delete any load balancers still in the VPC (covers orphans + in-flight teardown).
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

# Delete the orphaned k8s-elb-* security groups the ELB left behind. An SG is a VPC-level
# dependency, so a single leftover blocks the whole VPC delete (bit us once: the ELB and its ENIs
# were already gone but the SG remained → stack DELETE_FAILED on [VPC]). The SG can only be deleted
# after the ELB's ENIs drop, which lags the ELB delete by ~30-60s, so we retry on DependencyViolation.
delete_elb_sgs_in_vpc() {   # args: <vpc>
  local vpc="$1" sg tries err
  [ -z "$vpc" ] && return 0
  for sg in $(aws ec2 describe-security-groups --region "$REGION" \
      --filters "Name=vpc-id,Values=$vpc" \
      --query "SecurityGroups[?starts_with(GroupName,'k8s-elb-')].GroupId" --output text 2>/dev/null); do
    for tries in 1 2 3 4 5 6; do
      if err="$(aws ec2 delete-security-group --region "$REGION" --group-id "$sg" 2>&1)"; then
        echo "    deleted orphaned ELB SG $sg"; break
      fi
      case "$err" in
        *InvalidGroup.NotFound*) break ;;                        # already gone
        *DependencyViolation*) echo "    SG $sg still referenced (ENIs draining), retry ${tries}/6..."; sleep 10 ;;
        *) echo "    could not delete SG $sg: $err"; break ;;     # e.g. still in another SG's rules
      esac
    done
  done
}

# Release dynamically provisioned EBS volumes while the CSI driver can still delete them.
# `eksctl delete cluster` removes the nodes and the driver with them, so a PV left behind orphans
# its EBS volume, which keeps billing with nothing pointing at it. Deleting the namespaces that
# hold PVCs removes the pods pinning them, then the PVCs, and reclaimPolicy Delete removes the
# volumes. The cluster is being destroyed anyway, so a namespace is the right unit to delete.
release_volumes() {   # args: <ctx>
  local ctx="$1" namespaces elapsed left
  namespaces="$(kubectl --context "$ctx" get pvc -A -o json 2>/dev/null \
    | jq -r '[.items[].metadata.namespace] | unique | .[]' || true)"
  [ -z "$namespaces" ] && return 0
  echo "==> releasing EBS volumes: deleting namespaces with PVCs ($(echo $namespaces))"
  # shellcheck disable=SC2086  # one argument per namespace, intended
  kubectl --context "$ctx" delete namespace $namespaces --wait=false >/dev/null 2>&1 || true
  elapsed=0
  while [ $elapsed -lt 180 ]; do
    left="$(kubectl --context "$ctx" get pv -o json 2>/dev/null \
      | jq -r '[.items[] | select(.spec.persistentVolumeReclaimPolicy == "Delete")] | length' || echo 0)"
    [ "$left" = "0" ] && { echo "    volumes released"; return 0; }
    echo "    ${left} volume(s) still releasing... (${elapsed}s)"; sleep 15; elapsed=$((elapsed + 15))
  done
  # Carry on with the teardown, but name what is left so it can be deleted by hand.
  echo "    ⚠ volumes still present after 180s — these EBS volumes may be orphaned:"
  kubectl --context "$ctx" get pv -o json 2>/dev/null \
    | jq -r '.items[] | "      \(.spec.csi.volumeHandle // .spec.awsElasticBlockStore.volumeID // "?")  (\(.spec.claimRef.namespace)/\(.spec.claimRef.name))"' || true
  echo "      delete with: aws ec2 delete-volume --region ${REGION} --volume-id <id>"
}

delete_one() {   # args: <cluster>
  local cluster="$1" ctx cluster_name vpc elapsed c1 c2 stack
  ctx="$(solomog_context "$cluster")"
  cluster_name="${ctx##*/}"                       # arn:...:cluster/NAME → NAME (the eksctl name)
  # region: prefer EKS_REGION, then AWS_REGION, else field 4 of the context ARN (arn:aws:eks:<region>:…)
  REGION="${EKS_REGION:-${AWS_REGION:-}}"; [ -z "$REGION" ] && REGION="$(printf '%s' "$ctx" | cut -d: -f4)"
  REGION="${REGION:-us-east-1}"
  export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"

  echo "==> DELETING EKS cluster '${cluster_name}' in ${REGION} (context ${ctx})"

  # Find the cluster VPC by the eksctl tag — works even if the control plane is already gone.
  vpc="$(aws ec2 describe-vpcs --region "$REGION" \
    --filters "Name=tag:alpha.eksctl.io/cluster-name,Values=${cluster_name}" \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null || true)"
  [ "$vpc" = "None" ] && vpc=""
  echo "    cluster VPC: ${vpc:-<none found>}"

  # 1. Delete Gateways + any LoadBalancer Services so AWS tears down the ELBs (frees the ENIs).
  if kubectl --context "$ctx" version >/dev/null 2>&1; then
    echo "==> deleting Gateways + LoadBalancer Services (releases the ELBs)"
    kubectl --context "$ctx" delete gateway --all -A --ignore-not-found --timeout=60s 2>/dev/null || true
    kubectl --context "$ctx" get svc -A -o json 2>/dev/null \
      | jq -r '.items[] | select(.spec.type=="LoadBalancer") | "\(.metadata.namespace) \(.metadata.name)"' \
      | while read -r ns name; do
          [ -n "$name" ] && kubectl --context "$ctx" -n "$ns" delete svc "$name" --ignore-not-found 2>/dev/null || true
        done
    release_volumes "$ctx"
  else
    echo "    cluster API not reachable (already partly gone) — skipping in-cluster cleanup"
  fi

  # 2–3. Drain LBs + orphaned ELB SGs in the VPC.
  if [ -n "$vpc" ]; then
    echo "==> waiting for load balancers to drain from ${vpc}"
    elapsed=0
    while [ $elapsed -lt 180 ]; do
      delete_lbs_in_vpc "$vpc"
      c1=$(aws elb describe-load-balancers --region "$REGION" --query "length(LoadBalancerDescriptions[?VPCId=='$vpc'])" --output text 2>/dev/null || echo 0)
      c2=$(aws elbv2 describe-load-balancers --region "$REGION" --query "length(LoadBalancers[?VpcId=='$vpc'])" --output text 2>/dev/null || echo 0)
      [ "$c1" = "0" ] && [ "$c2" = "0" ] && { echo "    load balancers gone"; break; }
      echo "    still draining (elb=$c1 elbv2=$c2)... (${elapsed}s)"; sleep 15; elapsed=$((elapsed + 15))
    done
    echo "==> clearing orphaned k8s-elb-* security groups in ${vpc}"
    delete_elb_sgs_in_vpc "$vpc"
  fi

  # 4. Delete the cluster. eksctl is the clean path (handles both CFN stacks + termination protection);
  #    if the control plane is already gone, fall back to deleting the eksctl-<name>-* stacks directly.
  echo "==> eksctl delete cluster ${cluster_name}"
  if ! eksctl delete cluster --name "$cluster_name" --region "$REGION" --disable-nodegroup-eviction 2>&1; then
    echo "==> eksctl delete didn't complete — self-healing the orphan (LBs, ELB SGs, then CFN stacks)"
    delete_lbs_in_vpc "$vpc"
    delete_elb_sgs_in_vpc "$vpc"
    echo "==> cleaning any leftover eksctl-${cluster_name}-* CFN stacks directly"
    for stack in $(aws cloudformation describe-stacks --region "$REGION" \
        --query "Stacks[?starts_with(StackName,'eksctl-${cluster_name}-')].StackName" --output text 2>/dev/null); do
      echo "    stack ${stack}: disabling termination protection + deleting"
      aws cloudformation update-termination-protection --region "$REGION" \
        --stack-name "$stack" --no-enable-termination-protection 2>/dev/null || true
      aws cloudformation delete-stack --region "$REGION" --stack-name "$stack" 2>/dev/null || true
    done
    echo "    (stack deletion is async — check: aws cloudformation describe-stacks --stack-name eksctl-${cluster_name}-cluster)"
  fi

  # 4b. The IRSA role eks:storage created for the EBS CSI controller. Harmless if left, but it
  #     names a cluster that no longer exists. Absent on clusters that never ran eks:storage.
  local ebs_role="solomog-${cluster_name}-ebs-csi"
  if aws iam get-role --role-name "$ebs_role" >/dev/null 2>&1; then
    echo "==> deleting IAM role ${ebs_role}"
    aws iam detach-role-policy --role-name "$ebs_role" \
      --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy 2>/dev/null || true
    aws iam delete-role --role-name "$ebs_role" 2>/dev/null \
      || echo "    could not delete role ${ebs_role} — remove it by hand"
  fi

  # 5. Deregister from the context registry.
  solomog_deregister_context "$cluster"

  # 6. Clean the kubeconfig entries so the dead context stops showing up in kubectx/kubectl. `eksctl
  #    delete` removes its own <user>@<cluster>.<region>.eksctl.io context, but eks-create.sh ALSO runs
  #    `aws eks update-kubeconfig`, which adds the ARN-named context/cluster/user — and eksctl doesn't
  #    touch those, so a deleted cluster's ARN context lingered. (vcluster cleans up on delete; this is
  #    the EKS equivalent.) Keyed by the ARN for all three (that's how update-kubeconfig names them).
  echo "==> removing kubeconfig entries for the deleted cluster"
  if kubectl config delete-context "$ctx" >/dev/null 2>&1; then
    echo "    deleted kube context ${ctx}"
  else
    echo "    (kube context ${ctx} not present)"
  fi
  kubectl config delete-cluster "$ctx" >/dev/null 2>&1 || true
  kubectl config delete-user    "$ctx" >/dev/null 2>&1 || true

  echo "✓ teardown initiated for '${cluster_name}'."
  echo "  Verify the VPC is freed:  aws ec2 describe-vpcs --region ${REGION} --filters Name=tag:alpha.eksctl.io/cluster-name,Values=${cluster_name} --query 'Vpcs[].VpcId'"
}

RC=0
for n in "${NAMES[@]}"; do
  delete_one "$n" || { RC=1; echo "    ERROR: teardown failed for '${n}' — continuing with the rest." >&2; }
done

echo ""
if [ "$RC" -eq 0 ]; then
  echo "✓ Torn down: ${CLUSTER}"
else
  echo "⚠ Teardown finished with errors — review the messages above and re-run for the failed cluster(s)."
  exit 1
fi
