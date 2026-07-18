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
