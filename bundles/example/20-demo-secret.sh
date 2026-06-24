#!/usr/bin/env bash
# Executable hook (.sh): RUN, not applied — at its sorted position (20-, so after the
# namespace from 01-). This is the escape hatch for imperative steps; the canonical use
# is creating a Secret from a credential kept in .env. Hooks inherit the environment
# (so .env values are present) plus CONTEXT / CLUSTER / GATEWAY / HOST, and are SKIPPED
# under DRY_RUN=true.
#
# This demo uses a harmless default so it always works. For a REAL secret, keep the value
# in .env and reference it here, e.g.:
#   --from-literal="Authorization=$CLAUDE_API_KEY"
# The hook then carries no secret and is safe to commit; only .env stays private.
set -euo pipefail

VALUE="${DEMO_SECRET:-demo-not-a-real-secret}"   # set DEMO_SECRET in .env to override

echo "    creating demo-secret in solomog-example (token from \$DEMO_SECRET, default demo)"
kubectl --context "$CONTEXT" create secret generic demo-secret -n solomog-example \
  --from-literal="token=${VALUE}" \
  --dry-run=client -o yaml | kubectl --context "$CONTEXT" apply -f -
