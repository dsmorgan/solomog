#!/usr/bin/env bash
# Cluster-target resolution — CLUSTER is the consistent knob everywhere; a registry maps external
# cluster names → their real kube context; CONTEXT is an explicit override.
#
# solomog_context <cluster> resolves in this order:
#   1. CONTEXT set                          → used VERBATIM (override / escape hatch).
#   2. <cluster> in .solomog/contexts       → its mapped context (EXTERNAL, e.g. EKS — recorded
#                                             by `eks:create` via solomog_register_context).
#   3. else                                 → vind default "vcluster-docker_<cluster>".
#
# A target is EXTERNAL when CONTEXT is set OR the cluster is in the registry. solomog only installs
# onto external targets — it never vind-creates/networks them. `solomog teardown` is type-agnostic
# (vind / vsphere / eks) and requires an explicit CLUSTER/CLUSTERS list; type-specific deletes are
# vind:delete / vsphere:delete / eks:delete.
#
# So the user says `CLUSTER=dmorgan-agw` for a registered EKS cluster exactly like `CLUSTER=aaa`
# for a vind one; CONTEXT is only needed for a context solomog hasn't recorded.
#
# Usage:
#   source "$REPO_DIR/scripts/lib/target.sh"
#   CTX="$(solomog_context "$CLUSTER")"
#   if solomog_is_external "$CLUSTER"; then ...skip vind-only steps... fi

_solomog_registry() {   # path to the external cluster→context registry
  printf '%s/.solomog/contexts' "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
}

# Echo the mapped context for a cluster from the registry, or nothing.
_solomog_registry_lookup() {   # args: <cluster>
  local reg; reg="$(_solomog_registry)"
  [ -f "$reg" ] || return 0
  awk -v c="$1" '$1==c{print $2; exit}' "$reg"
}

# ─── standalone instances (no cluster) ───────────────────────────────────────
# `solomog standalone` runs agentgateway as a Docker container with no Kubernetes at all.
# Those instances are still solomog-managed TARGETS, so they are registered here — one name
# per line in .solomog/standalone-instances. That registry is what lets cluster:list show
# them and `teardown` classify and destroy them alongside real clusters, without needing
# Docker to be up just to identify a name.
#
# The file is named -instances, not just `standalone`, because .solomog/standalone/ is the
# directory holding scratch instances' runtime state — one path cannot be both.

_solomog_standalone_registry() {
  printf '%s/.solomog/standalone-instances' "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
}

# True when <name> is a registered standalone instance.
solomog_is_standalone() {   # args: <name>
  local reg; reg="$(_solomog_standalone_registry)"
  [ -n "${1:-}" ] || return 1
  [ -f "$reg" ] || return 1
  awk -v c="$1" 'NF && $1==c{found=1} END{exit !found}' "$reg"
}

# Record a standalone instance name (idempotent).
solomog_register_standalone() {   # args: <name>
  local reg; reg="$(_solomog_standalone_registry)"
  [ -n "${1:-}" ] || return 1
  mkdir -p "$(dirname "$reg")"
  solomog_is_standalone "$1" && return 0
  printf '%s\n' "$1" >> "$reg"
}

# Drop a standalone instance name from the registry.
solomog_unregister_standalone() {   # args: <name>
  local reg tmp; reg="$(_solomog_standalone_registry)"
  [ -n "${1:-}" ] || return 1
  [ -f "$reg" ] || return 0
  tmp="$(mktemp "${reg}.XXXXXX")"
  awk -v c="$1" 'NF && $1!=c' "$reg" > "$tmp"
  mv "$tmp" "$reg"
}

# Echo registered standalone instance names, one per line.
solomog_standalone_names() {
  local reg; reg="$(_solomog_standalone_registry)"
  [ -f "$reg" ] || return 0
  awk 'NF{print $1}' "$reg" | LC_ALL=C sort -u
}

# Echo the kube context for a cluster name (CONTEXT override → registry → vind default).
solomog_context() {   # args: <cluster>
  if [ -n "${CONTEXT:-}" ]; then printf '%s' "$CONTEXT"; return; fi
  local mapped; mapped="$(_solomog_registry_lookup "$1")"
  if [ -n "$mapped" ]; then printf '%s' "$mapped"; return; fi
  printf 'vcluster-docker_%s' "$1"
}

# True when the target is external (non-vind): CONTEXT set, or the cluster is registered.
solomog_is_external() {   # args: [<cluster>]
  [ -n "${CONTEXT:-}" ] && return 0
  [ -n "${1:-}" ] && [ -n "$(_solomog_registry_lookup "$1")" ] && return 0
  return 1
}

# True when the cluster's resolved context is a solomog vsphere cluster (vsphere_<name>,
# registered by vsphere:create). vsphere clusters are EXTERNAL for lifecycle purposes
# (solomog only installs onto them, never vind-creates/teardowns them) but LOCAL for
# exposure purposes: their MetalLB VIP is a private IP nothing resolves, so expose
# treats them like vind (mkcert + /etc/hosts), NOT like a cloud LB with a public hostname.
solomog_is_vsphere() {   # args: [<cluster>]
  case "$(solomog_context "${1:-}")" in
    vsphere_*) return 0 ;;
    *)         return 1 ;;
  esac
}

# Echo vind|eks|vsphere|external for a cluster name. Registry-based — ignores ambient
# CONTEXT= so a leftover EKS context cannot recast a vind name. Unregistered names
# are vind (teardown / vind:delete). Unregistered EKS goes through eks:delete CONTEXT=…
# directly, not through this classifier.
solomog_cluster_type() {   # args: <cluster>
  local mapped
  mapped="$(_solomog_registry_lookup "${1:-}")"
  if [ -n "$mapped" ]; then
    case "$mapped" in
      arn:aws:eks:*) printf 'eks' ;;
      vsphere_*)     printf 'vsphere' ;;
      *)             printf 'external' ;;
    esac
    return
  fi
  # Checked after the contexts registry so a real cluster always wins the name, and before
  # the vind default so `teardown` never mistakes a standalone instance for a vcluster.
  # standalone.sh refuses to create an instance whose name is already a tracked cluster, so
  # in practice the two sets are disjoint.
  if solomog_is_standalone "${1:-}"; then printf 'standalone'; return; fi
  printf 'vind'
}

# Human-readable cluster label for display (routes/graph headers, filenames) and
# for hostname/descr derivation in expose. A user-supplied CLUSTER is already the
# right label — only derive one when it's empty (bare CONTEXT= override):
# vsphere_<name> → <name>, vcluster-docker_<name> → <name>, ARN-ish → last /-part.
solomog_display_name() {   # args: <cluster-or-empty> <context>
  if [ -n "${1:-}" ]; then printf '%s' "$1"; return 0; fi
  case "${2:-}" in
    vsphere_*)         printf '%s' "${2#vsphere_}" ;;
    vcluster-docker_*) printf '%s' "${2#vcluster-docker_}" ;;
    */*)               printf '%s' "${2##*/}" ;;
    *)                 printf '%s' "${2:-}" ;;
  esac
}

# Require a cluster target — no silent default. Pass the resolved cluster value (positional $1 or
# env $CLUSTER); passes if that's non-empty OR CONTEXT is set. Fails gracefully otherwise. Catches
# the common fat-fingers: omitting it entirely, or a lowercase `cluster=` (the task runner only sees
# the capitalized CLUSTER, so lowercase is silently dropped → empty here).
solomog_require_cluster() {   # args: <cluster-value> [<task-label>]
  { [ -n "${1:-}" ] || [ -n "${CONTEXT:-}" ]; } && return 0
  local task="${2:-this task}"
  {
    echo "Error: missing CLUSTER (or CONTEXT) for ${task}."
    echo "  → set CLUSTER=<name>           e.g. CLUSTER=ea1"
    echo "    or CONTEXT=<kube-context>    to target an unregistered external context"
    echo "  (note: it's CLUSTER, capitalized — a lowercase 'cluster=' is ignored by the task runner.)"
  } >&2
  exit 1
}

# Known cluster names (vind tracking ∪ external registry), one per line, sorted.
_solomog_known_names() {
  local root clusters
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  clusters="$root/.solomog/clusters"
  # `true` so a missing file doesn't fail the brace under `set -o pipefail`.
  {
    [ -f "$clusters" ] && awk 'NF{print $1}' "$clusters"
    [ -f "$(_solomog_registry)" ] && awk 'NF{print $1}' "$(_solomog_registry)"
    true
  } | awk 'NF' | LC_ALL=C sort -u
}

# Require an explicit CLUSTER/CLUSTERS list for destructive tasks. Unlike
# solomog_require_cluster, CONTEXT= is not a substitute (that would still be a
# silent default). Whitespace-only counts as missing. Lists known clusters so
# the fix is copy-pasteable. Exits 1.
solomog_require_cluster_list() {   # args: <cluster-value> [<task-label>]
  local val="${1:-}" task="${2:-this task}" names name typ
  # Word-split: a blank / whitespace-only value is missing. Function-local set.
  # shellcheck disable=SC2086
  set -- $val
  [ $# -ge 1 ] && return 0
  names="$(_solomog_known_names)"
  {
    echo "Error: ${task} requires CLUSTER=<name> or CLUSTERS=\"a b\"."
    echo "  It does not default to all clusters."
    echo "  Known clusters:"
    if [ -z "$names" ]; then
      echo "    (none — solomog cluster:list)"
    else
      while IFS= read -r name; do
        [ -n "$name" ] || continue
        typ="$(solomog_cluster_type "$name")"
        printf '    %-20s %s\n' "$name" "$typ"
      done <<EOF
$names
EOF
    fi
    echo "  Examples:"
    echo "    solomog ${task} CLUSTER=<name>"
    echo "    solomog ${task} CLUSTERS=\"aaa hl1 dmorgan-agw\""
    echo "  (note: it's CLUSTER, capitalized — a lowercase 'cluster=' is ignored by the task runner.)"
  } >&2
  exit 1
}

# Require <cluster> to classify as <expected> (vind|eks|vsphere). Exits 1 on mismatch
# with a pointer at the type-specific delete / type-agnostic teardown.
solomog_require_kind() {   # args: <cluster> <expected> [<task-label>]
  local cluster="${1:-}" expected="${2:-}" task="${3:-this task}" got
  got="$(solomog_cluster_type "$cluster")"
  [ "$got" = "$expected" ] && return 0
  {
    echo "Error: ${task} is for ${expected} clusters, but CLUSTER='${cluster}' is ${got}."
    case "$got" in
      vind|eks|vsphere)
        echo "  → solomog ${got}:delete CLUSTER=${cluster}"
        echo "    or  solomog teardown CLUSTER=${cluster}"
        ;;
      *)
        echo "  Registered as a generic external cluster — solomog will not destroy it."
        echo "  Delete it yourself, then drop it from .solomog/contexts if it still shows in cluster:list."
        ;;
    esac
  } >&2
  exit 1
}

# Reload the AWS cred vars from .env over whatever the shell exported. Parses .env with
# envfile_get (the dotenv parser) — NOT `export "$(grep ^KEY= .env)"`, which exports the raw
# line INCLUDING its trailing "# comment" field, so a commented .env (every key in
# .env.example carries one) silently poisons the value:
#   aws: [ERROR]: The config profile (AdministratorAccess-1700…   # e.g. solo-sso …) could not be found
# Also normalizes two set-but-EMPTY traps, since an empty var is NOT the same as an unset one:
#   • AWS_REGION="" is a documented .env state ("blank is fine"), but go-task exports it and
#     every region-less call then dies with: Invalid endpoint: https://sts..amazonaws.com
#   • a blank cred in .env must UNSET, not export "", so it can't shadow the profile.
# A key ABSENT from .env is left alone (a hand-exported AWS_PROFILE still works).
# Never exits — callers decide what missing creds mean.
solomog_aws_env_load() {
  local lib_dir env_file var val
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  env_file="$lib_dir/../../.env"
  . "$lib_dir/envfile.sh"
  unset AWS_CREDENTIAL_EXPIRATION   # a stale one poisons EKS get-token; .env never carries it
  if [ -f "$env_file" ]; then
    for var in AWS_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN; do   # NOT AWS_REGION — each script sets that from the cluster context
      if envfile_has "$env_file" "$var"; then
        val="$(envfile_get "$env_file" "$var" 2>/dev/null || true)"
        if [ -n "$val" ]; then export "$var=$val"; else unset "$var"; fi
      fi
    done
  fi
  for var in AWS_REGION AWS_DEFAULT_REGION; do
    eval "val=\${$var-__solomog_unset__}"
    if [ -z "$val" ]; then unset "$var"; fi
  done
  return 0
}

# True when AWS creds actually work. Probes region-less first (profile config supplies the
# region), then pins one — STS answers in any region, and a caller may have no region
# configured at all now that a blank AWS_REGION is unset rather than passed through.
solomog_aws_ok() {
  command -v aws >/dev/null 2>&1 || return 1
  aws sts get-caller-identity >/dev/null 2>&1 && return 0
  aws sts get-caller-identity --region us-east-1 >/dev/null 2>&1 && return 0
  return 1
}

# AWS preflight for the eks:* tasks. Ensures a WORKING AWS identity, robust to the #1 footgun:
# stale AWS_* left exported in the interactive shell SHADOW the fresh creds `aws:refresh` wrote to
# .env (go-task loads .env as dotenv, but OS-env wins over dotenv — verified). So `aws:refresh`
# updates .env yet the task still sees the old, expired shell creds. Here we RELOAD the cred vars
# straight from .env (overriding whatever the shell exported) and drop AWS_CREDENTIAL_EXPIRATION
# (a stale one poisons EKS get-token — "expired" even with fresh keys; .env never carries it), then
# verify with sts. Makes `solomog aws:refresh eks:delete CLUSTER=…` reliable regardless of shell state.
#
# The reload itself is solomog_aws_env_load; the identity check is solomog_aws_ok. Both are
# reusable so soft callers (cluster:list) can reload without the hard exit this adds.
solomog_aws_preflight() {   # args: [<task-label>]
  local what="${1:-this task}"
  solomog_aws_env_load
  command -v aws >/dev/null 2>&1 || { echo "Error: aws CLI not found." >&2; exit 1; }
  solomog_aws_ok && return 0
  {
    echo "Error: no working AWS credentials for ${what}."
    echo "  Fix (either):"
    echo "    • solomog aws:refresh            # writes fresh SSO creds to .env, then re-run — or chain:"
    echo "      solomog aws:refresh ${what} CLUSTER=<name>"
    echo "    • export AWS_PROFILE=<profile> && eval \"\$(aws configure export-credentials --format env)\""
    echo "  (Stale AWS_* exported in your shell shadow .env — this preflight reloads .env, but if the"
    echo "   SSO session itself is expired you must aws:refresh / re-login.)"
  } >&2
  exit 1
}

# Comma-separated list of registered external cluster names (for error hints), or "(none)".
_solomog_registry_list() {
  local reg; reg="$(_solomog_registry)"
  [ -f "$reg" ] || { printf '(none)'; return; }
  awk '{printf "%s%s", sep, $1; sep=", "} END{ if (NR==0) printf "(none)" }' "$reg"
}

# Guard for EKS-only tasks: require an external target, with a CLUSTER-first error. Exits 1 if not.
# CLUSTER is the primary knob; CONTEXT is only the escape hatch for an unregistered context — so the
# error leads with CLUSTER and names eks:create (which creates AND registers), not "set CONTEXT".
solomog_require_external() {   # args: <cluster> <task-label>
  local cluster="${1:-}" task="${2:-this task}"
  solomog_is_external "$cluster" && return 0
  {
    if [ -n "$cluster" ]; then
      echo "Error: ${task} targets an external (e.g. EKS) cluster, but CLUSTER='${cluster}' isn't one."
      echo "  • If you haven't created it with solomog yet:"
      echo "        solomog eks:create CLUSTER=${cluster}          # creates it AND registers the context"
      echo "  • If it already exists (created elsewhere), point at its kube context once:"
      echo "        CONTEXT=<kube-context> solomog ${task} CLUSTER=${cluster}"
    else
      echo "Error: ${task} targets an external (e.g. EKS) cluster — set CLUSTER=<name>."
      echo "  Use a cluster registered by eks:create, or CONTEXT=<kube-context> for an unregistered one."
    fi
    echo "  Registered external clusters: $(_solomog_registry_list)"
  } >&2
  exit 1
}

# Record a <cluster> → <context> mapping for an external target (e.g. from eks:create). Idempotent:
# replaces any existing entry for that cluster.
solomog_register_context() {   # args: <cluster> <context>
  local reg tmp; reg="$(_solomog_registry)"; tmp="${reg}.tmp"
  mkdir -p "$(dirname "$reg")"
  if [ -f "$reg" ]; then grep -v -E "^$1[[:space:]]" "$reg" > "$tmp" 2>/dev/null || true; mv "$tmp" "$reg"; fi
  printf '%s\t%s\n' "$1" "$2" >> "$reg"
  echo "==> registered cluster '$1' → context '$2' (.solomog/contexts)"
}

# Remove a cluster's registry entry (e.g. from eks:delete). No-op if absent.
solomog_deregister_context() {   # args: <cluster>
  local reg tmp; reg="$(_solomog_registry)"; tmp="${reg}.tmp"
  [ -f "$reg" ] || return 0
  grep -v -E "^$1[[:space:]]" "$reg" > "$tmp" 2>/dev/null || true
  mv "$tmp" "$reg"
  [ -s "$reg" ] || rm -f "$reg"
  echo "==> deregistered cluster '$1' (.solomog/contexts)"
}
