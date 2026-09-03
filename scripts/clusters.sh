#!/usr/bin/env bash
set -euo pipefail
#
# Lists / inspects solomog-tracked clusters (vind + registered externals).
# Local registries + soft live checks:
#   • vind:    `vcluster list` (Docker) → running|gone|?
#   • eks:     `aws eks describe-cluster` when AWS creds work → running|gone|…;
#              expired/broken/missing creds stay "—" (undetermined), never fail the list.
#   • vsphere: kubectl /readyz probe with a short timeout → running|unreachable
#              (no vCenter API dependency; "unreachable" = powered off OR network down).
# Marks the current kubectl target: "*" exact context match, "~" same cluster reached
# through a different context (see _load_kube_servers).
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

# For solomog_aws_env_load / solomog_aws_ok only — context resolution here is
# deliberately local (_ctx_for ignores CONTEXT so a one-off override can't rewrite
# every row of the table).
. "$REPO_DIR/scripts/lib/target.sh"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  G=$'\033[32m'; B=$'\033[1m'; D=$'\033[2m'; Y=$'\033[33m'; R=$'\033[0m'
  # Dark purple, the same 256-colour slot as ui.sh's _SM_DIM, so the whole tool shares one
  # palette. Marks the `standalone` TYPE — the row is not a cluster, and the type column is
  # where that belongs. Status stays uncoloured for every type (see _standalone_status).
  P=$'\033[38;5;97m'
else
  G=''; B=''; D=''; Y=''; R=''; P=''
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
  # No kube context exists for a standalone instance — there is no cluster. Name the docker
  # container instead, which is the thing you actually address, and mirrors how the vind
  # rows name their context.
  if solomog_is_standalone "$1"; then printf 'docker/solomog-standalone-%s' "$1"; return; fi
  printf 'vcluster-docker_%s' "$1"
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

# Echo registered standalone instance names (one per line). Not clusters — `solomog
# standalone` runs agentgateway as a bare Docker container — but they ARE solomog-managed
# targets, so they belong in this table rather than in a separate world the user has to
# remember to check.
_tracked_standalone() {
  solomog_standalone_names
}

# Union of all known names, sorted.
_all_names() {
  { _tracked_vind; _tracked_external; _tracked_standalone; } | awk 'NF' | LC_ALL=C sort -u
}

# Current kubectl context, or empty if unavailable.
_current_context() {
  command -v kubectl >/dev/null 2>&1 || return 0
  kubectl config current-context 2>/dev/null || true
}

# Populate KUBE_SERVERS with "<context>\t<API server URL>" lines from the local kubeconfig.
# ONE cluster can wear SEVERAL context names and we don't control that: `eksctl create cluster`
# writes <user>@<cluster>.<region>.eksctl.io, then `aws eks update-kubeconfig` (eks-create.sh)
# writes the arn:aws:eks:… context we register — plus whatever `kubectx` renames add. So an
# exact name compare says "not current" while kubectl is in fact pointed at that very cluster.
# The server endpoint is the cluster's real identity; a context name is a user-editable alias
# over it. Local file read, no network. KUBE_SERVERS_OK=0 → fall back to the name compare.
KUBE_SERVERS=""
KUBE_SERVERS_OK=0
_load_kube_servers() {
  KUBE_SERVERS=""
  KUBE_SERVERS_OK=0
  command -v kubectl >/dev/null 2>&1 || return 0
  local out
  # jsonpath can't join contexts→clusters, so emit both tables tagged C/S and join in awk.
  out="$(kubectl config view -o jsonpath='{range .contexts[*]}C{"\t"}{.name}{"\t"}{.context.cluster}{"\n"}{end}{range .clusters[*]}S{"\t"}{.name}{"\t"}{.cluster.server}{"\n"}{end}' 2>/dev/null)" || return 0
  [ -n "$out" ] || return 0
  KUBE_SERVERS="$(printf '%s\n' "$out" | awk -F'\t' '
    $1=="S" && $2 != "" { srv[$2] = $3; next }
    $1=="C" && $2 != "" { ctx[++n] = $2; cl[n] = $3 }
    END { for (i = 1; i <= n; i++) if (srv[cl[i]] != "") printf "%s\t%s\n", ctx[i], srv[cl[i]] }')"
  KUBE_SERVERS_OK=1
}

_server_for_ctx() {   # args: <context> → API server URL, or empty
  [ "$KUBE_SERVERS_OK" = 1 ] || return 0
  printf '%s\n' "$KUBE_SERVERS" | awk -F'\t' -v c="$1" '$1==c{print $2; exit}'
}

# Mark for a row's context against the current one: "*" same context, "~" same cluster via a
# different context, " " neither. args: <row-context> <current-context> <current-server>
_mark_for() {
  local row_server
  if [ -z "$2" ]; then printf ' '; return; fi
  if [ "$1" = "$2" ]; then printf '*'; return; fi
  if [ -n "$3" ]; then
    row_server="$(_server_for_ctx "$1")"
    if [ -n "$row_server" ] && [ "$row_server" = "$3" ]; then printf '~'; return; fi
  fi
  printf ' '
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

# Soft AWS identity for EKS status. Shares the .env-reload + identity probe with
# solomog_aws_preflight, but NEVER exits — bad/expired creds just leave AWS_OK=0
# so EKS rows keep status "—".
AWS_OK=0
_load_aws() {
  AWS_OK=0
  command -v aws >/dev/null 2>&1 || return 0
  solomog_aws_env_load
  solomog_aws_ok && AWS_OK=1
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

# Probe a vsphere cluster's API server directly (short timeout, never fails the
# list). Can't tell powered-off from network-down without the vCenter API, so both
# read "unreachable" — cheap, dependency-free, and honest.
_vsphere_status() {   # args: <context>
  command -v kubectl >/dev/null 2>&1 || { printf '—'; return 0; }
  if kubectl --context "$1" get --raw /readyz --request-timeout=3s >/dev/null 2>&1; then
    printf 'running'
  else
    printf 'unreachable'
  fi
}

# Status for list/show. Vind: running|gone|?. EKS: AWS probe or —. vsphere: kubectl
# probe. Other external: —.
# Live state of a standalone instance's container: running | stopped | gone.
_standalone_status() {   # args: <instance>
  local out
  command -v docker >/dev/null 2>&1 || { printf '?'; return; }
  out="$(docker ps -a --filter "name=^solomog-standalone-$1$" --format '{{.State}}' 2>/dev/null | head -1)"
  # Plain text, no colour: every other _*_status returns plain text, and an escape sequence
  # here would also inflate awk's Status column width, which is sized on length($6).
  case "$out" in
    "") printf 'gone' ;;
    *)  printf '%s' "$out" ;;
  esac
}

_status_for() {   # args: <cluster> <type> <context>
  case "$2" in
    vind)
      if [ "$VCLUSTER_OK" != 1 ]; then printf '?'; return; fi
      if _vcluster_running "$1"; then printf 'running'; else printf 'gone'; fi
      ;;
    eks)
      _eks_status "$3"
      ;;
    vsphere)
      _vsphere_status "$3"
      ;;
    standalone)
      _standalone_status "$1"
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
    _load_kube_servers
    current_server="$(_server_for_ctx "$current")"
    if [ "$VCLUSTER_OK" != 1 ]; then
      printf '%s(vcluster list unavailable — vind status shown as ?)%s\n\n' "$D" "$R"
    fi

    # Build TSV rows: mark\tname\ttype\tregion\tcontext\tstatus
    # mark = * this row's context IS the current one, ~ same cluster via another context.
    rows=""
    aliased=""
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      ctx="$(_ctx_for "$name")"
      typ="$(solomog_cluster_type "$name")"
      region="$(_eks_region "$ctx")"
      status="$(_status_for "$name" "$typ" "$ctx")"
      mark="$(_mark_for "$ctx" "$current" "$current_server")"
      [ "$mark" = "~" ] && aliased=1
      rows="${rows}${mark}"$'\t'"${name}"$'\t'"${typ}"$'\t'"${region}"$'\t'"${ctx}"$'\t'"${status}"$'\n'
    done <<EOF
$names
EOF

    # Current row: bold+green with leading *. A "~" row (same cluster, different context) gets
    # plain green — related but weaker. Status stays plain so column widths stay stable.
    printf '%s' "$rows" | awk -F'\t' -v g="$G$B" -v a="$G" -v r="$R" -v p="$P" '
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
      # Pad to width FIRST, then wrap in colour. printf "%-*s" counts the escape bytes as
      # width, so colouring before padding would shove every later column out of line.
      function typecell(t, w,    padded) {
        padded = sprintf("%-*s", w, t)
        if (p != "" && t == "standalone") return p padded r
        return padded
      }
      END {
        printf "  %-*s  %-*s  %-*s  %-*s  %-*s\n", \
          w_name, h_name, w_type, h_type, w_region, h_region, w_ctx, h_ctx, w_status, h_status
        for (i = 1; i <= n; i++) {
          if (mark[i] == "*" || mark[i] == "~") {
            # A marked row is already coloured end to end, so leave its type alone rather
            # than reset mid-row. Standalone rows are never marked anyway: their "context"
            # is a container name, which can never equal the current kube context.
            printf "%s%s %-*s  %-*s  %-*s  %-*s  %-*s%s\n", \
              (mark[i] == "*" ? g : a), mark[i], \
              w_name, name[i], w_type, type[i], w_region, region[i], \
              w_ctx, ctx[i], w_status, status[i], r
          } else {
            printf "  %-*s  %s  %-*s  %-*s  %-*s\n", \
              w_name, name[i], typecell(type[i], w_type), w_region, region[i], \
              w_ctx, ctx[i], w_status, status[i]
          }
        }
      }'
    # Only explain "~" when one is on screen — the common single-mark table stays uncluttered.
    if [ -n "$aliased" ]; then
      printf '\n  %s~ same cluster as your current context (%s), reached by a different name%s\n' \
        "$D" "$current" "$R"
    fi
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
    solomog_is_standalone "$NAME" && known=1
    if [ "$known" = 0 ]; then
      printf '%s%s%s\n' "$B" "$NAME" "$R"
      printf '  %s(not in .solomog/clusters, .solomog/contexts or .solomog/standalone-instances)%s\n' "$Y" "$R"
      printf '\n  %sTip:%s solomog cluster:list\n' "$D" "$R"
      exit 1
    fi

    _load_vclusters
    _load_aws
    ctx="$(_ctx_for "$NAME")"
    typ="$(solomog_cluster_type "$NAME")"
    region="$(_eks_region "$ctx")"
    status="$(_status_for "$NAME" "$typ" "$ctx")"
    current="$(_current_context)"
    _load_kube_servers
    mark="$(_mark_for "$ctx" "$current" "$(_server_for_ctx "$current")")"

    case "$mark" in
      '*') printf '%s* %s%s\n' "$G$B" "$NAME" "$R" ;;
      '~') printf '%s~ %s%s\n' "$G" "$NAME" "$R" ;;
      *)   printf '%s%s%s\n' "$B" "$NAME" "$R" ;;
    esac

    if [ "$typ" = "standalone" ]; then
      printf '  %-12s %s%s%s\n' "type:" "$P" "$typ" "$R"
    else
      printf '  %-12s %s\n' "type:" "$typ"
    fi
    printf '  %-12s %s\n' "context:" "$ctx"
    [ -n "$region" ] && printf '  %-12s %s\n' "region:" "$region"
    printf '  %-12s %s\n' "status:" "$status"
    if [ "$typ" = "standalone" ]; then
      cname="solomog-standalone-$NAME"
      cfg="$(docker ps -a --filter "name=^${cname}$" \
        --format '{{.Label "solomog.standalone.config"}}' 2>/dev/null | head -1)"
      ui="$(docker ps -a --filter "name=^${cname}$" \
        --format '{{.Label "solomog.standalone.ui"}}' 2>/dev/null | head -1)"
      ports="$(docker ps -a --filter "name=^${cname}$" --format '{{.Ports}}' 2>/dev/null | head -1)"
      [ -n "$cfg" ] && printf '  %-12s %s\n' "config:" "standalone/$cfg/config.yaml"
      [ -d "$REPO_DIR/.solomog/standalone/$NAME" ] \
        && printf '  %-12s %s\n' "scratch:" ".solomog/standalone/$NAME/"
      [ -n "$ports" ] && printf '  %-12s %s\n' "ports:" "$ports"
      [ -n "$ui" ] && printf '  %-12s %s\n' "ui:" "$ui"
      printf '  %-12s %s\n' "tracked:" "standalone (.solomog/standalone-instances)"
      printf '\n  %sNot a cluster — agentgateway in a container. Manage with:%s\n' "$D" "$R"
      printf '  %ssolomog standalone:logs INSTANCE=%s%s\n' "$D" "$NAME" "$R"
      printf '  %ssolomog standalone:stop INSTANCE=%s%s\n' "$D" "$NAME" "$R"
    fi
    if [ "$typ" = "vind" ] && [ "$VCLUSTER_OK" = 1 ] && _vcluster_running "$NAME"; then
      age="$(_vcluster_age "$NAME")"
      [ -n "$age" ] && printf '  %-12s %s\n' "age:" "$age"
    fi
    if [ "$typ" = "vsphere" ]; then
      pool="$REPO_DIR/.solomog/vsphere/ippool"
      if [ -f "$pool" ]; then
        ips="$(awk -F'\t' -v c="$NAME" '$1==c{printf "%s%s(%s)", sep, $2, $3; sep="  "}' "$pool")"
        [ -n "$ips" ] && printf '  %-12s %s\n' "node IPs:" "$ips"
      fi
      if [ "$status" = "running" ]; then
        # || true: this is a separate round trip from the /readyz probe above — a
        # transient kubectl failure must degrade to "no nodes line", never fail the
        # list (same contract as _eks_status/_vsphere_status).
        nodes="$(kubectl --context "$ctx" get nodes --no-headers --request-timeout=3s 2>/dev/null \
                  | awk '{r += ($2=="Ready") ? 1 : 0; t++} END{if (t) printf "%d/%d Ready", r, t}' \
                  || true)"
        [ -n "$nodes" ] && printf '  %-12s %s\n' "nodes:" "$nodes"
      fi
    fi
    # Everything below is kube-context / mesh detail: whether kubectl points here, the
    # generated cert dir, the /etc/hosts entries expose writes. None of it can apply to a
    # container with no cluster, and printing "none" four times reads as something missing
    # rather than something inapplicable. So a standalone row stops here.
    if [ "$typ" = "standalone" ]; then
      exit 0
    fi

    # "~" is the honest answer for an EKS cluster: kubectl IS on this cluster, but through
    # eksctl's context, not the arn:… one solomog registered and every task resolves to.
    case "$mark" in
      '*') printf '  %-12s %s\n' "current:" "yes" ;;
      '~') printf '  %-12s %s\n' "current:" "same cluster, via context $current" ;;
      *)   printf '  %-12s %s\n' "current:" "no" ;;
    esac

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
