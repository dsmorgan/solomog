#!/usr/bin/env bash
# Each Agent's golden snapshot is built: Substrate restored the runtime on a gVisor worker,
# checkpointed it, and kagent marked the Agent Ready. Up to 10 minutes on a cold node.
. "$(dirname "$0")/../helpers/checks.sh"

for a in assistant toolcall; do
  start=$(date +%s)
  if wait_agent "$a" 600; then ok "Agent ${a} Ready ($(( $(date +%s) - start ))s waited)"
  else no "Agent ${a} not Ready after 10 minutes"; say "ate-controller: kubectl --context ${CTX} -n ${SUBSTRATE_NS} logs deploy/ate-controller --tail=20"; fi
done
exit "$fail"
