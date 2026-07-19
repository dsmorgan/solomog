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
# onto external targets — it never vind-create/teardown/networks them (and vind-teardown only
# targets clusters recorded in .solomog/clusters, which an external one isn't).
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

# AWS preflight for the eks:* tasks. Ensures a WORKING AWS identity, robust to the #1 footgun:
# stale AWS_* left exported in the interactive shell SHADOW the fresh creds `aws:refresh` wrote to
# .env (go-task loads .env as dotenv, but OS-env wins over dotenv — verified). So `aws:refresh`
# updates .env yet the task still sees the old, expired shell creds. Here we RELOAD the cred vars
# straight from .env (overriding whatever the shell exported) and drop AWS_CREDENTIAL_EXPIRATION
# (a stale one poisons EKS get-token — "expired" even with fresh keys; .env never carries it), then
# verify with sts. Makes `solomog aws:refresh eks:delete CLUSTER=…` reliable regardless of shell state.
solomog_aws_preflight() {   # args: [<task-label>]
  local what="${1:-this task}" env_file line var
  env_file="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.env"
  unset AWS_CREDENTIAL_EXPIRATION
  if [ -f "$env_file" ]; then
    for var in AWS_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN; do   # NOT AWS_REGION — each script sets that from the cluster context
      line="$(grep -E "^${var}=" "$env_file" 2>/dev/null | tail -1)"
      [ -n "$line" ] && export "${line?}"
    done
  fi
  command -v aws >/dev/null 2>&1 || { echo "Error: aws CLI not found." >&2; exit 1; }
  aws sts get-caller-identity >/dev/null 2>&1 && return 0
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
