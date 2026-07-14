#!/usr/bin/env bash
# Shared gateway detection for expose / apps / apply / test.
#
# Edition-aware: matches both enterprise-* and community GatewayClass names
# (enterprise-agentgateway / agentgateway, enterprise-kgateway / kgateway).
# "agentgateway" never contains "kgateway", so the substrings are safe.

# Echo GatewayClass names on the context (space-separated), or empty on failure.
solomog_gateway_classes() {
  local ctx="$1"
  kubectl --context "$ctx" get gatewayclass \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true
}

# Echo product short-name for defaults: kgateway | agentgateway.
# Bias toward agentgateway when both/neither are present (same as expose historically).
solomog_detect_product() {
  local classes="$1" has_agw=0 has_kgw=0
  case "$classes" in *agentgateway*) has_agw=1 ;; esac
  case "$classes" in *kgateway*)     has_kgw=1 ;; esac
  if [ "$has_kgw" = 1 ] && [ "$has_agw" = 0 ]; then
    echo kgateway
  else
    echo agentgateway
  fi
}

# Echo the GatewayClass name to use for PRODUCT, preferring whatever is actually
# installed (enterprise-* when present, else the community short name).
# Fallback when neither is present: enterprise-* (primary PoV path).
solomog_resolve_gateway_class() {
  local product="$1" classes="$2"
  case "$product" in
    agentgateway)
      case "$classes" in
        *enterprise-agentgateway*) echo enterprise-agentgateway; return ;;
        *agentgateway*)            echo agentgateway; return ;;
      esac
      echo enterprise-agentgateway
      ;;
    kgateway)
      case "$classes" in
        *enterprise-kgateway*) echo enterprise-kgateway; return ;;
        *kgateway*)            echo kgateway; return ;;
      esac
      echo enterprise-kgateway
      ;;
    *) echo "" ;;
  esac
}

# Echo gateway short-name: kgw | agw (for HOST defaults in apply/test).
solomog_detect_gateway() {
  local ctx="$1" classes product
  classes="$(solomog_gateway_classes "$ctx")"
  product="$(solomog_detect_product "$classes")"
  if [ "$product" = kgateway ]; then echo kgw; else echo agw; fi
}
