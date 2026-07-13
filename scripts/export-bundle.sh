#!/usr/bin/env bash
set -euo pipefail
#
# export-bundle.sh — Phase 1 of `solomog export`.
#
# Produces a portable, secret-safe hand-off package from a bundle's DECLARATIVE source.
# Stateless: touches NO cluster (drift verification against a live cluster is Phase 3).
#
# Phase 1 handles:
#   .yaml/.yml     → copied verbatim into manifests/
#   .yaml.tmpl     → %%TOKEN%% rendered (CLUSTER/GATEWAY/HOST) into manifests/
#   .sh hooks      → NOT executed yet (that's Phase 2's kubectl-interception shim). Copied
#                    into manual-steps/ and surfaced in README as explicit manual steps, so
#                    the package never LOOKS complete when a hook's config isn't captured.
#   env.example    → the .env vars this bundle needs (bundle refs ∩ .env.example), secrets flagged
#   install/       → resolved agentgateway install values (helmfile build, best-effort)
#   PREREQUISITES  → product + version + flags (flags best-effort from the run audit log)
#   README.md      → overview + FULL apply order (manifests + manual steps, interleaved) + verify
#   secret backstop→ scans the whole package for real .env secret VALUES; redacts + loudly
#                    reports any leak (static files carry no secrets by design — this is a net).
#
# Usage: export-bundle.sh
# Env:
#   BUNDLE   (required) ONE bundle name (a hand-off package is per-bundle)
#   OUT      output dir              default .solomog/exports/<bundle>-<ts>
#   EDITION  enterprise|community    default enterprise  (for the resolved install values)
#   CLUSTER  value for %%CLUSTER%%   default "example"   (recipient substitutes)
#   GATEWAY  value for %%GATEWAY%%   default agw
#   HOST     value for %%HOST%%      default <GATEWAY>.<CLUSTER>.test

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BUNDLE="${BUNDLE:?Set BUNDLE=<name>. List options with: solomog bundles:list}"
# Phase 1 exports a single bundle; if a list slipped through, take the first and warn.
case "$BUNDLE" in *" "*) echo "Note: export takes ONE bundle; using the first ('${BUNDLE%% *}')." >&2; BUNDLE="${BUNDLE%% *}" ;; esac
EDITION="${EDITION:-enterprise}"
CLUSTER="${CLUSTER:-example}"
GATEWAY="${GATEWAY:-agw}"
HOST="${HOST:-${GATEWAY}.${CLUSTER}.test}"
TS="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo export)"
OUT="${OUT:-$REPO_DIR/.solomog/exports/${BUNDLE}-${TS}}"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; D=$'\033[2m'; G=$'\033[32m'; Y=$'\033[33m'; RED=$'\033[31m'; R=$'\033[0m'
else B=''; D=''; G=''; Y=''; RED=''; R=''; fi

# ── Resolve bundle dir (private overrides committed — same rule as apply-bundle). ─
DIR=""
if [ -d "$REPO_DIR/bundles/private/$BUNDLE" ]; then DIR="$REPO_DIR/bundles/private/$BUNDLE"
elif [ -d "$REPO_DIR/bundles/$BUNDLE" ]; then DIR="$REPO_DIR/bundles/$BUNDLE"
else
  echo "Error: bundle '$BUNDLE' not found in bundles/ or bundles/private/." >&2
  echo "       Available: $(bash "$REPO_DIR/scripts/bundles.sh" names 2>/dev/null | tr '\n' ' ')" >&2
  exit 1
fi

# Render %%TOKEN%% placeholders (same substitution set as apply-bundle's render()).
render() { sed -e "s|%%CLUSTER%%|${CLUSTER}|g" -e "s|%%GATEWAY%%|${GATEWAY}|g" -e "s|%%HOST%%|${HOST}|g" "$1"; }

_is_secret() {  # name looks like a credential?
  case "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')" in
    *KEY*|*TOKEN*|*SECRET*|*PASSWORD*|*PASS*) return 0 ;; *) return 1 ;;
  esac
}

# Does a value look like actual credential MATERIAL (vs a resource name / ref that a
# secret-NAMED var might legitimately hold, e.g. TOKEN_EXCHANGE_ELICITATION_SECRET=
# snowflake-elicitation)? Only credential-shaped values are safe to auto-redact —
# blindly redacting a resource name would corrupt the very manifests/hooks that
# reference it. Heuristic: long, and either character-diverse (upper/special) or a
# long uniform token; short lowercase-hyphen names are treated as non-credential.
_cred_shaped() {
  local v="$1"
  [ "${#v}" -ge 16 ] || return 1
  case "$v" in
    *[!a-z0-9.-]*) return 0 ;;                          # has upper/_/+//= etc → diverse → credential-like
    *) [ "${#v}" -ge 32 ] && return 0 || return 1 ;;    # all-lowercase name-ish: only if very long
  esac
}

echo "==> Exporting bundle '${BUNDLE}'  (edition=${EDITION})"
echo "    source: ${DIR}"
echo "    render: CLUSTER=${CLUSTER} GATEWAY=${GATEWAY} HOST=${HOST}"
echo "    out:    ${OUT}"
rm -rf "$OUT"; mkdir -p "$OUT/manifests"

# ── Walk the bundle in apply order; split into manifests vs manual steps. ────────
files="$(cd "$DIR" && LC_ALL=C ls 2>/dev/null | grep -E '\.(yaml|yml)(\.tmpl)?$|\.sh$' | LC_ALL=C sort || true)"
ORDER=""        # "type\tstepname\tnote" lines, in apply order — drives the README
HOOK_COUNT=0; MANIFEST_COUNT=0
while IFS= read -r name; do
  [ -z "$name" ] && continue
  f="$DIR/$name"
  case "$name" in
    *.sh)
      mkdir -p "$OUT/manual-steps"
      cp "$f" "$OUT/manual-steps/$name"
      # First non-shebang, non-blank comment line = a human summary of the hook.
      desc="$(grep -m1 -E '^#[^!]' "$f" 2>/dev/null | sed 's/^#[[:space:]]*//' || true)"
      ORDER="${ORDER}manual	${name}	${desc}
"
      HOOK_COUNT=$((HOOK_COUNT + 1)) ;;
    *.tmpl)
      out="${name%.tmpl}"
      rendered="$(render "$f")"
      leftover="$(printf '%s\n' "$rendered" | grep -oE '%%[A-Z0-9_]+%%' | LC_ALL=C sort -u || true)"
      if [ -n "$leftover" ]; then
        echo "Error: unsubstituted token(s) in ${name}: $(echo "$leftover" | tr '\n' ' ')" >&2
        echo "       Supported: %%CLUSTER%% %%GATEWAY%% %%HOST%%" >&2
        exit 1
      fi
      printf '%s\n' "$rendered" > "$OUT/manifests/$out"
      ORDER="${ORDER}manifest	${out}	(rendered from ${name})
"
      MANIFEST_COUNT=$((MANIFEST_COUNT + 1)) ;;
    *)
      cp "$f" "$OUT/manifests/$name"
      ORDER="${ORDER}manifest	${name}
"
      MANIFEST_COUNT=$((MANIFEST_COUNT + 1)) ;;
  esac
done <<EOF
$files
EOF
echo "    ${MANIFEST_COUNT} manifest(s), ${HOOK_COUNT} manual step(s)"

# ── env.example: the .env vars this bundle needs (bundle refs ∩ .env.example). ───
# Intersecting with .env.example avoids shell-noise false positives — .env.example is
# the canonical list of user-supplied vars, so the intersection is exactly what a
# recipient must provide. Secrets (by name) go in one section, plain config in another.
EX="$REPO_DIR/.env.example"
NEEDED=""
if [ -f "$EX" ]; then
  exkeys="$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$EX" | sed 's/=$//' | LC_ALL=C sort -u)"
  refs="$(cat "$DIR"/*.sh "$DIR"/*.tmpl "$DIR"/*.yaml "$DIR"/*.yml 2>/dev/null \
    | grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*\}?' | tr -d '${}' | LC_ALL=C sort -u || true)"
  required="$(grep -rhoE '\$\{[A-Za-z_][A-Za-z0-9_]*:\?' "$DIR"/*.sh 2>/dev/null | tr -d '${' | sed 's/:?$//' | LC_ALL=C sort -u || true)"
  NEEDED="$(printf '%s\n' "$refs" | grep -Fxf <(printf '%s\n' "$exkeys") 2>/dev/null || true)"
fi

ENVOUT="$OUT/env.example"
{
  echo "# Environment this bundle needs. Copy to a private .env and fill in values."
  echo "# Generated by 'solomog export' from bundle '${BUNDLE}'."
  echo
  echo "# ── Secrets (sensitive — never commit real values) ─────────────────────────"
} > "$ENVOUT"
sec_n=0; cfg_lines=""
if [ -n "$NEEDED" ]; then
  while IFS= read -r k; do
    [ -z "$k" ] && continue
    tag="optional"; printf '%s\n' "$required" | grep -Fxq "$k" && tag="required"
    if _is_secret "$k"; then
      printf '%s=""              # %s\n' "$k" "$tag" >> "$ENVOUT"; sec_n=$((sec_n + 1))
    else
      cfg_lines="${cfg_lines}${k}=\"\"              # ${tag}
"
    fi
  done <<EOF
$NEEDED
EOF
fi
[ "$sec_n" -eq 0 ] && echo "# (none)" >> "$ENVOUT"
{
  echo
  echo "# ── Config (non-secret, but bundle-specific) ───────────────────────────────"
  if [ -n "$cfg_lines" ]; then printf '%s' "$cfg_lines"; else echo "# (none)"; fi
} >> "$ENVOUT"

# ── install/: resolved agentgateway install values (best-effort, offline). ──────
# `helmfile build` resolves the release + values without pulling charts or touching a
# cluster. Secret env (license keys) is sentinel-seeded so nothing real lands in the file.
mkdir -p "$OUT/install"
INSTALL_NOTE="$OUT/install/values.yaml"
MOD="$REPO_DIR/helmfiles/products/agentgateway.yaml.gotmpl"
build_ok=false
if [ -f "$MOD" ] && command -v helmfile >/dev/null 2>&1; then
  if (
      set -a
      [ -f "$REPO_DIR/versions.env" ] && . "$REPO_DIR/versions.env"
      SOLO_LICENSE_KEY="%%SOLO_LICENSE_KEY%%"; AGENTGATEWAY_LICENSE_KEY="%%AGENTGATEWAY_LICENSE_KEY%%"
      SOLO_CONTEXT="vcluster-docker_${CLUSTER}"; SOLO_CLUSTER="$CLUSTER"; ISTIO_MODE=ambient
      set +a
      helmfile -e "$EDITION" -f "$MOD" build
    ) > "$INSTALL_NOTE" 2>/dev/null && [ -s "$INSTALL_NOTE" ]; then
    build_ok=true
    # Scrub local paths helmfile build embeds (repo dir + home, incl. helm cache) — not
    # secret, just not portable. Repo first (more specific), then home.
    SM_RD="$REPO_DIR" perl -i -pe 's/\Q$ENV{SM_RD}\E/<repo>/g' "$INSTALL_NOTE" 2>/dev/null || true
    SM_H="$HOME" perl -i -pe 's/\Q$ENV{SM_H}\E/<home>/g' "$INSTALL_NOTE" 2>/dev/null || true
    echo "    resolved install values → install/values.yaml"
  fi
fi
if [ "$build_ok" != true ]; then
  {
    echo "# Resolved values were not captured offline (helmfile build unavailable/failed)."
    echo "# Install enterprise agentgateway per PREREQUISITES.md; chart coordinates are there."
  } > "$INSTALL_NOTE"
fi

# ── PREREQUISITES.md: product, version, and (best-effort) the flags used. ───────
AGW_VER="$(grep -E '^AGENTGATEWAY_VERSION=' "$REPO_DIR/versions.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true)"
[ -z "$AGW_VER" ] && AGW_VER="(see versions.env)"
# Mine the run audit log for the flags that were active on recent agentgateway installs.
FLAGS=""
AUDIT_GLOB="$REPO_DIR/.solomog/audit"/*.log
for lg in $AUDIT_GLOB; do [ -f "$lg" ] || continue
  FLAGS="${FLAGS}$(grep -hE 'agentgateway|stack' "$lg" 2>/dev/null \
    | grep -oE '(TOKEN_EXCHANGE|OAUTH_ISSUER|EDITION)=[^ ]+' | LC_ALL=C sort -u || true)
"
done
FLAGS="$(printf '%s\n' "$FLAGS" | grep -v '^$' | LC_ALL=C sort -u || true)"
{
  echo "# Prerequisites for '${BUNDLE}'"
  echo
  echo "This package is the **configuration layer**. It assumes an agentgateway install"
  echo "is already present on the target cluster, then applies the manifests in \`manifests/\`."
  echo
  echo "## Product"
  echo
  echo "- **Enterprise agentgateway** \`${AGW_VER}\` (edition: ${EDITION})"
  echo "- Namespace \`agentgateway-system\`, GatewayClass \`enterprise-agentgateway\`"
  echo "- Gateway API CRDs + the agentgateway/enterprise CRDs must be installed."
  echo
  echo "## Install flags detected (best-effort — from this repo's run audit log; verify)"
  echo
  if [ -n "$FLAGS" ]; then printf '%s\n' "$FLAGS" | sed 's/^/- `/; s/$/`/'; else echo "- (none found in audit log — confirm whether tokenExchange / OAuth issuer were enabled)"; fi
  echo
  echo "## Resolved install values"
  echo
  echo "See \`install/values.yaml\` (license keys are sentinel placeholders — supply your own)."
} > "$OUT/PREREQUISITES.md"

# ── README.md: overview + FULL apply order (manifests + manual steps interleaved). ─
{
  echo "# ${BUNDLE} — exported configuration"
  echo
  echo "Portable, secret-safe export of the \`${BUNDLE}\` agentgateway configuration,"
  echo "generated by \`solomog export\`. Apply it to any cluster that already has"
  echo "agentgateway installed (see \`PREREQUISITES.md\`) — solomog is not required."
  echo
  echo "## Contents"
  echo
  echo "- \`manifests/\` — the config, in apply order. \`kubectl apply -f manifests/\` applies"
  echo "  them in filename (\`NN-\`) order."
  echo "- \`env.example\` — environment values this config needs (secrets flagged). Fill in a"
  echo "  private copy before running any manual step."
  echo "- \`PREREQUISITES.md\` — product, version, and install flags."
  echo "- \`install/values.yaml\` — resolved agentgateway install values (reference)."
  [ "$HOOK_COUNT" -gt 0 ] && echo "- \`manual-steps/\` — imperative steps not yet captured as manifests (see below)."
  echo
  echo "## Substitute before applying"
  echo
  echo "These example values were rendered in; change them for your environment:"
  echo
  echo "| token | value used | meaning |"
  echo "|-------|------------|---------|"
  echo "| \`%%CLUSTER%%\` | \`${CLUSTER}\` | cluster name (appears in hostnames) |"
  echo "| \`%%GATEWAY%%\` | \`${GATEWAY}\` | Gateway resource name |"
  echo "| \`%%HOST%%\` | \`${HOST}\` | gateway hostname |"
  echo
  echo "## Apply order"
  echo
  printf '%s' "$ORDER" | while IFS=$'\t' read -r ty step note; do
    [ -z "$ty" ] && continue
    if [ "$ty" = manifest ]; then
      echo "1. \`manifests/${step}\`${note:+  ${note}}"
    else
      echo "1. ⚠ **manual step** — \`manual-steps/${step}\`${note:+ — ${note}}"
    fi
  done
  if [ "$HOOK_COUNT" -gt 0 ]; then
    echo
    echo "## ⚠ Manual steps (not yet captured as manifests)"
    echo
    echo "This bundle uses ${HOOK_COUNT} imperative hook(s). Their config is **not** in"
    echo "\`manifests/\` — a future export version will capture their rendered output. For now,"
    echo "port each by hand (the scripts are in \`manual-steps/\`, and reference \`env.example\`):"
    echo
    printf '%s' "$ORDER" | while IFS=$'\t' read -r ty step note; do
      [ "$ty" = manual ] || continue
      echo "- \`${step}\`${note:+ — ${note}}"
    done
  fi
  echo
  echo "## Verify"
  echo
  echo "After applying, check every route is active:"
  echo
  echo '```'
  echo "kubectl get httproute -n agentgateway-system \\"
  echo "  -o custom-columns=NAME:.metadata.name,ACCEPTED:'.status.parents[*].conditions[?(@.type==\"Accepted\")].status'"
  echo '```'
} > "$OUT/README.md"

# ── Secret backstop: scan the whole package for real .env secret VALUES. ────────
# Static files carry no secrets by design; this catches a hand-inlined credential or a
# license leaking via the resolved values. Redact + report loudly (never silent).
LEAKS=0
if [ -f "$REPO_DIR/.env" ]; then
  while IFS= read -r line; do
    case "$line" in \#*|'') continue ;; *=*) : ;; *) continue ;; esac
    k="${line%%=*}"; v="${line#*=}"
    v="${v%%#*}"; v="${v%"${v##*[![:space:]]}"}"          # drop inline comment + rtrim
    v="${v#\"}"; v="${v%\"}"; v="${v#\'}"; v="${v%\'}"      # strip quotes
    _is_secret "$k" || continue
    _cred_shaped "$v" || continue                          # only redact real credential material
    # Does this real value appear anywhere in the package?
    if grep -rFq -- "$v" "$OUT" 2>/dev/null; then
      echo "${RED}⚠ SECRET LEAK: value of ${k} found in the export — redacting.${R}" >&2
      # Redact every occurrence across the package (perl \Q…\E quotes metachars safely).
      grep -rFl -- "$v" "$OUT" 2>/dev/null | while IFS= read -r hit; do
        SM_V="$v" SM_K="$k" perl -i -pe 's/\Q$ENV{SM_V}\E/%%$ENV{SM_K}%%/g' "$hit"
      done
      LEAKS=$((LEAKS + 1))
    fi
  done < "$REPO_DIR/.env"
fi

echo
if [ "$LEAKS" -gt 0 ]; then
  echo "${Y}⚠ ${LEAKS} secret value(s) were found and redacted to %%NAME%% placeholders."
  echo "  Review the flagged files before sharing.${R}"
else
  echo "${G}✓ secret scan clean — no .env secret values present in the package.${R}"
fi
echo "${B}✓ exported '${BUNDLE}'${R} → ${OUT}"
echo "  ${D}manifests: ${MANIFEST_COUNT}   manual steps: ${HOOK_COUNT}   secrets to supply: ${sec_n}${R}"
echo "  ${D}tar it for hand-off:  tar -czf ${BUNDLE}-export.tgz -C \"$(dirname "$OUT")\" \"$(basename "$OUT")\"${R}"
