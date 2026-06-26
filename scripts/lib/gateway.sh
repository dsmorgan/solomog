#!/usr/bin/env bash
# Shared gateway detection. `expose` figures out the gateway from the cluster's
# GatewayClasses; apply/test need the same so $HOST defaults to the right name
# (kgw.<cluster>.test vs agw.<cluster>.test) and matches the cert expose minted.
#
# solomog_detect_gateway <kube-context> — echo the gateway short-name:
#   kgw  if a kgateway GatewayClass is present and no agentgateway one is
#   agw  otherwise (agentgateway-only, both present, or none — the default bias)
# Matches both editions (enterprise-kgateway / kgateway, enterprise-agentgateway /
# agentgateway). "agentgateway" never contains "kgateway", so the substrings are safe.
solomog_detect_gateway() {
  local ctx="$1" classes has_agw=0 has_kgw=0
  classes="$(kubectl --context "$ctx" get gatewayclass \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
  case "$classes" in *agentgateway*) has_agw=1 ;; esac
  case "$classes" in *kgateway*)     has_kgw=1 ;; esac
  if [ "$has_kgw" = 1 ] && [ "$has_agw" = 0 ]; then echo kgw; else echo agw; fi
}
