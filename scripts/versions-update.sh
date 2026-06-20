#!/usr/bin/env bash
set -euo pipefail
#
# Fetches the latest release tag from GitHub for each product and
# optionally updates versions.env.

VERSIONS_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/versions.env"

fetch_latest() {
  local repo="$1"
  curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" \
    | jq -r '.tag_name // empty' \
    | sed 's/^v//'
}

echo "==> Fetching latest versions from GitHub..."
echo ""

GLOO_MESH_LATEST=$(fetch_latest "solo-io/gloo-mesh-enterprise" 2>/dev/null || echo "")
KGATEWAY_LATEST=$(fetch_latest "kgateway-dev/kgateway" 2>/dev/null || echo "")
AGENTGATEWAY_LATEST=$(fetch_latest "solo-io/agentgateway" 2>/dev/null || echo "")
ISTIO_LATEST=$(fetch_latest "istio/istio" 2>/dev/null || echo "")

# Read current pinned values for comparison
source "$VERSIONS_FILE"

print_row() {
  local key="$1" current="$2" latest="$3"
  if [[ -z "$latest" ]]; then
    printf "  %-30s %s  (could not fetch)\n" "$key" "$current"
  elif [[ "$current" == "$latest" ]]; then
    printf "  %-30s %s  (up to date)\n" "$key" "$current"
  else
    printf "  %-30s %s  →  %s\n" "$key" "$current" "$latest"
  fi
}

echo "Current → Latest:"
print_row "GLOO_MESH_VERSION"    "${GLOO_MESH_VERSION:-?}"    "$GLOO_MESH_LATEST"
print_row "KGATEWAY_VERSION"     "${KGATEWAY_VERSION:-?}"     "$KGATEWAY_LATEST"
print_row "AGENTGATEWAY_VERSION" "${AGENTGATEWAY_VERSION:-?}" "$AGENTGATEWAY_LATEST"
print_row "ISTIO_VERSION"        "${ISTIO_VERSION:-?}"        "$ISTIO_LATEST"
echo ""

# Only prompt if there are actual updates
has_updates=false
[[ -n "$GLOO_MESH_LATEST"    && "$GLOO_MESH_LATEST"    != "${GLOO_MESH_VERSION:-}"    ]] && has_updates=true
[[ -n "$KGATEWAY_LATEST"     && "$KGATEWAY_LATEST"     != "${KGATEWAY_VERSION:-}"     ]] && has_updates=true
[[ -n "$AGENTGATEWAY_LATEST" && "$AGENTGATEWAY_LATEST" != "${AGENTGATEWAY_VERSION:-}" ]] && has_updates=true
[[ -n "$ISTIO_LATEST"        && "$ISTIO_LATEST"        != "${ISTIO_VERSION:-}"        ]] && has_updates=true

if ! $has_updates; then
  echo "All versions are up to date."
  exit 0
fi

read -rp "Update versions.env with the values shown above? [y/N] " confirm
echo ""
if [[ "${confirm,,}" != "y" ]]; then
  echo "No changes made."
  exit 0
fi

update_line() {
  local key="$1" val="$2"
  [[ -z "$val" ]] && return
  sed -i.bak "s|^${key}=.*|${key}=${val}|" "$VERSIONS_FILE"
}

update_line "GLOO_MESH_VERSION"    "$GLOO_MESH_LATEST"
update_line "KGATEWAY_VERSION"     "$KGATEWAY_LATEST"
update_line "AGENTGATEWAY_VERSION" "$AGENTGATEWAY_LATEST"
update_line "ISTIO_VERSION"        "$ISTIO_LATEST"
rm -f "$VERSIONS_FILE.bak"

echo "==> versions.env updated."
