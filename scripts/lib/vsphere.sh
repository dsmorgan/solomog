#!/usr/bin/env bash
# vSphere homelab provisioner helpers — preflight gates + static IP-pool allocator.
# Spec: docs/specs/vsphere-provisioner.md. Sourced by the vsphere-*.sh scripts.
#
# ISOLATION CONTRACT: this capability must never burden non-vsphere use of solomog.
# Tooling is lazy-checked here (the eksctl precedent — OpenTofu is deliberately NOT a
# scripts/setup.sh prerequisite), and config presence is the gate: without the VSPHERE_*
# section filled in .env, every vsphere:* task fails fast here with guidance. There is
# no feature flag — this preflight IS the flag.
#
# Env (all from the .env "vSphere homelab provisioner" section; see .env.example):
#   VSPHERE_SERVER/USER/PASSWORD/DATACENTER/DATASTORE        vCenter connection + placement
#   VSPHERE_COMPUTE_CLUSTER/NETWORK                          cluster VM placement (create)
#   VSPHERE_NODE_POOL_START/NODE_POOL_SIZE                   static node-IP pool (create)
#   VSPHERE_LB_POOL / VSPHERE_NET_GATEWAY/NET_DNS/NET_PREFIX network config (create)
#   VSPHERE_TOFU_BIN                                         tofu binary override (default: tofu;
#                                                            also lets tests stub the tool check)
#   VSPHERE_POOL_FILE                                        allocator file override (tests only)
#   VSPHERE_INIT_STATE                                       init-state path override (tests only)
#
# Usage:
#   source "$REPO_DIR/scripts/lib/vsphere.sh"
#   vsphere_preflight "vsphere:create" full     # or "conn" for init/delete-level checks
#   vsphere_require_init "vsphere:create"       # create refuses to run before vsphere:init

_vsphere_repo_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

# vCenter connection + template placement — enough for vsphere:init / vsphere:delete.
_VSPHERE_CONN_VARS="VSPHERE_SERVER VSPHERE_USER VSPHERE_PASSWORD VSPHERE_DATACENTER VSPHERE_DATASTORE"
# Everything vsphere:create additionally needs (VM placement + static networking).
_VSPHERE_FULL_VARS="$_VSPHERE_CONN_VARS VSPHERE_COMPUTE_CLUSTER VSPHERE_NETWORK VSPHERE_NODE_POOL_START VSPHERE_NODE_POOL_SIZE VSPHERE_LB_POOL VSPHERE_NET_GATEWAY VSPHERE_NET_DNS VSPHERE_NET_PREFIX"

# Gate a vsphere:* task: tooling first, then config. Args: <task-label> <conn|full>
vsphere_preflight() {
  local task="${1:-this task}" scope="${2:-full}" tofu_bin="${VSPHERE_TOFU_BIN:-tofu}"
  local vars missing="" v

  if ! command -v "$tofu_bin" >/dev/null 2>&1; then
    {
      echo "Error: OpenTofu ('$tofu_bin') not found — required by ${task}."
      echo "  → brew install opentofu"
      echo "  (Homelab-only tooling: deliberately NOT installed by scripts/setup.sh —"
      echo "   the vsphere:* tasks are optional and vind/EKS use never needs it.)"
    } >&2
    return 1
  fi

  case "$scope" in
    conn) vars="$_VSPHERE_CONN_VARS" ;;
    *)    vars="$_VSPHERE_FULL_VARS" ;;
  esac
  for v in $vars; do
    eval "[ -n \"\${${v}:-}\" ]" || missing="${missing} ${v}"
  done
  if [ -n "$missing" ]; then
    {
      echo "Error: ${task} is the vSphere HOMELAB provisioner and needs .env configuration."
      echo "  Missing:${missing}"
      echo "  → fill the '─── vSphere homelab provisioner ───' section in .env"
      echo "    (see .env.example; run 'solomog env:sync' to pick up the new keys)."
      echo "  Not using the homelab? Nothing to do — vind/EKS tasks are unaffected."
    } >&2
    return 1
  fi
  return 0
}

# create refuses to run before vsphere:init has provisioned the template (decision 5).
# The check is the init root's local tofu state carrying at least one managed resource —
# a state emptied by destroy, or no state at all, both mean "not initialized".
vsphere_require_init() {
  local task="${1:-this task}"
  local state; state="${VSPHERE_INIT_STATE:-$(_vsphere_repo_dir)/terraform/vsphere-init/terraform.tfstate}"
  if [ -s "$state" ] && grep -q '"mode": *"managed"' "$state" 2>/dev/null; then
    return 0
  fi
  {
    echo "Error: ${task} requires the one-time template setup first."
    echo "  → solomog vsphere:init     # content library + Ubuntu template in vCenter"
  } >&2
  return 1
}

# Kube context naming for vsphere clusters (parallel to vind's vcluster-docker_<name>).
vsphere_context_name() {   # args: <cluster>
  printf 'vsphere_%s' "$1"
}

# ── Static IP-pool allocator ─────────────────────────────────────────────────
# Pool = VSPHERE_NODE_POOL_START + VSPHERE_NODE_POOL_SIZE consecutive addresses.
# v1 fixed assumption: the pool stays within the start IP's last octet (no /24
# boundary crossing) and outside the homelab DHCP scope.
# Allocations live in .solomog/vsphere/ippool (gitignored), one line each:
#   <cluster>\t<ip>\t<role>        role = server | agent-1 | agent-2 | …

_vsphere_pool_file() {
  if [ -n "${VSPHERE_POOL_FILE:-}" ]; then printf '%s' "$VSPHERE_POOL_FILE"; return; fi
  printf '%s/.solomog/vsphere/ippool' "$(_vsphere_repo_dir)"
}

# Echo the pool IP at 0-based <index>, validating the no-octet-crossing assumption.
_vsphere_pool_ip() {   # args: <index>
  local base last
  base="${VSPHERE_NODE_POOL_START%.*}"
  last="${VSPHERE_NODE_POOL_START##*.}"
  case "$last" in (*[!0-9]*|'')
    echo "Error: VSPHERE_NODE_POOL_START='${VSPHERE_NODE_POOL_START}' is not an IPv4 address." >&2
    return 1 ;;
  esac
  if [ $((last + VSPHERE_NODE_POOL_SIZE - 1)) -gt 254 ]; then
    echo "Error: node pool ${VSPHERE_NODE_POOL_START} +${VSPHERE_NODE_POOL_SIZE} crosses .254 —" \
         "keep the pool inside the last octet (v1 fixed assumption)." >&2
    return 1
  fi
  printf '%s.%s' "$base" "$((last + $1))"
}

# Print a cluster's allocations as "<role>\t<ip>" lines (server first, agents in order).
vsphere_list_ips() {   # args: <cluster>
  local f; f="$(_vsphere_pool_file)"
  [ -f "$f" ] || return 0
  awk -F'\t' -v c="$1" '$1==c && $3=="server"{print $3 "\t" $2}' "$f"
  awk -F'\t' -v c="$1" '$1==c && $3!="server"{print $3 "\t" $2}' "$f" | sort -t- -k2,2n
}

# Allocate <count> IPs (1 server + count-1 agents) for <cluster>; echo "<role>\t<ip>" lines.
# Idempotent: an existing allocation of exactly <count> is returned as-is (re-run of
# create); any other existing count is an error (delete the cluster first).
vsphere_alloc_ips() {   # args: <cluster> <count>
  local cluster="$1" count="$2" f existing_n i ip taken role
  f="$(_vsphere_pool_file)"
  mkdir -p "$(dirname "$f")"

  existing_n=0
  [ -f "$f" ] && existing_n="$(awk -F'\t' -v c="$cluster" '$1==c' "$f" | grep -c . || true)"
  if [ "$existing_n" -gt 0 ]; then
    if [ "$existing_n" -eq "$count" ]; then
      vsphere_list_ips "$cluster"
      return 0
    fi
    echo "Error: cluster '${cluster}' already holds ${existing_n} pool IP(s) but ${count} requested." >&2
    echo "  → solomog vsphere:delete CLUSTER=${cluster}   # frees its allocations" >&2
    return 1
  fi

  # First-fit scan of the pool; validate capacity before writing anything.
  local picked=""
  i=0
  while [ "$i" -lt "$VSPHERE_NODE_POOL_SIZE" ] && [ "$(printf '%s\n' $picked | grep -c .)" -lt "$count" ]; do
    ip="$(_vsphere_pool_ip "$i")" || return 1
    taken=""
    [ -f "$f" ] && taken="$(awk -F'\t' -v ip="$ip" '$2==ip{print; exit}' "$f")"
    [ -z "$taken" ] && picked="$picked $ip"
    i=$((i + 1))
  done
  if [ "$(printf '%s\n' $picked | grep -c .)" -lt "$count" ]; then
    echo "Error: node IP pool exhausted (need ${count}, pool size ${VSPHERE_NODE_POOL_SIZE}," \
         "in use: $( [ -f "$f" ] && grep -c . "$f" || echo 0 ))." >&2
    echo "  → free IPs with vsphere:delete, or grow VSPHERE_NODE_POOL_SIZE in .env." >&2
    return 1
  fi

  i=0
  for ip in $picked; do
    if [ "$i" -eq 0 ]; then role="server"; else role="agent-$i"; fi
    printf '%s\t%s\t%s\n' "$cluster" "$ip" "$role" >> "$f"
    i=$((i + 1))
  done
  vsphere_list_ips "$cluster"
}

# Free a cluster's allocations. No-op if absent; removes the file when it empties.
vsphere_release_ips() {   # args: <cluster>
  local f tmp; f="$(_vsphere_pool_file)"; tmp="${f}.tmp"
  [ -f "$f" ] || return 0
  awk -F'\t' -v c="$1" '$1!=c' "$f" > "$tmp"
  mv "$tmp" "$f"
  [ -s "$f" ] || rm -f "$f"
}
