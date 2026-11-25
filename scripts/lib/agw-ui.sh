#!/usr/bin/env bash
# Which Solo UI packaging an enterprise agentgateway release uses.
#
#   bundled     the enterprise-agentgateway chart carries the enterprise-agentgateway-ui
#               subchart (alias `ui`, condition ui.enabled). First seen in v2026.10.x. The UI
#               is part of the agentgateway release: Services enterprise-agentgateway-ui and
#               enterprise-agentgateway-ui-telemetry-collector, served at /.
#   management  older releases: the UI is the separate `management` chart (Services
#               solo-enterprise-ui and solo-enterprise-telemetry-collector, served at /age/).
#
# Prefer bundled whenever the chart has it. UI_MODE=bundled|management forces one; any
# other value (default auto) asks the chart. Sourced by stack.sh and install-agentgateway-ui.sh.

# agw_ui_mode — prints bundled or management for AGENTGATEWAY_VERSION.
agw_ui_mode() {
  local mode="${UI_MODE:-auto}"
  case "$mode" in
    bundled|management) echo "$mode"; return 0 ;;
    auto|"") ;;
    *) echo "Error: UI_MODE='$mode' (use auto, bundled or management)" >&2; return 1 ;;
  esac
  local version="${AGENTGATEWAY_VERSION:?AGENTGATEWAY_VERSION is not set}"
  local repo="oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway"
  local cache_dir="${SOLOMOG_REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}/.solomog/cache"
  local cache="$cache_dir/agw-ui-mode-${version}"
  if [[ -s "$cache" ]]; then cat "$cache"; return 0; fi
  local chart
  if ! chart="$(helm show chart "$repo" --version "$version" 2>/dev/null)"; then
    echo "Error: can't read chart enterprise-agentgateway ${version} to choose the UI packaging." >&2
    echo "       Set UI_MODE=bundled or UI_MODE=management to skip the check." >&2
    return 1
  fi
  if grep -q 'name: enterprise-agentgateway-ui' <<<"$chart"; then mode=bundled; else mode=management; fi
  mkdir -p "$cache_dir" && echo "$mode" >"$cache"
  echo "$mode"
}

# agw_ui_bundled_enabled CONTEXT — true when the installed agentgateway release has ui.enabled.
agw_ui_bundled_enabled() {
  [[ "$(helm get values agentgateway --kube-context "$1" -n agentgateway-system -o json 2>/dev/null \
        | jq -r '.ui.enabled // false' 2>/dev/null)" == "true" ]]
}
