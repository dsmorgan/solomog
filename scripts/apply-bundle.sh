#!/usr/bin/env bash
set -euo pipefail
#
# Applies a "bundle" — a directory of custom manifests — to a cluster, in order.
# This is the escape hatch for customer-specific / repro config that isn't worth
# generalizing into a product or app module: drop YAML in bundles/<name>/ and apply it.
#
# Ordering: files are applied in LC_ALL=C sorted order. Prefix names with a
# zero-padded number to sequence them (01-, 02-, ... 10-). Leave gaps (10/20/30)
# so you can wedge files in later. Sorting is byte-stable (LC_ALL=C), so padding —
# not natural sort — is what guarantees 02 before 10.
#
# Executable hooks: a file ending in `.sh` is RUN (not applied) at its place in the
# sorted order — the escape hatch for imperative steps that don't fit declarative YAML,
# e.g. creating a Secret from a credential in .env:
#     # bundles/<name>/05-anthropic-secret.sh
#     kubectl --context "$CONTEXT" create secret generic anthropic-secret -n agentgateway-system \
#       --from-literal="Authorization=$CLAUDE_API_KEY" --dry-run=client -o yaml \
#       | kubectl --context "$CONTEXT" apply -f -
# Hooks inherit the environment (so .env values like $CLAUDE_API_KEY are present) plus
# CONTEXT / CLUSTER / GATEWAY / HOST, and run with cwd = the bundle dir. Because the
# secret VALUE stays in .env, the hook script carries no secret and is safe to commit.
# Hooks are SKIPPED under DRY_RUN (we can't assume an arbitrary script is side-effect free).
#
# Templating (opt-in, per file): a file ending in `.yaml.tmpl` is rendered with a
# small fixed set of %%TOKEN%% substitutions before apply; plain `.yaml` is applied
# verbatim. The %%TOKEN%% syntax (not $VAR) is deliberate — it can't clash with `$`
# that legitimately appears in manifests, and needs no envsubst/gettext dependency.
# Supported tokens:
#     %%CLUSTER%%   bare cluster name            (e.g. aaa)
#     %%GATEWAY%%   gateway name                 (default agw; GATEWAY=)
#     %%HOST%%      gateway host                 (default <GATEWAY>.<CLUSTER>.test; HOST=)
# An unrecognized %%FOO%% left after rendering is a hard error (catches typos).
#
# Bundle resolution (hybrid git layout): bundles/<name>/ (committed) or
# bundles/private/<name>/ (gitignored, for sensitive config). private wins if both exist.
#
# kubectl apply is declarative + idempotent, so re-running a bundle is safe. There is
# NO prune: deleting a file from the bundle does not delete the resource (by design —
# auto-prune is too easy to misfire). Stop-on-first-error (set -e) surfaces ordering
# bugs (e.g. a CR before its CRD) immediately; fix and re-run.
#
# Usage: apply-bundle.sh <kube-context>
# Env:
#   BUNDLE    (required) bundle name under bundles/ or bundles/private/
#   DRY_RUN   true|false (default false) — server-side dry-run, applies nothing
#   GATEWAY   gateway name for %%GATEWAY%% (default: auto-detected agw/kgw from the cluster)
#   HOST      host for %%HOST%% (default <GATEWAY>.<CLUSTER>.test)

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_DIR/scripts/lib/gateway.sh"
CONTEXT="${1:?Usage: apply-bundle.sh <kube-context>}"
CLUSTER="${CONTEXT#vcluster-docker_}"
BUNDLE="${BUNDLE:?Set BUNDLE=<name>. List options with: solomog bundles:list}"
DRY_RUN="${DRY_RUN:-false}"
# Auto-detect the gateway (agw/kgw) so %%GATEWAY%%/%%HOST%% render correctly per cluster.
GATEWAY="${GATEWAY:-$(solomog_detect_gateway "$CONTEXT")}"
HOST="${HOST:-${GATEWAY}.${CLUSTER}.test}"

# Resolve the bundle directory (private overrides committed).
DIR=""
if [[ -d "$REPO_DIR/bundles/private/$BUNDLE" ]]; then
  DIR="$REPO_DIR/bundles/private/$BUNDLE"
  [[ -d "$REPO_DIR/bundles/$BUNDLE" ]] && echo "    (note: both committed and private '$BUNDLE' exist — using private)"
elif [[ -d "$REPO_DIR/bundles/$BUNDLE" ]]; then
  DIR="$REPO_DIR/bundles/$BUNDLE"
else
  echo "Error: bundle '$BUNDLE' not found in bundles/ or bundles/private/." >&2
  echo "       Available: $(bash "$REPO_DIR/scripts/bundles.sh" names 2>/dev/null | tr '\n' ' ')" >&2
  exit 1
fi

# Collect manifests in deterministic order (.yaml, .yml, and their .tmpl variants).
FILES="$(cd "$DIR" && LC_ALL=C ls 2>/dev/null | grep -E '\.(yaml|yml)(\.tmpl)?$|\.sh$' | LC_ALL=C sort || true)"
if [[ -z "$FILES" ]]; then
  echo "Error: bundle '$BUNDLE' ($DIR) has no .yaml/.yml manifests." >&2
  exit 1
fi

# Render %%TOKEN%% placeholders. `|` delimiter is safe — none of the values contain it.
render() {
  sed -e "s|%%CLUSTER%%|${CLUSTER}|g" \
      -e "s|%%GATEWAY%%|${GATEWAY}|g" \
      -e "s|%%HOST%%|${HOST}|g" \
      "$1"
}

APPLY_ARGS=(apply)
[[ "$DRY_RUN" == "true" ]] && APPLY_ARGS+=(--dry-run=server)

echo "==> Applying bundle '$BUNDLE' to ${CONTEXT}"
[[ "$DRY_RUN" == "true" ]] && echo "    DRY RUN (server-side) — nothing will be written"
echo "    dir: ${DIR}"
echo "    vars: CLUSTER=${CLUSTER} GATEWAY=${GATEWAY} HOST=${HOST}"

while IFS= read -r name; do
  [[ -z "$name" ]] && continue
  f="$DIR/$name"
  case "$name" in
    *.sh)
      if [[ "$DRY_RUN" == "true" ]]; then
        echo "==> [skip in dry-run] ${name}"
      else
        echo "==> [exec] ${name}"
        # Hook inherits the env (.env values) + the targeting vars; cwd = bundle dir.
        ( cd "$DIR" && CONTEXT="$CONTEXT" CLUSTER="$CLUSTER" GATEWAY="$GATEWAY" HOST="$HOST" \
            bash "./$name" )
      fi ;;
    *.tmpl)
      echo "==> [tmpl] ${name}"
      rendered="$(render "$f")"
      leftover="$(printf '%s\n' "$rendered" | grep -oE '%%[A-Z0-9_]+%%' | LC_ALL=C sort -u || true)"
      if [[ -n "$leftover" ]]; then
        echo "Error: unsubstituted token(s) in ${name}: $(echo "$leftover" | tr '\n' ' ')" >&2
        echo "       Supported tokens: %%CLUSTER%% %%GATEWAY%% %%HOST%%" >&2
        exit 1
      fi
      printf '%s\n' "$rendered" | kubectl --context "$CONTEXT" "${APPLY_ARGS[@]}" -f - ;;
    *)
      echo "==> ${name}"
      kubectl --context "$CONTEXT" "${APPLY_ARGS[@]}" -f "$f" ;;
  esac
done <<EOF
$FILES
EOF

echo ""
echo "✓ Bundle '$BUNDLE' applied to ${CLUSTER}$([[ "$DRY_RUN" == "true" ]] && echo ' (dry-run)')"
