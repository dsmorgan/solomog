#!/usr/bin/env bash
set -euo pipefail

# The direct response proves that the route-level policy was selected.
curl --fail-with-body -sS "https://$HOST/logging/healthz" |
  jq -e '.status == "ok" and .policy == "logging-direct-response"'

# An unmatched path provides a failure response for access-log filtering experiments.
code="$(curl -sS -o /dev/null -w '%{http_code}' "https://$HOST/logging/missing")"
case "$code" in
  4??|5??) echo "  ✓ unmatched path returned HTTP $code" ;;
  *) echo "expected an HTTP error for unmatched path, got $code"; exit 1 ;;
esac
