#!/usr/bin/env bash
# Leg 2, proved offline — no cluster, no Okta, no browser.
#
# The resource authorization server is the one component here written from scratch rather than
# configured, so it gets real unit coverage. This runs `src/resource_as.py` in-process against a FAKE
# enterprise IdP (a generated RSA key standing in for Okta's org signing key), mints ID-JAGs with it,
# and drives the actual HTTP /token endpoint.
#
# 25 assertions across four groups:
#   • the composite it mints          — sub=user, act.sub=the agent from the ID-JAG's client_id,
#                                       aud/iss/azp/scp/groups/idjag_jti, and the token verifies
#                                       against the JWKS the gateway will fetch
#   • narrow-never-escalate           — requesting above the ID-JAG's scope ceiling is dropped
#   • the groups fallback             — and that it self-reports as `groups_source: fallback`
#   • the rejections                  — wrong aud (replay containment), wrong issuer, expired,
#                                       no agent identity, bad client secret, wrong grant_type
#
# WHY IT RUNS FIRST (05): it needs nothing external, so it isolates "did I break the resource AS"
# from every Okta/cluster failure mode the later tests can hit. If this is red, fix it before
# looking at anything else. If this is green and test 20 is red, the problem is Okta or the gateway
# wiring, not leg 2.
#
# Runs via `uv` (no system pip — PEP 668), per the CLAUDE.md bundle idiom. Does not skip on missing
# XAA_* config: it has no dependency on it.
set -euo pipefail

command -v uv >/dev/null 2>&1 || { echo "✗ uv not found — install it: brew install uv (or: solomog setup)" >&2; exit 1; }

SRC="$(cd "$(dirname "$0")/../src" && pwd)"

uv run --quiet --python 3.12 --with 'pyjwt[crypto]>=2.8,<3' \
  python "$SRC/test_resource_as.py" "$SRC/resource_as.py"
