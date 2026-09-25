#!/usr/bin/env bash
# Print the path of the ID-token cache to use for one agent. The single place that knows how the cache
# is laid out, so no reader has to guess.
#
# Usage:  CACHE=$(bash helpers/xaa-token-path.sh a) || <caller decides: skip or fail>
#
# WHY THIS EXISTS. There are two supported login shapes, and they need different cache layouts:
#
#   one shared login app (the default)  ->  .solomog/xaa-id-token.json          ONE file
#   one login app per agent (hardened)  ->  .solomog/xaa-id-token-{a,b}.json    TWO files
#
# The first cut of the shared shape wrote the SAME token to both per-letter files, so every reader
# could stay unchanged. That was expedient and wrong: two files that must be byte-identical with
# nothing enforcing it invite exactly one question ("why are these the same?") and hide exactly one
# bug — switch shapes and back, and a leftover per-letter file quietly feeds an agent a token minted
# for a different app. The route would 401 with a valid-looking cache on disk.
#
# So xaa-login.sh now writes ONE layout and DELETES the other, and this resolves whichever is live.
# Per-letter wins when present, because its existence means the per-agent shape was the last thing
# written — but in practice only one layout is ever on disk at a time.
#
# Exits 1 (silently) when nothing is cached. Callers own the wording, because they disagree about
# severity: tests/08 skips, tests/50 fails.
set -euo pipefail

L="${1:?usage: xaa-token-path.sh <a|b>}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

PER="$REPO_DIR/.solomog/xaa-id-token-${L}.json"
SHARED="$REPO_DIR/.solomog/xaa-id-token.json"

if [ -f "$PER" ]; then
  printf '%s\n' "$PER"
elif [ -f "$SHARED" ]; then
  printf '%s\n' "$SHARED"
else
  exit 1
fi
