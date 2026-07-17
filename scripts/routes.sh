#!/usr/bin/env bash
set -euo pipefail
#
# solomog routes — a brief, read-only view of the routing config on a cluster's
# agentgateway(s): Gateway → listeners → HTTPRoutes (host/path → backend, attached
# policies, and whether each is actually ACTIVE).
#
# Built entirely from kubectl + jq — deliberately NOT from the proxy admin API
# (:15000/config_dump) or agctl. config_dump only shows *accepted* config, so a
# rejected route just vanishes from it; the CR .status conditions (Accepted /
# ResolvedRefs / Programmed) are the only source that surfaces routes that AREN'T
# active. Scope is agentgateway for now (auto-detected); the Gateway-API layer is
# product-agnostic, so a kgateway renderer can drop in later.
#
# Usage:
#   routes.sh <cluster> [wide]
#     wide   also show per-rule matchers/filters and the failure reason for any
#            non-active route/gateway.
#
# Env: NO_COLOR disables color (also auto-off when stdout isn't a TTY).

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/gateway.sh
. "$REPO_DIR/scripts/lib/gateway.sh"
# shellcheck source=scripts/lib/target.sh
. "$REPO_DIR/scripts/lib/target.sh"

CLUSTER="${1:?Usage: routes.sh <cluster> [wide]}"
WIDE="${2:-}"
# Resolve the context from CLUSTER (registry/vind) or the CONTEXT override. See lib/target.sh.
CTX="$(solomog_context "$CLUSTER")"
# External target: CLUSTER is only a display label — derive from the context.
solomog_is_external "$CLUSTER" && CLUSTER="${CTX##*/}"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  G=$'\033[32m'; RED=$'\033[31m'; B=$'\033[1m'; D=$'\033[2m'; C=$'\033[36m'; R=$'\033[0m'
else
  G=''; RED=''; B=''; D=''; C=''; R=''
fi

# ── Preflight: the context must exist and answer. ────────────────────────────
if ! kubectl --context "$CTX" get gatewayclass >/dev/null 2>&1; then
  echo "Error: can't reach context '$CTX' (is cluster '$CLUSTER' up?)." >&2
  echo "       contexts: $(kubectl config get-contexts -o name 2>/dev/null | tr '\n' ' ')" >&2
  exit 1
fi

# ── Gather CRs once (tolerate CRDs absent in the other edition). ─────────────
# Strip raw C0 control bytes: live controllers occasionally write a status field
# with an unescaped newline, which is invalid JSON and makes jq bail (intermittently).
# Valid JSON escapes control chars (`\n` = two chars) and treats whitespace between
# tokens as optional, so removing raw 0x00–0x1F bytes is lossless.
_items() {
  local out
  out="$(kubectl --context "$CTX" get "$1" -A -o json 2>/dev/null | LC_ALL=C tr -d '\000-\037')"
  case "$out" in '') echo '{"items":[]}' ;; *) printf '%s' "$out" ;; esac
}

GW_JSON="$(_items gateways.gateway.networking.k8s.io)"
RT_JSON="$(_items httproutes.gateway.networking.k8s.io)"
# Policies + backends span an enterprise CRD and an OSS one; merge both editions'.
POL_ITEMS="$(jq -s '[.[].items[]?]' \
  <(_items enterpriseagentgatewaypolicies.enterpriseagentgateway.solo.io) \
  <(_items agentgatewaypolicies.agentgateway.dev))"
BE_ITEMS="$(jq -s '[.[].items[]?]' \
  <(_items enterpriseagentgatewaybackends.enterpriseagentgateway.solo.io) \
  <(_items agentgatewaybackends.agentgateway.dev))"

# All backend names referenced by any route (via an HTTPRoute backendRef)…
ROUTE_BACKENDS="$(echo "$RT_JSON" | jq -r '[.items[].spec.rules[]?.backendRefs[]?.name] | unique | .[]' 2>/dev/null || true)"
# …and all referenced from inside a *policy* spec (any backendRef.name at any depth —
# e.g. JWT jwks.remote.backendRef, token-exchange STS). Path-based so it's robust to
# odd nested values. A backend in neither set is genuinely unused.
POL_BACKEND_REFS="$(echo "$POL_ITEMS" | jq -r '
  [ .[] | paths(scalars) as $p
    | select($p[-1]=="name" and ($p | index("backendRef"))) | getpath($p) ]
  | unique | .[]' 2>/dev/null || true)"

# ── Header. ──────────────────────────────────────────────────────────────────
# The agentgateway Gateways (by class). Nothing to show if there are none.
GW_ROWS="$(echo "$GW_JSON" | jq -r '
  .items[] | select(.spec.gatewayClassName | test("agentgateway"))
  | [.metadata.namespace, .metadata.name, .spec.gatewayClassName] | @tsv')"

if [ -z "$GW_ROWS" ]; then
  printf '%sCluster %s%s%s\n' "$B" "$C" "$CLUSTER" "$R"
  if [ "$(solomog_detect_gateway "$CTX")" = kgw ]; then
    printf '%sNo agentgateway Gateways here — this looks like a kgateway cluster.%s\n' "$D" "$R"
  else
    printf '%sNo agentgateway Gateways found.%s Install one: solomog agentgateway CLUSTER=%s\n' "$D" "$R" "$CLUSTER"
  fi
  exit 0
fi

# Edition inferred from the agentgateway class itself (enterprise-agentgateway → enterprise).
EDITION="community"; case "$GW_ROWS" in *enterprise-agentgateway*) EDITION="enterprise" ;; esac
printf '%sCluster %s%s%s  ·  agentgateway (%s)\n' "$B" "$C" "$CLUSTER" "$R" "$EDITION"

# ── Per gateway. ───────────────────────────────────────────────────────────
_cond() {  # _cond <json> <type> → status string (True/False/"")
  echo "$1" | jq -r --arg t "$2" '[.status.conditions[]? | select(.type==$t) | .status] | first // ""'
}

echo "$GW_ROWS" | while IFS=$'\t' read -r GNS GNAME GCLASS; do
  GJSON="$(echo "$GW_JSON" | jq -c --arg ns "$GNS" --arg n "$GNAME" \
    '.items[] | select(.metadata.namespace==$ns and .metadata.name==$n)')"

  PROG="$(_cond "$GJSON" Programmed)"
  ADDR="$(echo "$GJSON" | jq -r '.status.addresses[0].value // "-"')"
  LISTENERS="$(echo "$GJSON" | jq -r '
    [.spec.listeners[] | "\(.protocol|ascii_downcase) :\(.port)"] | join(" · ")')"
  LHOST="$(echo "$GJSON" | jq -r '[.spec.listeners[].hostname // "*"] | unique | join(",")')"

  if [ "$PROG" = True ]; then PTAG="${G}✓ Programmed${R}"; else PTAG="${RED}✗ Programmed${PROG:+ ($PROG)}${R}"; fi
  printf '\n%sGateway %s%s   %s%s%s   %s   %s%s%s\n' \
    "$B" "$GNAME" "$R" "$D" "$GNS" "$R" "$PTAG" "$D" "$ADDR" "$R"
  printf '  %slisteners%s  %s   %s(host %s)%s\n' "$D" "$R" "$LISTENERS" "$D" "$LHOST" "$R"

  # Gateway-scoped policies.
  GPOLS="$(echo "$POL_ITEMS" | jq -r --arg gw "$GNAME" '
    [ .[] | select(.spec.targetRefs[]? | .kind=="Gateway" and .name==$gw) | .metadata.name ]
    | unique | join(", ")')"
  [ -n "$GPOLS" ] && printf '  %sgateway policies%s  %s\n' "$D" "$R" "$GPOLS"

  # Routes attached to this gateway → TSV: name, host/path, backends, policies, acc, res
  RROWS="$(echo "$RT_JSON" | jq -r \
    --arg gw "$GNAME" --argjson pol "$POL_ITEMS" '
    .items[]
    | select([.spec.parentRefs[]?.name] | index($gw))
    | .metadata.name as $rn
    | ([.spec.hostnames[]?] | if length==0 then "*" else join(",") end) as $hosts
    | ([.spec.rules[]?.matches[]?.path.value] | unique | map(select(. != null)) | join(" ")) as $paths
    | (if $paths=="" then $hosts else $hosts+" "+$paths end) as $hp
    | ([.spec.rules[]?.backendRefs[]?.name] | unique | join(",")) as $bes
    | ([$pol[] | select(.spec.targetRefs[]? | .kind=="HTTPRoute" and .name==$rn) | .metadata.name] | unique | join(",")) as $pols
    | ([.status.parents[]?.conditions[]? | select(.type=="Accepted")    | .status]) as $acc
    | ([.status.parents[]?.conditions[]? | select(.type=="ResolvedRefs")| .status]) as $res
    | (if ($acc|length)>0 and (all($acc[]; .=="True")) then "ok" else "bad" end) as $accf
    | (if ($res|length)>0 and (all($res[]; .=="True")) then "ok" else "bad" end) as $resf
    | [$rn, $hp, ($bes|if .=="" then "-" else . end), ($pols|if .=="" then "-" else . end), $accf, $resf] | @tsv')"

  if [ -z "$RROWS" ]; then
    printf '  %s(no HTTPRoutes attached)%s\n' "$D" "$R"
  else
    echo
    printf '%s\n' "$RROWS" | awk -F'\t' \
      -v g="$G" -v red="$RED" -v b="$B" -v d="$D" -v r="$R" '
      function mark(f) { return f=="ok" ? g"✓"r : red"✗"r }
      {
        rn[NR]=$1; hp[NR]=$2; be[NR]=$3; po[NR]=$4; acc[NR]=$5; res[NR]=$6
        if (length($1)>w1) w1=length($1)
        if (length($2)>w2) w2=length($2)
        if (length($3)>w3) w3=length($3)
        if (length($4)>w4) w4=length($4)
      }
      END {
        printf "  %s%-*s  %-*s  %-*s  %-*s  %s%s\n", b, w1,"ROUTE", w2,"HOST / PATH", w3,"BACKEND", w4,"POLICIES", "ACC RES", r
        for (i=1;i<=NR;i++)
          printf "  %s%-*s%s  %-*s  %-*s  %-*s   %s   %s\n", \
            g, w1, rn[i], r, w2, hp[i], w3, be[i], w4, po[i], mark(acc[i]), mark(res[i])
      }'
  fi

  # WIDE: per-rule matcher/filter detail + the reason any route/gateway is not active.
  if [ -n "$WIDE" ]; then
    echo "$RT_JSON" | jq -r --arg gw "$GNAME" --arg d "$D" --arg r "$R" '
      .items[] | select([.spec.parentRefs[]?.name] | index($gw))
      | "  \($d)· \(.metadata.name)\($r)",
        ( .spec.rules[]? |
          "      match \([.matches[]? | "\(.path.type // "")=\(.path.value // "/")\(if .method then " "+.method else "" end)\(if (.headers|length)>0 then " hdr:"+([.headers[].name]|join(",")) else "" end)"] | join("; "))"
          + (if (.filters|length)>0 then "   filters \([.filters[].type]|join(","))" else "" end) )' 2>/dev/null || true
    # Failure reasons (only prints lines where a condition is False).
    echo "$RT_JSON" | jq -r --arg gw "$GNAME" --arg red "$RED" --arg r "$R" '
      .items[] | select([.spec.parentRefs[]?.name] | index($gw))
      | .metadata.name as $rn
      | .status.parents[]?.conditions[]? | select(.status=="False")
      | "  \($red)✗ \($rn): \(.type) — \(.reason): \(.message)\($r)"' 2>/dev/null || true
  fi
done

# ── Backends not bound to a route: policy-referenced (required) vs truly unused. ─
# A backend CR with no HTTPRoute backendRef isn't necessarily orphaned — JWKS
# sources and the token-exchange STS are referenced from a *policy* spec instead.
# Only a backend referenced by NEITHER a route nor a policy is possibly dead config.
if [ -n "$BE_ITEMS" ] && [ "$BE_ITEMS" != "[]" ]; then
  # $1 = "in"  → backends referenced by a policy (not a route)
  #      "out" → backends referenced by neither (possibly dead config)
  _classify() {
    echo "$BE_ITEMS" | jq -r --arg routed "$ROUTE_BACKENDS" --arg poled "$POL_BACKEND_REFS" --arg mode "$1" '
      ($routed | split("\n") | map(select(length>0))) as $r
      | ($poled  | split("\n") | map(select(length>0))) as $p
      | [ .[] | .metadata.name as $n
          | select($n | IN($r[]) | not)
          | select(if $mode=="in" then ($n | IN($p[])) else ($n | IN($p[]) | not) end)
          | $n ] | unique | join(", ")'
  }
  POLICY_BE="$(_classify in)"
  UNUSED="$(_classify out)"
  if [ -n "$POLICY_BE" ]; then
    printf '\n%spolicy backends%s  %s   %s(JWKS / token-exchange sources referenced by a policy, not a route — required)%s\n' \
      "$D" "$R" "$POLICY_BE" "$D" "$R"
  fi
  if [ -n "$UNUSED" ]; then
    printf '\n%s⚠ unused backends%s  %s   %s(referenced by no route or policy — possibly dead config)%s\n' \
      "$RED" "$R" "$UNUSED" "$D" "$R"
  fi
fi

exit 0
