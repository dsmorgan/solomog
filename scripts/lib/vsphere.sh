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

# Print a cluster's NODE allocations as "<role>\t<ip>" lines (server first, agents in
# order). Node view only — lb-* VIP rows (vsphere_alloc_lb_ip) are a separate concern.
vsphere_list_ips() {   # args: <cluster>
  local f; f="$(_vsphere_pool_file)"
  [ -f "$f" ] || return 0
  awk -F'\t' -v c="$1" '$1==c && $3=="server"{print $3 "\t" $2}' "$f"
  awk -F'\t' -v c="$1" '$1==c && $3 ~ /^agent-/{print $3 "\t" $2}' "$f" | sort -t- -k2,2n
}

# Allocate <count> IPs (1 server + count-1 agents) for <cluster>; echo "<role>\t<ip>" lines.
# Idempotent: an existing allocation of exactly <count> is returned as-is (re-run of
# create); any other existing count is an error (delete the cluster first).
vsphere_alloc_ips() {   # args: <cluster> <count>
  local cluster="$1" count="$2" f existing_n i ip taken role
  f="$(_vsphere_pool_file)"
  mkdir -p "$(dirname "$f")"

  existing_n=0
  [ -f "$f" ] && existing_n="$(awk -F'\t' -v c="$cluster" '$1==c && ($3=="server" || $3 ~ /^agent-/)' "$f" | grep -c . || true)"
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

# Free a cluster's allocations. Default scope "nodes" KEEPS the lb-* VIP rows —
# that stickiness is what makes a cluster name's DNS record permanent across
# recreate cycles (spec decision 13). Pass "all" (vsphere:delete PURGE_LB=true)
# to release the VIPs too. No-op if absent; removes the file when it empties.
vsphere_release_ips() {   # args: <cluster> [nodes|all]
  local f tmp scope="${2:-nodes}"; f="$(_vsphere_pool_file)"; tmp="${f}.tmp"
  [ -f "$f" ] || return 0
  if [ "$scope" = "all" ]; then
    awk -F'\t' -v c="$1" '$1!=c' "$f" > "$tmp"
  else
    awk -F'\t' -v c="$1" '$1!=c || $3 ~ /^lb-/' "$f" > "$tmp"
  fi
  mv "$tmp" "$f"
  [ -s "$f" ] || rm -f "$f"
}

# ── Name-sticky LoadBalancer VIPs (spec phase 6a) ────────────────────────────
# Each (cluster, gateway) gets a deterministic VIP from VSPHERE_LB_POOL
# ("<start>-<end>", one /24), recorded as role "lb-<gw>" in the same pool file.
# Allocation walks from the TOP of the pool downward so it stays clear of
# MetalLB auto-assign (which takes the lowest free address); expose then pins
# the VIP via metallb.io/loadBalancerIPs. Rows persist across vsphere:delete
# (default scope keeps them), so a recreated cluster gets the same VIP and any
# DNS record for it stays valid.

# Echo "<base> <start-octet> <end-octet>" for VSPHERE_LB_POOL, validating shape.
_vsphere_lb_pool_bounds() {
  local start end base_s base_e s e
  start="${VSPHERE_LB_POOL%-*}"; end="${VSPHERE_LB_POOL#*-}"
  base_s="${start%.*}"; base_e="${end%.*}"
  s="${start##*.}"; e="${end##*.}"
  case "$s$e" in (*[!0-9]*|'')
    echo "Error: VSPHERE_LB_POOL='${VSPHERE_LB_POOL}' must look like 10.0.20.200-10.0.20.219." >&2
    return 1 ;;
  esac
  if [ "$base_s" != "$base_e" ] || [ "$s" -gt "$e" ]; then
    echo "Error: VSPHERE_LB_POOL='${VSPHERE_LB_POOL}' must be an ascending range in one /24." >&2
    return 1
  fi
  printf '%s %s %s' "$base_s" "$s" "$e"
}

# Allocate (or return the sticky existing) VIP for a cluster's gateway; echoes the IP.
vsphere_alloc_lb_ip() {   # args: <cluster> <gateway-name e.g. agw>
  local cluster="$1" role="lb-$2" f bounds base s e i ip taken existing
  f="$(_vsphere_pool_file)"
  mkdir -p "$(dirname "$f")"
  existing=""
  [ -f "$f" ] && existing="$(awk -F'\t' -v c="$cluster" -v r="$role" '$1==c && $3==r{print $2; exit}' "$f")"
  if [ -n "$existing" ]; then printf '%s' "$existing"; return 0; fi
  bounds="$(_vsphere_lb_pool_bounds)" || return 1
  base="${bounds%% *}"; s="$(printf '%s' "$bounds" | awk '{print $2}')"; e="${bounds##* }"
  i="$e"
  while [ "$i" -ge "$s" ]; do
    ip="${base}.${i}"
    taken=""
    [ -f "$f" ] && taken="$(awk -F'\t' -v ip="$ip" '$2==ip{print; exit}' "$f")"
    # Liveness guard: never hand out an IP something already answers on — a live
    # host in the pool ARP-battles MetalLB and breaks the VIP intermittently
    # (learned from ds2's 10G interface sitting inside the pool). Recorded VIPs
    # are skipped above, so a ping reply here means a foreign device.
    # VSPHERE_LB_PING_CHECK=false disables (tests / ICMP-filtered networks).
    if [ -z "$taken" ] && [ "${VSPHERE_LB_PING_CHECK:-true}" != "false" ] \
       && ping -c1 -W300 -t1 "$ip" >/dev/null 2>&1; then
      echo "    NOTE: skipping ${ip} — something already answers on it (foreign device in VSPHERE_LB_POOL)" >&2
      taken="live"
    fi
    if [ -z "$taken" ]; then
      printf '%s\t%s\t%s\n' "$cluster" "$ip" "$role" >> "$f"
      printf '%s' "$ip"
      return 0
    fi
    i=$((i - 1))
  done
  echo "Error: no free VIP in VSPHERE_LB_POOL (${VSPHERE_LB_POOL}) — release with vsphere:delete PURGE_LB=true or grow the pool." >&2
  return 1
}

# Print a cluster's VIP reservations as "<role>\t<ip>" lines.
vsphere_list_lb_ips() {   # args: <cluster>
  local f; f="$(_vsphere_pool_file)"
  [ -f "$f" ] || return 0
  awk -F'\t' -v c="$1" '$1==c && $3 ~ /^lb-/{print $3 "\t" $2}' "$f"
}

# ── Baseline snapshots (spec phase 4) ────────────────────────────────────────

# Echo the cluster's VM names (server first, then agents), derived from the node
# allocations — the same names terraform/vsphere-k3s builds.
vsphere_vm_names() {   # args: <cluster>
  vsphere_list_ips "$1" | awk -F'\t' -v c="$1" \
    '{ if ($1=="server") print "solomog-" c "-server"; else print "solomog-" c "-" $1 }'
}

# Run the pyvmomi VM tool (take|revert|stop|start|status) for a cluster's VMs, via
# uv (a setup.sh prerequisite — no new tooling; vCenter 7.0.3 has no REST snapshot
# API and tofu can't revert or power-cycle).
vsphere_vm_tool() {   # args: <take|revert|stop|start|status> <cluster>
  local names
  command -v uv >/dev/null 2>&1 || { echo "Error: uv not found (bash scripts/setup.sh installs it)." >&2; return 1; }
  names="$(vsphere_vm_names "$2")"
  if [ -z "$names" ]; then
    echo "Error: no node allocations recorded for '$2' — is it a solomog vsphere cluster?" >&2
    return 1
  fi
  # shellcheck disable=SC2086
  uv run --with pyvmomi --python 3.12 "$(_vsphere_repo_dir)/scripts/vsphere-snapshot.py" "$1" $names
}

# Poll until <count> nodes report Ready on <context> (used after reset/start).
vsphere_wait_ready() {   # args: <context> <count> [<timeout-seconds, default 420>]
  local ctx="$1" want="$2" timeout="${3:-420}" deadline ready
  deadline=$(( $(date +%s) + timeout ))
  while :; do
    ready="$(kubectl --context "$ctx" get nodes --no-headers --request-timeout=3s 2>/dev/null | awk '$2=="Ready"' | grep -c . || true)"
    if [ "${ready:-0}" -ge "$want" ]; then
      echo "    ${ready} node(s) Ready"
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "Error: only ${ready:-0}/${want} nodes Ready after ${timeout}s." >&2
      kubectl --context "$ctx" get nodes >&2 || true
      return 1
    fi
    sleep 5
  done
}
