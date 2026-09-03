#!/usr/bin/env bash
# The question this bundle exists to answer: does the same trace technique work on an MCP
# relay route?
#
# The access log cannot see the exchanged token there (test 60) because the relay exchanges on
# its own upstream call. Whether a debug trace still records that call's token-endpoint
# response is what decides if there is a usable workaround today.
#
# This test does not assert a direction -- it reports what happened and fails only if the trace
# itself could not be captured. Either outcome is a finding; record it in docs/FINDINGS.md.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

command -v agctl >/dev/null || { echo "↷ skipped — agctl not installed"; exit 0; }

out="$(bash "$HERE/../helpers/capture-trace.sh" mcp 2>&1)" || { echo "$out" >&2; exit 1; }
printf '%s\n' "$out"

if printf '%s' "$out" | grep -q "OAuth token response"; then
  echo "✓ MCP relay route: the exchanged token IS readable from the trace."
  echo "  → the workaround covers the customer's shape; note it on agentgateway-enterprise#7844."
else
  echo "! MCP relay route: NO token-endpoint body snapshot in the trace."
  echo "  → the relay's exchange is invisible to tracing as well as to access logs, so"
  echo "    #7844 is the only route to observability on this path. Record which body"
  echo "    snapshot stages DID appear above; that is the evidence for the issue."
fi
