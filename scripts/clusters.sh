#!/usr/bin/env bash
set -euo pipefail
#
# Lists / inspects solomog-tracked clusters (vind + registered externals).
# Local registries + soft live checks — no kubectl API:
#   • vind: `vcluster list` (Docker) → running|gone|?
#   • eks:  `aws eks describe-cluster` when AWS creds work → running|gone|…;
#           expired/broken/missing creds stay "—" (undetermined), never fail the list.
# Marks the current kubectl context.
#
# Usage:
#   clusters.sh list              pretty table of known clusters
#   clusters.sh show <name>       detail for one cluster
#   clusters.sh names             bare names, one per line
#
# Task entrypoints: solomog cluster:list / cluster:show
# (aliases: clusters:list, clusters, cluster / clusters:show)

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTERS_FILE="$REPO_DIR/.solomog/clusters"
CONTEXTS_FILE="$REPO_DIR/.solomog/contexts"
MODE="${1:-list}"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  G=$'\033[32m'; B=$'\033[1m'; D=$'\033[2m'; Y=$'\033[33m'; R=$'\033[0m'
else
  G=''; B=''; D=''; Y=''; R=''
fi

# ─── registry helpers ────────────────────────────────────────────────────────

_registry_lookup() {   # args: <cluster> → context or empty
  [ -f "$CONTEXTS_FILE" ] || return 0
  awk -v c="$1" '$1==c{print $2; exit}' "$CONTEXTS_FILE"
}

# Resolved kube context for a name (registry → vind default). Ignores CONTEXT env
# so a one-off override doesn't rewrite every row in the list.
_ctx_for() {
  local mapped; mapped="$(_registry_lookup "$1")"
  if [ -n "$mapped" ]; then printf '%s' "$mapped"; return; fi
  printf 'vcluster-docker_%s' "$1"
}

_type_for() {   # args: <cluster> <context>
  if [ -n "$(_registry_lookup "$1")" ]; then
    case "$2" in
      arn:aws:eks:*) printf 'eks' ;;
      *)             printf 'external' ;;
    esac
  else
    printf 'vind'
  fi
}

_eks_region() {   # args: <context> → region or empty
  case "$1" in
    arn:aws:eks:*) printf '%s' "$1" | awk -F: '{print $4}' ;;
  esac
}

# Echo tracked vind names (one per line).
_tracked_vind() {
  [ -f "$CLUSTERS_FILE" ] || return 0
  awk 'NF{print $1}' "$CLUSTERS_FILE"
}

# Echo registered external names (one per line).
_tracked_external() {
  [ -f "$CONTEXTS_FILE" ] || return 0
  awk 'NF{print $1}' "$CONTEXTS_FILE"
}

# Union of all known names, sorted.
_all_names() {
  { _tracked_vind; _tracked_external; } | awk 'NF' | LC_ALL=C sort -u
}

# Current kubectl context, or empty if unavailable.
_current_context() {
  command -v kubectl >/dev/null 2>&1 || return 0
  kubectl config current-context 2>/dev/null || true
}

# Populate VCLUSTER_RAW / VCLUSTER_LIST / VCLUSTER_OK from `vcluster list` (Docker, not API).
# VCLUSTER_OK=1 when the list succeeded; 0 when vcluster/docker unavailable.
VCLUSTER_RAW=""
VCLUSTER_LIST=""
VCLUSTER_OK=0
_load_vclusters() {
  VCLUSTER_RAW=""
  VCLUSTER_LIST=""
  VCLUSTER_OK=0
  command -v vcluster >/dev/null 2>&1 || return 0
  local out
  # Capture stderr separately so a docker failure doesn't poison the name list.
  if out="$(vcluster list 2>/dev/null)"; then
    VCLUSTER_OK=1
    VCLUSTER_RAW="$out"
    # Same parse as vind-create/teardown; drop table chrome / non-name tokens.
    VCLUSTER_LIST="$(printf '%s\n' "$out" | awk 'NR>1 && $1 ~ /^[A-Za-z0-9][A-Za-z0-9_-]*$/ {print $1}')"
  fi
}

_vcluster_running() {   # args: <name> → 0 if present in live list
  [ "$VCLUSTER_OK" = 1 ] || return 1
  printf '%s\n' "$VCLUSTER_LIST" | grep -qxF "$1"
}

# Soft AWS identity for EKS status. Same .env-reload footgun fix as
# solomog_aws_preflight, but NEVER exits — bad/expired creds just leave AWS_OK=0
# so EKS rows keep status "—".
AWS_OK=0
_load_aws() {
  AWS_OK=0
  command -v aws >/dev/null 2>&1 || return 0
  local env_file="$REPO_DIR/.env" line var
  unset AWS_CREDENTIAL_EXPIRATION
  if [ -f "$env_file" ]; then
    for var in AWS_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN; do
      line="$(grep -E "^${var}=" "$env_file" 2>/dev/null | tail -1)"
      [ -n "$line" ] && export "${line?}"
    done
  fi
  aws sts get-caller-identity >/dev/null 2>&1 && AWS_OK=1
  return 0
}

# Map an EKS control-plane status to our Status column vocabulary.
_eks_status_word() {   # args: <ACTIVE|CREATING|…>
  case "$1" in
    ACTIVE)   printf 'running' ;;
    CREATING) printf 'creating' ;;
    UPDATING) printf 'updating' ;;
    DELETING) printf 'deleting' ;;
    FAILED)   printf 'failed' ;;
    *)        # unknown future value — lowercase via tr (bash 3.2 safe)
              printf '%s' "$1" | tr 'A-Z' 'a-z' ;;
  esac
}

# Probe one EKS cluster via AWS (not kubectl). Echoes running|gone|creating|…|—
# "—" = could not determine (auth/network/aws error). Requires AWS_OK=1.
_eks_status() {   # args: <context>
  [ "$AWS_OK" = 1 ] || { printf '—'; return 0; }
  local region name out err rc
  region="$(_eks_region "$1")"
  name="${1##*/}"
  if [ -z "$region" ] || [ -z "$name" ]; then printf '—'; return 0; fi
  err="$(mktemp "${TMPDIR:-/tmp}/solomog-eks.XXXXXX")"
  out="$(aws eks describe-cluster --name "$name" --region "$region" \
          --query 'cluster.status' --output text 2>"$err")" && rc=0 || rc=$?
  if [ "$rc" = 0 ] && [ -n "$out" ] && [ "$out" != "None" ]; then
    rm -f "$err"
    _eks_status_word "$out"
    return 0
  fi
  if grep -qiE 'ResourceNotFoundException|NoClusterFound|Cluster not found' "$err" 2>/dev/null; then
    rm -f "$err"
    printf 'gone'
    return 0
  fi
  rm -f "$err"
  printf '—'
}

# Status for list/show. Vind: running|gone|?. EKS: AWS probe or —. Other external: —.
_status_for() {   # args: <cluster> <type> <context>
  case "$2" in
    vind)
      if [ "$VCLUSTER_OK" != 1 ]; then printf '?'; return; fi
      if _vcluster_running "$1"; then printf 'running'; else printf 'gone'; fi
      ;;
    eks)
      _eks_status "$3"
      ;;
    *) printf '—' ;;
  esac
}

# Age from cached `vcluster list` for a name (best-effort), or empty.
_vcluster_age() {
  [ "$VCLUSTER_OK" = 1 ] || return 0
  printf '%s\n' "$VCLUSTER_RAW" | awk -v n="$1" 'NR>1 && $1==n {
    # NAME | STATUS | CONNECTED | AGE  — age is last field
    print $NF; exit
  }'
}

_in_clusters_file() {
  [ -f "$CLUSTERS_FILE" ] && grep -qxF "$1" "$CLUSTERS_FILE"
}

_hosts_for() {   # args: <cluster> → matching /etc/hosts lines
  local c="$1"
  [ -f /etc/hosts ] || return 0
  # Hostname form is *.<cluster>.test (expose / route-host).
  grep -E "[[:space:]][^[:space:]]*\\.${c}\\.test([[:space:]]|\$)" /etc/hosts 2>/dev/null || true
}

# ─── modes ───────────────────────────────────────────────────────────────────

case "$MODE" in
  names)
    _all_names
    ;;

  list)
    _load_vclusters
    _load_aws
    names="$(_all_names)"
    if [ -z "$names" ]; then
      printf '%sNo clusters tracked.%s\n' "$B" "$R"
      printf '  Create one:  %ssolomog agentgateway CLUSTER=<name>%s\n' "$D" "$R"
      printf '           or  %ssolomog eks:create CLUSTER=<name>%s\n' "$D" "$R"
      exit 0
    fi

    current="$(_current_context)"
    if [ "$VCLUSTER_OK" != 1 ]; then
      printf '%s(vcluster list unavailable — vind status shown as ?)%s\n\n' "$D" "$R"
    fi

    # Build TSV rows: mark\tname\ttype\tregion\tcontext\tstatus
    # mark = * when this row's context is the current kubectl context.
    rows=""
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      ctx="$(_ctx_for "$name")"
      typ="$(_type_for "$name" "$ctx")"
      region="$(_eks_region "$ctx")"
      status="$(_status_for "$name" "$typ" "$ctx")"
      mark=" "
      [ -n "$current" ] && [ "$ctx" = "$current" ] && mark="*"
      rows="${rows}${mark}"$'\t'"${name}"$'\t'"${typ}"$'\t'"${region}"$'\t'"${ctx}"$'\t'"${status}"$'\n'
    done <<EOF
$names
EOF

    # Current row: bold+green with leading *. Status stays plain so column widths stay stable.
    printf '%s' "$rows" | awk -F'\t' -v g="$G$B" -v r="$R" '
      BEGIN {
        h_name="Name"; h_type="Type"; h_region="Region"
        h_ctx="Context"; h_status="Status"
        w_name=length(h_name); w_type=length(h_type); w_region=length(h_region)
        w_ctx=length(h_ctx); w_status=length(h_status)
      }
      NF >= 6 {
        i = ++n
        mark[i]=$1; name[i]=$2; type[i]=$3; region[i]=$4; ctx[i]=$5; status[i]=$6
        if (length($2) > w_name) w_name = length($2)
        if (length($3) > w_type) w_type = length($3)
        if (length($4) > w_region) w_region = length($4)
        if (length($5) > w_ctx) w_ctx = length($5)
        if (length($6) > w_status) w_status = length($6)
      }
      END {
        printf "  %-*s  %-*s  %-*s  %-*s  %-*s\n", \
          w_name, h_name, w_type, h_type, w_region, h_region, w_ctx, h_ctx, w_status, h_status
        for (i = 1; i <= n; i++) {
          if (mark[i] == "*") {
            printf "%s* %-*s  %-*s  %-*s  %-*s  %-*s%s\n", \
              g, w_name, name[i], w_type, type[i], w_region, region[i], \
              w_ctx, ctx[i], w_status, status[i], r
          } else {
            printf "  %-*s  %-*s  %-*s  %-*s  %-*s\n", \
              w_name, name[i], w_type, type[i], w_region, region[i], \
              w_ctx, ctx[i], w_status, status[i]
          }
        }
      }'
    ;;

  show)
    NAME="${2:-}"
    if [ -z "$NAME" ]; then
      echo "Error: cluster:show needs CLUSTER=<name>." >&2
      echo "  → solomog cluster:show CLUSTER=<name>   (see: solomog cluster:list)" >&2
      exit 1
    fi

    known=0
    _in_clusters_file "$NAME" && known=1
    [ -n "$(_registry_lookup "$NAME")" ] && known=1
    if [ "$known" = 0 ]; then
      printf '%s%s%s\n' "$B" "$NAME" "$R"
      printf '  %s(not in .solomog/clusters or .solomog/contexts)%s\n' "$Y" "$R"
      printf '\n  %sTip:%s solomog cluster:list\n' "$D" "$R"
      exit 1
    fi

    _load_vclusters
    _load_aws
    ctx="$(_ctx_for "$NAME")"
    typ="$(_type_for "$NAME" "$ctx")"
    region="$(_eks_region "$ctx")"
    status="$(_status_for "$NAME" "$typ" "$ctx")"
    current="$(_current_context)"
    is_current=0
    [ -n "$current" ] && [ "$ctx" = "$current" ] && is_current=1

    if [ "$is_current" = 1 ]; then
      printf '%s* %s%s\n' "$G$B" "$NAME" "$R"
    else
      printf '%s%s%s\n' "$B" "$NAME" "$R"
    fi

    printf '  %-12s %s\n' "type:" "$typ"
    printf '  %-12s %s\n' "context:" "$ctx"
    [ -n "$region" ] && printf '  %-12s %s\n' "region:" "$region"
    printf '  %-12s %s\n' "status:" "$status"
    if [ "$typ" = "vind" ] && [ "$VCLUSTER_OK" = 1 ] && _vcluster_running "$NAME"; then
      age="$(_vcluster_age "$NAME")"
      [ -n "$age" ] && printf '  %-12s %s\n' "age:" "$age"
    fi
    printf '  %-12s %s\n' "current:" "$([ "$is_current" = 1 ] && echo yes || echo no)"

    printf '  %-12s ' "tracked:"
    bits=""
    _in_clusters_file "$NAME" && bits="${bits}vind (.solomog/clusters), "
    [ -n "$(_registry_lookup "$NAME")" ] && bits="${bits}external (.solomog/contexts), "
    bits="${bits%, }"
    if [ -n "$bits" ]; then printf '%s\n' "$bits"; else printf '%snone%s\n' "$D" "$R"; fi

    if [ -d "$REPO_DIR/certs/$NAME" ]; then
      printf '  %-12s %s\n' "certs:" "certs/$NAME/"
    else
      printf '  %-12s %s\n' "certs:" "${D}none${R}"
    fi

    hosts="$(_hosts_for "$NAME")"
    if [ -n "$hosts" ]; then
      printf '  %-12s\n' "hosts:"
      printf '%s\n' "$hosts" | while IFS= read -r line; do
        printf '    %s%s%s\n' "$D" "$line" "$R"
      done
    else
      printf '  %-12s %s\n' "hosts:" "${D}none${R}"
    fi

    if [ -n "${CONTEXT:-}" ]; then
      printf '\n  %snote:%s CONTEXT=%s is set in the environment (would override for tasks).\n' \
        "$Y" "$R" "$CONTEXT"
    fi
    if [ "$typ" = "vind" ] && [ "$VCLUSTER_OK" != 1 ]; then
      printf '\n  %snote:%s vcluster list unavailable — status is unknown.\n' "$Y" "$R"
    fi
    ;;

  *)
    echo "Usage: clusters.sh {list|show <name>|names}" >&2
    exit 1
    ;;
esac
