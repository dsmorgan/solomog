#!/usr/bin/env bash
set -euo pipefail
#
# Fixture tests for scripts/lib/vsphere.sh (no vCenter, no tofu, no real .env values).
# Run: bash scripts/test-vsphere-lib.sh

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/vsphere.sh
source "$REPO_DIR/scripts/lib/vsphere.sh"

FAIL=0
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

assert_eq() {
  local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    pass "$label"
  else
    fail "$label (got=$(printf '%q' "$got") want=$(printf '%q' "$want"))"
  fi
}

assert_fails_with() {   # label, expected-stderr-fragment, then the command
  local label="$1" needle="$2" out rc=0; shift 2
  out="$("$@" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    fail "$label (expected failure, got rc=0)"
  elif printf '%s' "$out" | grep -F -- "$needle" >/dev/null; then
    pass "$label"
  else
    fail "$label (rc=$rc but missing $(printf '%q' "$needle") in: $out)"
  fi
}

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/test-vsphere.XXXXXX")"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

export VSPHERE_POOL_FILE="$WORKDIR/ippool"
export VSPHERE_LB_PING_CHECK=false   # fixture IPs are fictional — keep the liveness guard out
export VSPHERE_NODE_POOL_START="10.0.20.50"
export VSPHERE_NODE_POOL_SIZE="6"

echo "==> preflight: missing tooling"
export VSPHERE_TOFU_BIN="$WORKDIR/no-such-tofu"
assert_fails_with "tofu absent → brew guidance" "brew install opentofu" \
  vsphere_preflight "vsphere:create" full

echo "==> preflight: tooling ok, config missing"
export VSPHERE_TOFU_BIN="/bin/ls"   # any executable satisfies the tool check
assert_fails_with "unset VSPHERE_* → names the missing keys" "VSPHERE_SERVER" \
  vsphere_preflight "vsphere:create" full
assert_fails_with "…and reassures non-homelab users" "vind/EKS tasks are unaffected" \
  vsphere_preflight "vsphere:create" full

echo "==> preflight: conn scope passes without create-only vars"
export VSPHERE_SERVER=vc.test VSPHERE_USER=u VSPHERE_PASSWORD=p
export VSPHERE_DATACENTER=dc VSPHERE_DATASTORE=ds
if vsphere_preflight "vsphere:init" conn >/dev/null 2>&1; then
  pass "conn scope ok"
else
  fail "conn scope ok"
fi
assert_fails_with "full scope still wants create vars" "VSPHERE_NETWORK" \
  vsphere_preflight "vsphere:create" full

export VSPHERE_COMPUTE_CLUSTER=cc VSPHERE_NETWORK=pg VSPHERE_LB_POOL=10.0.20.200-10.0.20.219
export VSPHERE_NET_GATEWAY=10.0.20.1 VSPHERE_NET_DNS=10.0.20.1 VSPHERE_NET_PREFIX=24
if vsphere_preflight "vsphere:create" full >/dev/null 2>&1; then
  pass "full scope ok once configured"
else
  fail "full scope ok once configured"
fi

echo "==> require_init (hermetic via VSPHERE_INIT_STATE — a real init state may exist)"
export VSPHERE_INIT_STATE="$WORKDIR/init.tfstate"
assert_fails_with "create before init refused (no state)" "solomog vsphere:init" \
  vsphere_require_init "vsphere:create"
printf '{"resources": [{"mode": "managed", "type": "vsphere_content_library"}]}\n' > "$VSPHERE_INIT_STATE"
if vsphere_require_init "vsphere:create" >/dev/null 2>&1; then
  pass "applied state accepted"
else
  fail "applied state accepted"
fi
printf '{"resources": []}\n' > "$VSPHERE_INIT_STATE"
assert_fails_with "destroyed (empty) state refused" "solomog vsphere:init" \
  vsphere_require_init "vsphere:create"

echo "==> allocator: basic allocation"
GOT="$(vsphere_alloc_ips hl1 3)"
assert_eq "hl1 gets 3 sequential" "$GOT" "$(printf 'server\t10.0.20.50\nagent-1\t10.0.20.51\nagent-2\t10.0.20.52')"

GOT="$(vsphere_alloc_ips hl2 2)"
assert_eq "hl2 continues after hl1" "$GOT" "$(printf 'server\t10.0.20.53\nagent-1\t10.0.20.54')"

echo "==> allocator: idempotent re-alloc"
GOT="$(vsphere_alloc_ips hl1 3)"
assert_eq "same IPs on re-run" "$GOT" "$(printf 'server\t10.0.20.50\nagent-1\t10.0.20.51\nagent-2\t10.0.20.52')"
assert_fails_with "count mismatch is an error" "vsphere:delete" vsphere_alloc_ips hl1 2

echo "==> allocator: exhaustion (pool of 6, 5 used, 2 wanted)"
assert_fails_with "pool exhausted" "pool exhausted" vsphere_alloc_ips hl3 2

echo "==> allocator: release + first-fit reuse"
vsphere_release_ips hl1
GOT="$(vsphere_list_ips hl1)"
assert_eq "hl1 gone after release" "$GOT" ""
GOT="$(vsphere_list_ips hl2)"
assert_eq "hl2 untouched by hl1 release" "$GOT" "$(printf 'server\t10.0.20.53\nagent-1\t10.0.20.54')"
GOT="$(vsphere_alloc_ips hl3 2)"
assert_eq "freed IPs reused first-fit" "$GOT" "$(printf 'server\t10.0.20.50\nagent-1\t10.0.20.51')"

vsphere_release_ips hl2
vsphere_release_ips hl3
if [ ! -f "$VSPHERE_POOL_FILE" ]; then
  pass "empty pool file removed"
else
  fail "empty pool file removed"
fi

echo "==> allocator: octet-boundary guard"
export VSPHERE_NODE_POOL_START="10.0.20.250" VSPHERE_NODE_POOL_SIZE="10"
assert_fails_with "pool crossing .254 refused" "crosses .254" vsphere_alloc_ips oops 2

echo "==> LB VIP allocator (name-sticky, top-of-pool)"
export VSPHERE_LB_POOL="10.0.20.200-10.0.20.203"
assert_eq "first VIP from the TOP of the pool" "$(vsphere_alloc_lb_ip s1 agw)" "10.0.20.203"
assert_eq "sticky on re-alloc" "$(vsphere_alloc_lb_ip s1 agw)" "10.0.20.203"
assert_eq "second gateway walks down" "$(vsphere_alloc_lb_ip s1 kgw)" "10.0.20.202"
assert_eq "second cluster walks down" "$(vsphere_alloc_lb_ip hl2 agw)" "10.0.20.201"

echo "==> LB rows never leak into the node view"
export VSPHERE_NODE_POOL_START="10.0.20.50" VSPHERE_NODE_POOL_SIZE="6"
GOT="$(vsphere_alloc_ips s1 2)"
assert_eq "node alloc unaffected by lb rows" "$GOT" "$(printf 'server\t10.0.20.50\nagent-1\t10.0.20.51')"
GOT="$(vsphere_alloc_ips s1 2)"
assert_eq "node idempotency unaffected by lb rows" "$GOT" "$(printf 'server\t10.0.20.50\nagent-1\t10.0.20.51')"

echo "==> release: default keeps VIPs sticky; 'all' purges"
vsphere_release_ips s1
assert_eq "nodes released" "$(vsphere_list_ips s1)" ""
assert_eq "VIPs survive default release" "$(vsphere_list_lb_ips s1)" "$(printf 'lb-agw\t10.0.20.203\nlb-kgw\t10.0.20.202')"
vsphere_release_ips s1 all
assert_eq "PURGE releases VIPs too" "$(vsphere_list_lb_ips s1)" ""

echo "==> LB pool exhaustion + validation"
assert_eq "freed VIP reused from top" "$(vsphere_alloc_lb_ip x1 agw)" "10.0.20.203"
assert_eq "next down" "$(vsphere_alloc_lb_ip x2 agw)" "10.0.20.202"
assert_eq "skips hl2's .201" "$(vsphere_alloc_lb_ip x3 agw)" "10.0.20.200"
assert_fails_with "VIP pool exhausted" "no free VIP" vsphere_alloc_lb_ip x4 agw
VSPHERE_LB_POOL="banana" assert_fails_with "malformed pool refused" "must look like" vsphere_alloc_lb_ip y1 agw
export VSPHERE_LB_POOL="10.0.20.200-10.0.20.219"

echo "==> context naming"
assert_eq "context name" "$(vsphere_context_name hl1)" "vsphere_hl1"

echo "==> solomog_is_vsphere (lib/target.sh — drives expose's local-vs-cloud LB branch)"
# shellcheck source=lib/target.sh
source "$REPO_DIR/scripts/lib/target.sh"
if CONTEXT=vsphere_hl1 solomog_is_vsphere hl1; then
  pass "vsphere_* context → vsphere"
else
  fail "vsphere_* context → vsphere"
fi
if CONTEXT="arn:aws:eks:us-east-1:1:cluster/x" solomog_is_vsphere x; then
  fail "EKS ARN context → not vsphere"
else
  pass "EKS ARN context → not vsphere"
fi
if CONTEXT= solomog_is_vsphere some-vind-name; then
  fail "vind default context → not vsphere"
else
  pass "vind default context → not vsphere"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "All vsphere lib tests passed."
else
  echo "${FAIL} test(s) FAILED."
  exit 1
fi
