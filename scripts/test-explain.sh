#!/usr/bin/env bash
set -euo pipefail
#
# Hermetic tests for `solomog explain` / `wwit` (no cluster, no execute).
# Run: bash scripts/test-explain.sh

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOLOMOG="$REPO_DIR/solomog"

FAIL=0
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; FAIL=$((FAIL + 1)); }

assert_eq() {
  local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    pass "$label"
  else
    fail "$label (got=$(printf '%q' "$got") want=$(printf '%q' "$want"))"
  fi
}

assert_contains() {
  local label="$1" hay="$2" needle="$3"
  case "$hay" in
    *"$needle"*) pass "$label" ;;
    *) fail "$label (missing $(printf '%q' "$needle"))" ;;
  esac
}

assert_not_contains() {
  local label="$1" hay="$2" needle="$3"
  case "$hay" in
    *"$needle"*) fail "$label (unexpected $(printf '%q' "$needle"))" ;;
    *) pass "$label" ;;
  esac
}

_run() {
  local out rc
  set +e
  out="$("$@" 2>/dev/null)"
  rc=$?
  set -e
  _LAST_OUT="$out"
  _LAST_RC="$rc"
}

_run_err() {
  local out rc
  set +e
  out="$("$@" 2>&1)"
  rc=$?
  set -e
  _LAST_OUT="$out"
  _LAST_RC="$rc"
}

AGW_VER="$(sed -n 's/^AGENTGATEWAY_VERSION=//p' "$REPO_DIR/versions.env" | head -1 | tr -d '"')"
[ -n "$AGW_VER" ] || AGW_VER="v2026.8.1"
SA_VER="$(sed -n 's/^AGENTGATEWAY_STANDALONE_VERSION=//p' "$REPO_DIR/versions.env" | head -1 | tr -d '"')"
[ -n "$SA_VER" ] || SA_VER="2026.8.2"

echo "==> usage (no tasks)"
_run "$SOLOMOG" explain
assert_eq "usage exit 0" "$_LAST_RC" "0"
assert_contains "usage text" "$_LAST_OUT" "Usage: solomog explain"

echo "==> agentgateway enterprise recipe"
_run "$SOLOMOG" explain agentgateway CLUSTER=aaa
assert_eq "agentgateway exit 0" "$_LAST_RC" "0"
assert_contains "helm install" "$_LAST_OUT" "helm install"
assert_contains "version pin" "$_LAST_OUT" "$AGW_VER"
assert_contains "enterprise chart" "$_LAST_OUT" "enterprise-agentgateway"
assert_contains "license placeholder" "$_LAST_OUT" '$AGENTGATEWAY_LICENSE_KEY'
assert_contains "gateway api" "$_LAST_OUT" "gateway-api"
assert_not_contains "no helmfile" "$_LAST_OUT" "helmfile"
assert_not_contains "no vcluster" "$_LAST_OUT" "vcluster"
assert_not_contains "no kube-context" "$_LAST_OUT" "--kube-context"
assert_not_contains "no kube-context flag" "$_LAST_OUT" "--context"

echo "==> TOKEN_EXCHANGE is a comment, not a live overlay"
_run "$SOLOMOG" explain agentgateway CLUSTER=aaa TOKEN_EXCHANGE=true
assert_contains "token-exchange comment" "$_LAST_OUT" "tokenExchange.enabled=true"
assert_contains "header keeps the flag" "$_LAST_OUT" "TOKEN_EXCHANGE=true"

echo "==> wwit matches explain (helm body)"
_run "$SOLOMOG" wwit agentgateway CLUSTER=aaa
wwit_out="$_LAST_OUT"
_run "$SOLOMOG" explain agentgateway CLUSTER=aaa
explain_out="$_LAST_OUT"
wwit_helm="$(printf '%s\n' "$wwit_out" | grep -E '^(helm |kubectl apply --server-side)' || true)"
explain_helm="$(printf '%s\n' "$explain_out" | grep -E '^(helm |kubectl apply --server-side)' || true)"
assert_eq "wwit alias parity" "$wwit_helm" "$explain_helm"

echo "==> KEY=VALUE may precede explain"
_run "$SOLOMOG" CLUSTER=aaa explain agentgateway
assert_eq "var-first exit 0" "$_LAST_RC" "0"
assert_contains "var-first helm" "$_LAST_OUT" "enterprise-agentgateway"

echo "==> mid-chain explain is an error (does not run the earlier task)"
_run_err "$SOLOMOG" bundles:list explain
assert_eq "mid-chain exit 1" "$_LAST_RC" "1"
assert_contains "mid-chain message" "$_LAST_OUT" "must be the first task"
assert_not_contains "mid-chain did not list bundles" "$_LAST_OUT" "example"

echo "==> community edition uses the OSS registry"
_run "$SOLOMOG" explain agentgateway EDITION=community CLUSTER=aaa
assert_contains "community repo" "$_LAST_OUT" "cr.agentgateway.dev"
assert_not_contains "community has no license set" "$_LAST_OUT" "licensing.licenseKey"

echo "==> stack reorders products"
_run "$SOLOMOG" explain stack PRODUCTS="agentgateway istio" CLUSTER=aaa
assert_contains "order comment" "$_LAST_OUT" "install order is istio agentgateway"
istio_line="$(printf '%s\n' "$_LAST_OUT" | grep -n 'gloo-operator\|istio-base' | head -1 | cut -d: -f1)"
agw_line="$(printf '%s\n' "$_LAST_OUT" | grep -n 'enterprise-agentgateway-crds\|charts/agentgateway-crds' | head -1 | cut -d: -f1)"
if [ -n "$istio_line" ] && [ -n "$agw_line" ] && [ "$istio_line" -lt "$agw_line" ]; then
  pass "istio helm before agentgateway"
else
  fail "istio helm before agentgateway (istio=$istio_line agw=$agw_line)"
fi

echo "==> uncovered task stubs"
_run_err "$SOLOMOG" explain teardown CLUSTER=aaa
assert_eq "stub exit 0" "$_LAST_RC" "0"
assert_contains "stub comment" "$_LAST_OUT" "No customer-shaped recipe"
assert_contains "stderr note" "$_LAST_OUT" "no recipe for teardown"

echo "==> secrets from the environment do not appear"
CANARY="explain-canary-secret-9f3a2c1b8e7d"
export AGENTGATEWAY_LICENSE_KEY="$CANARY"
_run "$SOLOMOG" explain agentgateway CLUSTER=aaa
assert_not_contains "no license value" "$_LAST_OUT" "$CANARY"
unset AGENTGATEWAY_LICENSE_KEY

echo "==> expose emits a Gateway"
_run "$SOLOMOG" explain expose CLUSTER=aaa
assert_contains "kind Gateway" "$_LAST_OUT" "kind: Gateway"
assert_contains "default host" "$_LAST_OUT" "agw.aaa.test"
assert_contains "mkcert comment" "$_LAST_OUT" "mkcert"
assert_not_contains "expose no helmfile" "$_LAST_OUT" "helmfile"

echo "==> apply unrolls the example bundle"
_run "$SOLOMOG" explain apply BUNDLE=example CLUSTER=aaa
assert_eq "apply exit 0" "$_LAST_RC" "0"
assert_contains "namespace manifest" "$_LAST_OUT" "solomog-example"
assert_contains "rendered cluster" "$_LAST_OUT" 'cluster: "aaa"'
assert_contains "rendered host" "$_LAST_OUT" 'gateway-host: "agw.aaa.test"'
assert_contains "hook printed" "$_LAST_OUT" "demo-secret"
assert_contains "hook is kubectl" "$_LAST_OUT" "kubectl create secret"
assert_not_contains "hook dropped context" "$_LAST_OUT" '--context "$CONTEXT"'
assert_not_contains "apply no helmfile" "$_LAST_OUT" "helmfile"

echo "==> portal / standalone / apps emit recipes"
_run "$SOLOMOG" explain portal CLUSTER=aaa
assert_contains "portal chart" "$_LAST_OUT" "portal-crds"
_run "$SOLOMOG" explain standalone NAME=minimal
assert_contains "docker run" "$_LAST_OUT" "docker run"
assert_contains "standalone image pin" "$_LAST_OUT" "$SA_VER"
# CONFIG is the task-level alias for NAME; the recipe must name the same config dir.
_run "$SOLOMOG" explain standalone CONFIG=llm
assert_contains "standalone CONFIG alias" "$_LAST_OUT" "/path/to/llm:/config"
_run "$SOLOMOG" explain apps:utils ROUTE=true CLUSTER=aaa
assert_contains "httpbin image" "$_LAST_OUT" "mccutchen/go-httpbin"
assert_contains "httproute" "$_LAST_OUT" "kind: HTTPRoute"

echo "==> unknown task still fails"
_run_err "$SOLOMOG" explain not-a-real-task CLUSTER=aaa
assert_eq "unknown task exit 1" "$_LAST_RC" "1"
assert_contains "unknown task" "$_LAST_OUT" "unknown task"

if [ "$FAIL" -ne 0 ]; then
  echo
  echo "FAILED: $FAIL check(s)"
  exit 1
fi
echo
echo "All explain tests passed."
