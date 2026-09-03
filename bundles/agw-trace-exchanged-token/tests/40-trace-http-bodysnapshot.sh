#!/usr/bin/env bash
# Does a debug trace expose the exchanged token on an HTTP-backend route?
#
# Expected: yes. The exchange is an ordinary backend call, so the authorization server's
# response body -- which by RFC 6749 contains access_token -- is captured as a bodySnapshot.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

command -v agctl >/dev/null || { echo "↷ skipped — agctl not installed (see helpers/capture-trace.sh for the install line)"; exit 0; }

out="$(bash "$HERE/../helpers/capture-trace.sh" http 2>&1)" || { echo "$out" >&2; exit 1; }
printf '%s\n' "$out"

printf '%s' "$out" | grep -q "OAuth token response" || {
  echo "✗ no token-endpoint body snapshot in the trace for the HTTP route." >&2
  echo "  Either the exchange did not run, or body snapshots are not emitted on this build." >&2
  exit 1; }
echo "✓ HTTP route: the exchanged token is readable from the trace's response body snapshot"
