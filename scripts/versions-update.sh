#!/usr/bin/env bash
set -euo pipefail
#
# Read-only version check: fetches the latest GitHub release tags for products
# that have a public "latest" release, compares them to versions.env, and prints
# what looks outdated. NEVER writes versions.env — update pins by hand after
# confirming the right edition/line (enterprise OCI ≠ community GitHub tags).
#
# Notes:
#   - Tag names are compared as returned (leading "v" is preserved). Chart pins
#     that require a "v" prefix (agentgateway, community kgateway) stay accurate.
#   - KGATEWAY_VERSION is the ENTERPRISE pin (Solo OCI); GitHub latest from
#     kgateway-dev/kgateway is the community/OSS line — compared to
#     KGATEWAY_COMMUNITY_VERSION only.
#   - Operator / Gloo Gateway / UI / prom pins are not checked here (registries,
#     not GitHub "latest").

VERSIONS_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/versions.env"

fetch_latest() {
  local repo="$1"
  curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" \
    | jq -r '.tag_name // empty'
}

echo "==> Checking versions against GitHub latest (read-only — will not write versions.env)"
echo ""

GLOO_MESH_LATEST=$(fetch_latest "solo-io/gloo-mesh-enterprise" 2>/dev/null || echo "")
KGATEWAY_OSS_LATEST=$(fetch_latest "kgateway-dev/kgateway" 2>/dev/null || echo "")
AGENTGATEWAY_LATEST=$(fetch_latest "solo-io/agentgateway" 2>/dev/null || echo "")
ISTIO_LATEST=$(fetch_latest "istio/istio" 2>/dev/null || echo "")

# Read current pinned values for comparison
# shellcheck source=/dev/null
source "$VERSIONS_FILE"

print_row() {
  local key="$1" current="$2" latest="$3" note="${4:-}"
  if [[ -z "$latest" ]]; then
    printf "  %-32s %s  (could not fetch)\n" "$key" "$current"
  elif [[ "$current" == "$latest" ]]; then
    printf "  %-32s %s  (up to date)\n" "$key" "$current"
  else
    printf "  %-32s %s  →  %s%s\n" "$key" "$current" "$latest" "${note:+  ($note)}"
  fi
}

echo "Current pin → GitHub latest:"
print_row "GLOO_MESH_VERSION" \
  "${GLOO_MESH_VERSION:-?}" "$GLOO_MESH_LATEST"
print_row "KGATEWAY_COMMUNITY_VERSION" \
  "${KGATEWAY_COMMUNITY_VERSION:-?}" "$KGATEWAY_OSS_LATEST" "OSS GitHub; not enterprise OCI"
print_row "AGENTGATEWAY_VERSION" \
  "${AGENTGATEWAY_VERSION:-?}" "$AGENTGATEWAY_LATEST"
print_row "ISTIO_VERSION" \
  "${ISTIO_VERSION:-?}" "$ISTIO_LATEST"

echo ""
echo "Not checked by this task (manual pin / different registry):"
printf "  %-32s %s  (enterprise OCI — not kgateway-dev GitHub latest)\n" \
  "KGATEWAY_VERSION" "${KGATEWAY_VERSION:-?}"
printf "  %-32s %s\n" "GLOO_OPERATOR_VERSION" "${GLOO_OPERATOR_VERSION:-?}"
printf "  %-32s %s\n" "GLOO_GATEWAY_VERSION" "${GLOO_GATEWAY_VERSION:-?}"
printf "  %-32s %s\n" "AGW_UI_VERSION" "${AGW_UI_VERSION:-?}"
printf "  %-32s %s\n" "KUBE_PROM_STACK_VERSION" "${KUBE_PROM_STACK_VERSION:-?}"
printf "  %-32s %s\n" "AGENTGATEWAY_COMMUNITY_VERSION" "${AGENTGATEWAY_COMMUNITY_VERSION:-?}"
printf "  %-32s %s\n" "GATEWAY_API_VERSION" "${GATEWAY_API_VERSION:-?}"
echo ""

has_updates=false
[[ -n "$GLOO_MESH_LATEST"    && "$GLOO_MESH_LATEST"    != "${GLOO_MESH_VERSION:-}"            ]] && has_updates=true
[[ -n "$KGATEWAY_OSS_LATEST" && "$KGATEWAY_OSS_LATEST" != "${KGATEWAY_COMMUNITY_VERSION:-}" ]] && has_updates=true
[[ -n "$AGENTGATEWAY_LATEST" && "$AGENTGATEWAY_LATEST" != "${AGENTGATEWAY_VERSION:-}"       ]] && has_updates=true
[[ -n "$ISTIO_LATEST"        && "$ISTIO_LATEST"        != "${ISTIO_VERSION:-}"              ]] && has_updates=true

if ! $has_updates; then
  echo "Checked pins match GitHub latest (or could not fetch). Nothing to update."
  exit 0
fi

echo "One or more checked pins differ from GitHub latest."
echo "Update versions.env by hand after confirming the right edition/line — this task does not write the file."
