#!/usr/bin/env bash
# /api/substrate/status — the endpoint substrate-scope's high-fidelity mode is built on.
#
# This test exists to guard the version pin as much as the install. kagent 1.0.0-alpha1
# REMOVED this REST endpoint; scope then silently falls back to its `crd` source, which
# sees WorkerPools and ActorTemplates but no per-actor runtime state, no chat drawer and
# no stimulate. The board still renders, so the regression is easy to miss — hence an
# explicit assertion rather than trusting the UI to look right.
set -euo pipefail

CTX="${CONTEXT:?CONTEXT not set}"
PORT="${SUBSTRATE_STATUS_PORT:-18083}"
rc=0

echo "── kagent /api/substrate/status"

kubectl --context "$CTX" port-forward -n kagent svc/kagent-controller "${PORT}:8083" \
  >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null || true' EXIT
sleep 4

BODY="$(curl -sS --max-time 20 "http://127.0.0.1:${PORT}/api/substrate/status?namespace=kagent" 2>/dev/null || true)"

if [ -z "$BODY" ]; then
  echo "  ✗ no response from /api/substrate/status"
  echo "    On kagent 1.0.0-alpha1+ this endpoint no longer exists. Check the version:"
  echo "      helm --kube-context $CTX list -n kagent"
  exit 1
fi

# The payload is wrapped by kagent's standard response envelope, so read .data when it is
# there and fall back to the bare object.
S="$(printf '%s' "$BODY" | jq -c 'if has("data") then .data else . end' 2>/dev/null || true)"
if [ -z "$S" ] || [ "$S" = "null" ]; then
  echo "  ✗ response was not JSON substrate status:"
  printf '%s\n' "$BODY" | head -c 400 | sed 's/^/    /'
  exit 1
fi

if [ "$(printf '%s' "$S" | jq -r '.enabled')" = "true" ]; then
  echo "  ✓ controller reports substrate enabled"
else
  echo "  ✗ enabled=false — controller.substrate.enabled / ateApiEndpoint not set"
  rc=1
fi

ERR="$(printf '%s' "$S" | jq -r '.ateApiError // ""')"
if [ -n "$ERR" ]; then
  echo "  ✗ ateApiError: ${ERR}"
  echo "    The controller reached ate-api but the call failed; actors and workers will"
  echo "    be empty and scope's board will render with no chips."
  rc=1
else
  echo "  ✓ no ateApiError"
fi

POOLS="$(printf '%s' "$S" | jq -r '.workerPools | length')"
TEMPLATES="$(printf '%s' "$S" | jq -r '.actorTemplates | length')"
ACTORS="$(printf '%s' "$S" | jq -r '.actors | length')"
WORKERS="$(printf '%s' "$S" | jq -r '.workers | length')"
echo "  pools=${POOLS} actorTemplates=${TEMPLATES} actors=${ACTORS} workers=${WORKERS}"

[ "${POOLS:-0}" -ge 1 ]     || { echo "  ✗ no WorkerPools in the inventory"; rc=1; }
[ "${TEMPLATES:-0}" -ge 1 ] || { echo "  ✗ no ActorTemplates — kagent generated none"; rc=1; }
# actors/workers come from ate-api rather than the Kubernetes API. Empty here with pools
# and templates present is the signature of an ate-api the controller cannot read.
[ "${WORKERS:-0}" -ge 1 ]   || { echo "  ✗ no workers from ate-api — scope will show empty bays"; rc=1; }

exit $rc
