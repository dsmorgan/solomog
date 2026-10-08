#!/usr/bin/env bash
set -euo pipefail
#
# graph.sh — `solomog graph`. Snapshots a cluster's agentgateway, kagent and Agent Substrate
# configuration and renders it as an interactive, self-contained HTML graph you explore in a
# browser:
#   agentgateway: Gateway (data plane) + control-plane deployment + pods → HTTPRoutes →
#                 Backends → Policies, with Gateway-API edges (parentRef / backendRef / targetRef)
#   kagent:       controller → Agents → AgentTemplate / Harness (1.0) or declarative refs (0.10)
#                 → ModelConfigs / RemoteMCPServers; Harness → substrate WorkerPool → worker
#                 pods + SandboxConfig (model in lib/graph/kagent.jq)
# Either product may be absent. When both are present, one page holds both with a view switch
# (agentgateway | kagent | all), and cross-product edges show which kagent model/MCP traffic
# rides an agentgateway route and which routes front kagent. Click any node for its details
# and a copy-paste `kubectl` command.
#
# The relationship model is the same one `routes` computes (kubectl + jq); this just emits
# it as Cytoscape.js elements, inlines them + the vendored graph lib into ONE HTML file
# (self-contained → works offline, shareable, could drop into an `export`), then serves it
# on an ephemeral local port and opens a browser tab. Optionally enriches with each gateway
# pod's admin /config_dump (version + which CRs the proxy actually loaded).
#
# INPUT= reads CRs from a file or a directory instead of a cluster (stacked YAML, JSON, or
# a JSON/YAML List). Status in those files is ignored unless STATUS=exported. Refs to objects
# that are not in the snapshot become ghost nodes (same kind, dashed) — on a cluster too.
#
# Usage: graph.sh <cluster>
# Env:
#   INPUT         file or directory of CRs. Omit to graph a cluster. Not with CLUSTER/CONTEXT.
#   STATUS        exported — on an INPUT render, color nodes from status in the files.
#   VERSION       version label on an INPUT render (the subtitle). Ignored for a cluster.
#   OPEN          true|false (default true) — open the generated HTML in a browser
#   SERVE         true (default false) — serve on a local port (Enter to stop) instead of just
#                 opening the self-contained file. localhost gives native clipboard copy.
#   OUT           output HTML path (default .solomog/graph/<cluster>-<ts>.html)
#   PORT          serve port, SERVE=true only (default: an ephemeral free port)
#   DUMP          true|false (default true) — port-forward each gateway pod's admin :15000
#                 and fetch /config_dump (version + loaded enrichment). Soft-fails on error.
#                 Forced off for INPUT (there is no proxy).
#   DUMP_TIMEOUT  seconds to wait for port-forward/curl (default 15)

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_DIR/scripts/lib/gateway.sh"
# shellcheck source=lib/target.sh
source "$REPO_DIR/scripts/lib/target.sh"

CLUSTER="${1:-}"
# Capture before the cluster path resets VERSION from the proxy dump. File renders use it
# as a subtitle label; a cluster graph ignores it.
REQUESTED_VERSION="${VERSION:-}"
STATUS_FLAG="${STATUS:-}"
INPUT="${INPUT:-}"
FILE_MODE=false
HONOR_STATUS=true
if [ -n "$INPUT" ]; then
  if [ -n "$CLUSTER" ] || [ -n "${CONTEXT:-}" ]; then
    echo "Error: pass INPUT= or a cluster (CLUSTER/CONTEXT), not both." >&2
    exit 1
  fi
  FILE_MODE=true
  HONOR_STATUS=false
  [ "$STATUS_FLAG" = "exported" ] && HONOR_STATUS=true
  CLUSTER="$(basename "$INPUT")"
  case "$CLUSTER" in
    *.yaml|*.yml|*.json) CLUSTER="${CLUSTER%.*}" ;;
  esac
else
  solomog_require_cluster "$CLUSTER" graph
  # Resolve the context from CLUSTER (registry/vind) or the CONTEXT override. See lib/target.sh.
  CTX="$(solomog_context "$CLUSTER")"
  # CLUSTER is only a display label from here on (also names the output file); derive
  # one when only CONTEXT= was given (arn:...:cluster/NAME → NAME; vsphere_<n> → <n>).
  CLUSTER="$(solomog_display_name "$CLUSTER" "$CTX")"
fi
SERVE="${SERVE:-false}"
DUMP="${DUMP:-true}"
[ "$FILE_MODE" = true ] && DUMP=false
DUMP_TIMEOUT="${DUMP_TIMEOUT:-15}"
TS="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo graph)"
OUT="${OUT:-$REPO_DIR/.solomog/graph/${CLUSTER}-${TS}.html}"
CYTO="$REPO_DIR/scripts/lib/graph/cytoscape.min.js"

[ -f "$CYTO" ] || { echo "Error: vendored graph lib missing: $CYTO" >&2; exit 1; }
KAGENT_JQ="$REPO_DIR/scripts/lib/graph/kagent.jq"
GHOSTS_JQ="$REPO_DIR/scripts/lib/graph/ghosts.jq"
CLASSIFY_JQ="$REPO_DIR/scripts/lib/graph/classify.jq"
INGEST_RB="$REPO_DIR/scripts/lib/graph/ingest.rb"
[ -f "$KAGENT_JQ" ] || { echo "Error: graph model missing: $KAGENT_JQ" >&2; exit 1; }
[ -f "$GHOSTS_JQ" ] || { echo "Error: graph model missing: $GHOSTS_JQ" >&2; exit 1; }
[ -f "$CLASSIFY_JQ" ] || { echo "Error: graph model missing: $CLASSIFY_JQ" >&2; exit 1; }
[ -f "$INGEST_RB" ] || { echo "Error: graph model missing: $INGEST_RB" >&2; exit 1; }

# Sanitize raw C0 control bytes (live controllers sometimes write an unescaped newline into
# a status field → invalid JSON → jq bails). Lossless: valid JSON escapes control chars.
_items() {
  local out
  out="$(kubectl --context "$CTX" get "$1" -A -o json 2>/dev/null | LC_ALL=C tr -d '\000-\037')"
  case "$out" in '') echo '[]' ;; *) printf '%s' "$out" | jq '[.items[]?]' ;; esac
}
# Merge a CRD's items, tagging each with its full resource type (for kubectl hints).
_tagged() { _items "$1" | jq --arg t "$1" 'map(. + {_rtype:$t})'; }
# Large lists (pods, deployments, services) go to jq through --slurpfile <(...), never
# --argjson: on a real cluster they exceed ARG_MAX ("argument list too long").
_json() { printf '%s' "$1"; }

# ── File render (INPUT= a file or a directory). No kubectl. ─────────────────
_load_input() {
  local input="$1" list nfiles classified dups skipped defaulted draw_n
  if [ -d "$input" ]; then
    INGEST_ROOT="$(cd "$input" && pwd)"
    export INGEST_ROOT
    list="$(mktemp)"
    find "$INGEST_ROOT" \( -name '.*' -o -name node_modules \) -prune -o -type f \
      \( -name '*.yaml' -o -name '*.yml' -o -name '*.json' \) -print | LC_ALL=C sort > "$list"
    nfiles="$(grep -c . "$list" 2>/dev/null || true)"
    nfiles="${nfiles:-0}"
    if [ "$nfiles" -eq 0 ]; then
      rm -f "$list"
      echo "Error: no .yaml, .yml, or .json files in ${input}" >&2
      exit 1
    fi
    echo "==> Reading ${nfiles} file(s) from '${input}'"
    DOCS="$(ruby "$INGEST_RB" --files-from "$list")" || { rm -f "$list"; exit 1; }
    rm -f "$list"
  elif [ -f "$input" ]; then
    unset INGEST_ROOT
    echo "==> Reading '${input}'"
    DOCS="$(ruby "$INGEST_RB" "$input")" || exit 1
  else
    echo "Error: INPUT is not a file or directory: ${input}" >&2
    exit 1
  fi
  classified="$(jq -c -f "$CLASSIFY_JQ" <<EOF
$DOCS
EOF
)" || exit 1
  dups="$(printf '%s' "$classified" | jq -r '.duplicates[] | "  \(.kind) \(.ns)/\(.name)\n" + ([.sources[] | "    " + .] | join("\n"))')"
  if [ -n "$dups" ]; then
    echo "Error: duplicate objects in ${input} (same kind, namespace, and name):" >&2
    printf '%s\n' "$dups" >&2
    exit 1
  fi
  GW="$(printf '%s' "$classified" | jq -c '.gw')"
  RT="$(printf '%s' "$classified" | jq -c '.rt')"
  POL="$(printf '%s' "$classified" | jq -c '.pol')"
  BE="$(printf '%s' "$classified" | jq -c '.be')"
  PODS="$(printf '%s' "$classified" | jq -c '.pods')"
  DEPS="$(printf '%s' "$classified" | jq -c '.deps')"
  GC="$(printf '%s' "$classified" | jq -c '.gc')"
  SVCS="$(printf '%s' "$classified" | jq -c '.svcs')"
  KOBJS="$(printf '%s' "$classified" | jq -c '.kobjs')"
  defaulted="$(printf '%s' "$classified" | jq -r '.defaulted')"
  skipped="$(printf '%s' "$classified" | jq -r '.skipped[] | "    \(.kind) ×\(.count)"')"
  [ "$defaulted" != 0 ] && echo "    ${defaulted} object(s) had no namespace; treated as default"
  if [ -n "$skipped" ]; then
    echo "    skipped (not drawn):"
    printf '%s\n' "$skipped"
  fi
  other_gw="$(printf '%s' "$GW" | jq -r '[.[] | select((.spec.gatewayClassName // "") | test("agentgateway") | not) | .metadata.namespace + "/" + .metadata.name + " (" + (.spec.gatewayClassName // "no class") + ")"] | join(", ")')"
  [ -n "$other_gw" ] && echo "    skipped Gateway (not an agentgateway class): ${other_gw}"
  echo "    objects: $(printf '%s' "$classified" | jq -r '.objects')  routes=$(printf '%s' "$RT" | jq 'length') backends=$(printf '%s' "$BE" | jq 'length') policies=$(printf '%s' "$POL" | jq 'length')"
  if [ "$HONOR_STATUS" = true ]; then
    echo "    coloring nodes from status in the files (exported). That status was not re-evaluated." >&2
  else
    echo "    status is not evaluated. A connected graph is not an accepted config." >&2
  fi
  echo "    object YAML is embedded in the HTML. Review it before sharing." >&2
}

if [ "$FILE_MODE" = true ]; then
  _load_input "$INPUT"
  HAS_KAGENT=false
  HAS_SUBSTRATE=false
  printf '%s' "$KOBJS" | jq -e 'any(.[]; .kind=="Agent" or .kind=="SandboxAgent" or .kind=="AgentTemplate" or .kind=="Harness" or .kind=="AgentHarness" or .kind=="SandboxTemplate" or .kind=="ModelConfig" or .kind=="ModelProviderConfig" or .kind=="RemoteMCPServer" or .kind=="MCPServer" or .kind=="EnterpriseKagentRBACPolicy")' >/dev/null \
    && HAS_KAGENT=true
  printf '%s' "$KOBJS" | jq -e 'any(.[]; .kind=="WorkerPool" or .kind=="SandboxConfig")' >/dev/null \
    && HAS_SUBSTRATE=true
else
if ! _probe="$(kubectl --context "$CTX" get --raw /version 2>&1)"; then
  echo "Error: can't reach context '$CTX' (is cluster '$CLUSTER' up?)." >&2
  echo "  kubectl said:" >&2
  printf '%s\n' "$_probe" | sed 's/^/    /' >&2
  exit 1
fi

# Installed CRDs, fetched once: product detection, and kagent/substrate kinds are only listed
# when served (they span two API groups across kagent 0.10 → 1.0).
CRDS="$(kubectl --context "$CTX" get crd -o name 2>/dev/null | sed 's|^.*/||')"
_has_crd() { printf '%s\n' "$CRDS" | grep -qx "$1"; }

echo "==> Snapshotting agentgateway / kagent / substrate config on '${CLUSTER}'"
GW="$(_items gateways.gateway.networking.k8s.io)"
RT="$(_items httproutes.gateway.networking.k8s.io)"
POL="$(jq -s 'add' <(_tagged enterpriseagentgatewaypolicies.enterpriseagentgateway.solo.io) <(_tagged agentgatewaypolicies.agentgateway.dev))"
BE="$(jq -s 'add' <(_tagged enterpriseagentgatewaybackends.enterpriseagentgateway.solo.io) <(_tagged agentgatewaybackends.agentgateway.dev))"
# Only the pods the graph draws: gateway data-plane pods and substrate worker pods.
PODS="$(_items pods | jq '[.[] | select(.metadata.labels["gateway.networking.k8s.io/gateway-name"] or .metadata.labels["ate.dev/worker-pool"])]')"
DEPS="$(_items deployments.apps)"
GC="$(_items gatewayclasses.gateway.networking.k8s.io)"

# kagent (0.10 kagent.dev/v1alpha2; 1.0 api.kagent.dev/v1alpha3 — early 1.0 alphas served
# v1alpha3 under kagent.dev) + Agent Substrate (ate.dev). Fetch whichever are served.
KAGENT_RES="agents agenttemplates harnesses agentharnesses sandboxagents sandboxtemplates modelconfigs modelproviderconfigs remotemcpservers mcpservers"
KRES=""
for r in $KAGENT_RES; do
  for g in api.kagent.dev kagent.dev; do _has_crd "$r.$g" && KRES="$KRES $r.$g"; done
done
for r in enterprisekagentrbacpolicies.enterprisekagent.solo.io workerpools.ate.dev sandboxconfigs.ate.dev; do
  _has_crd "$r" && KRES="$KRES $r"
done
KOBJS='[]'
for r in $KRES; do KOBJS="$(jq -s 'add' <(_json "$KOBJS") <(_tagged "$r"))"; done
HAS_KAGENT=false; HAS_SUBSTRATE=false
{ _has_crd agents.api.kagent.dev || _has_crd agents.kagent.dev; } && HAS_KAGENT=true
_has_crd workerpools.ate.dev && HAS_SUBSTRATE=true

SVCS='[]'
if [ "$HAS_KAGENT" = true ] || [ "$HAS_SUBSTRATE" = true ]; then
  # Services map agentgateway backends onto the kagent / substrate Deployments they front.
  SVCS="$(_items services)"
fi
fi

GWNAMES="$(echo "$GW" | jq -r '[.[]|select((.spec.gatewayClassName // "")|test("agentgateway"))|.metadata.name]|join(",")')"
HAS_AGW=true; [ -z "$GWNAMES" ] && HAS_AGW=false
# A file render with routes, backends, or policies is still a picture when no Gateway
# was included. On a cluster, those objects without an agentgateway Gateway belong to
# some other gateway and are left out.
if [ "$FILE_MODE" = true ] && [ "$HAS_AGW" = false ]; then
  draw_n="$(jq -s '.[0]+.[1]+.[2] | length' <(_json "$RT") <(_json "$POL") <(_json "$BE"))"
  [ "$draw_n" != 0 ] && HAS_AGW=true
fi
if [ "$HAS_AGW" = false ] && [ "$HAS_KAGENT" = false ] && [ "$HAS_SUBSTRATE" = false ]; then
  if [ "$FILE_MODE" = true ]; then
    echo "Error: nothing to graph in '${INPUT}'." >&2
    exit 1
  fi
  echo "No agentgateway Gateways, kagent, or Agent Substrate on '${CLUSTER}' — nothing to graph." >&2
  exit 0
fi
# No agentgateway Gateway on a cluster → leave its half empty, so HTTPRoutes / backends
# that belong to some other gateway (kgateway, Istio) don't surface as unused agentgateway config.
if [ "$HAS_AGW" = false ]; then GW="[]"; RT="[]"; POL="[]"; BE="[]"; fi
EDITION="community"; echo "$GW" | jq -e '.[]|select(.spec.gatewayClassName=="enterprise-agentgateway")' >/dev/null 2>&1 && EDITION="enterprise"

# ── Proxy admin /config_dump (version + loaded enrichment). Soft-fail. ──────────
# Docs: each gateway pod serves admin on :15000; /config_dump includes build info
# (.version) and the runtime-loaded binds/routes/backends/policies. Local port is
# always ephemeral — never hardcode 15000 on the host (may already be in use).
_free_port() {
  python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()' 2>/dev/null || echo ""
}

# Fetch one pod's /config_dump to stdout. Returns non-zero on failure (stdout empty).
_fetch_one_dump() {
  local ns="$1" pod="$2" local_port pf_pid i out=""
  local_port="$(_free_port)"
  [ -z "$local_port" ] && return 1
  kubectl --context "$CTX" port-forward -n "$ns" "pod/${pod}" "${local_port}:15000" >/dev/null 2>&1 &
  pf_pid=$!
  i=0
  while [ "$i" -lt "$DUMP_TIMEOUT" ]; do
    if out="$(curl -sf -m 2 "http://127.0.0.1:${local_port}/config_dump" 2>/dev/null)" \
       && printf '%s' "$out" | jq -e 'type=="object"' >/dev/null 2>&1; then
      printf '%s' "$out"
      kill "$pf_pid" 2>/dev/null || true
      wait "$pf_pid" 2>/dev/null || true
      return 0
    fi
    # Bail early if the PF process died.
    kill -0 "$pf_pid" 2>/dev/null || break
    i=$((i + 1))
    sleep 1
  done
  kill "$pf_pid" 2>/dev/null || true
  wait "$pf_pid" 2>/dev/null || true
  return 1
}

# Image-tag fallback from a gateway's dataplane pod (no admin port needed).
_image_version_for_gw() {
  local gwn="$1"
  printf '%s' "$PODS" | jq -r --arg g "$gwn" '
    [.[] | select(.metadata.labels["gateway.networking.k8s.io/gateway-name"] == $g)
         | .spec.containers[0].image // empty]
    | first // empty
    | if . == "" then empty else (split(":")|last) end'
}

DUMPS='{}'          # { "ns/name": <config_dump>, ... }
VERSION=""
VERSION_SOURCE="unknown"
GIT_REVISION=""

if [ "$DUMP" = "true" ]; then
  echo "==> Fetching proxy /config_dump (admin :15000)…"
  while IFS=$'\t' read -r gw_ns gw_name; do
    [ -z "$gw_name" ] && continue
    # Prefer a Ready Running pod labelled for this gateway.
    pod="$(printf '%s' "$PODS" | jq -r --arg g "$gw_name" --arg ns "$gw_ns" '
      [.[] | select(.metadata.namespace==$ns
                 and .metadata.labels["gateway.networking.k8s.io/gateway-name"]==$g
                 and .status.phase=="Running")
          | .metadata.name] | first // empty')"
    if [ -z "$pod" ]; then
      echo "    ${gw_ns}/${gw_name}: no Running dataplane pod — skip dump" >&2
      continue
    fi
    if dump_json="$(_fetch_one_dump "$gw_ns" "$pod")"; then
      key="${gw_ns}/${gw_name}"
      DUMPS="$(jq -cn --argjson d "$DUMPS" --arg k "$key" --argjson v "$dump_json" '$d + {($k): $v}')"
      ver="$(printf '%s' "$dump_json" | jq -r '.version.version // empty')"
      rev="$(printf '%s' "$dump_json" | jq -r '.version.git_revision // empty')"
      if [ -n "$ver" ]; then
        if [ -z "$VERSION" ]; then
          VERSION="$ver"
          VERSION_SOURCE="config_dump"
          GIT_REVISION="$rev"
        elif [ "$ver" != "$VERSION" ]; then
          echo "    warn: version skew ${gw_ns}/${gw_name}=${ver} vs ${VERSION}" >&2
        fi
      fi
      echo "    ${gw_ns}/${gw_name} (pod ${pod}): dump ok${ver:+ · ${ver}}"
    else
      echo "    ${gw_ns}/${gw_name} (pod ${pod}): dump unavailable — will fall back" >&2
    fi
  done <<EOF
$(echo "$GW" | jq -r '.[]|select((.spec.gatewayClassName // "")|test("agentgateway"))|[.metadata.namespace,.metadata.name]|@tsv')
EOF
fi

# Image-tag fallback when dump didn't yield a version.
if [ "$FILE_MODE" = true ] && [ -n "$REQUESTED_VERSION" ]; then
  VERSION="$REQUESTED_VERSION"
  VERSION_SOURCE="given"
elif [ -z "$VERSION" ] && [ "$HAS_AGW" = true ]; then
  first_gw="$(echo "$GWNAMES" | cut -d, -f1)"
  img_ver="$(_image_version_for_gw "$first_gw")"
  if [ -n "$img_ver" ]; then
    VERSION="$img_ver"
    VERSION_SOURCE="image"
    echo "    version from image tag: ${VERSION}"
  else
    echo "    version: unknown (no dump, no image tag)" >&2
  fi
fi

# Loaded (ns/name) sets from all dumps — union across gateways.
LOADED="$(jq -cn --argjson dumps "$DUMPS" '
  def route_keys:
    [.[] | .binds[]? | (.listeners // {}) | to_entries[]? | (.value.routes // {}) | to_entries[]?
     | .value | select(.name != null)
     | ((.namespace // "") + "/" + .name)];
  # Plain Service backendRefs never appear in .backends — the dump records them inline on each
  # route as service.name "<ns>/<svc>.<ns>.svc.cluster.local". Collect those as ns/svc.
  def service_keys:
    [.[] | .binds[]? | (.listeners // {}) | to_entries[]? | (.value.routes // {}) | to_entries[]?
     | .value.backends[]? | .service.name? | select(type=="string")
     | split("/") as $p | select(($p|length)==2)
     | ($p[1] | split(".")) as $h | $h[1] + "/" + $h[0]];
  def backend_keys:
    [.[] | .backends[]? | .backend // {} | to_entries[]? | .value
     | select(type=="object" and (.name|type)=="string")
     | ((.namespace // "") + "/" + .name)];
  def policy_keys:
    [.[] | .policies[]? | . as $p
     | (
         (if ($p.name|type)=="object" and ($p.name.name|type)=="string"
          then [($p.name.namespace // "") + "/" + $p.name.name] else [] end)
         + ( ($p.key // "") as $k
             | if ($k|startswith("traffic/")) or ($k|startswith("agw-enterprise-policy/"))
               then ($k|split(":")[0]|split("/")) as $parts
                    | if ($parts|length)>=3 then [$parts[1]+"/"+$parts[2]] else [] end
               elif ($k|test("^[^/]+/[^/]+:"))
               then ($k|split(":")[0]|split("/")) as $parts
                    | if ($parts|length)>=2 then [$parts[0]+"/"+$parts[1]] else [] end
               else [] end)
       )[] ];
  ($dumps | [.[]]) as $all
  | {
      routes:   ($all | route_keys   | unique),
      backends: ($all | backend_keys | unique),
      services: ($all | service_keys | unique),
      policies: ($all | policy_keys  | unique),
      hasDump:  (($dumps|length) > 0)
    }
')"

# ── Build Cytoscape elements (nodes + edges) from the snapshot. ─────────────────
DATA="$(jq -cn \
  --argjson gw "$GW" --slurpfile rt <(_json "$RT") --slurpfile pol <(_json "$POL") --slurpfile be <(_json "$BE") \
  --slurpfile pods <(_json "$PODS") --slurpfile deps <(_json "$DEPS") --argjson gc "$GC" \
  --argjson loaded "$LOADED" \
  --arg cluster "$CLUSTER" --arg edition "$EDITION" \
  --arg version "$VERSION" --arg versionSource "$VERSION_SOURCE" --arg gitRevision "$GIT_REVISION" \
  --arg honorStatus "$HONOR_STATUS" --arg fileMode "$FILE_MODE" '
  $rt[0] as $rt | $pol[0] as $pol | $be[0] as $be | $pods[0] as $pods | $deps[0] as $deps |
  def honor: $honorStatus == "true";
  def cond(t): [.status.conditions[]?|select(.type==t).status];
  def stat(t): if honor|not then "na" else (cond(t) as $c | if ($c|length)==0 then "na" elif ($c|all(.=="True")) then "ok" else "bad" end) end;
  def rstat:
    if honor|not then "na" else (
    ([.status.parents[]?.conditions[]?|select(.type=="Accepted").status]) as $a
    | ([.status.parents[]?.conditions[]?|select(.type=="ResolvedRefs").status]) as $r
    | if ($a|length)==0 then "na" elif (($a|all(.=="True")) and ($r|all(.=="True"))) then "ok" else "bad" end) end;
  # Policies use the Gateway-API GEP-713 PolicyStatus shape: conditions live under
  # .status.ancestors[].conditions[] (Accepted + Attached), NOT .status.conditions.
  def pconds: [.status.ancestors[]?.conditions[]?];
  def pstat: if honor|not then "na" else (pconds as $c | if ($c|length)==0 then "na" elif ($c|any(.status!="True")) then "bad" else "ok" end) end;
  def backend_rtype($default):
    (.group // "") as $g | (.kind // "") as $k
    | if $g=="enterpriseagentgateway.solo.io" or $k=="EnterpriseAgentgatewayBackend"
      then "enterpriseagentgatewaybackends.enterpriseagentgateway.solo.io"
      elif $g=="agentgateway.dev" or $k=="AgentgatewayBackend"
      then "agentgatewaybackends.agentgateway.dev"
      elif $k=="Service" or $g=="" or $g=="core" then $default
      else $default end;
  def backend_key($default_ns; $default_rtype):
    (backend_rtype($default_rtype))+":"+(.namespace // $default_ns)+"/"+.name;
  def aggregate_refs($relation):
    group_by(.data.source+"|"+.data.target)
    | map(length as $n | .[0]
      | .data.refCount=$n
      | .data.relation=$relation
      | .data.rel=($relation+(if $n>1 then " ×"+($n|tostring) else "" end)));
  # Map a node ns/name into loaded=true|false|na from the dump-derived sets.
  # Capture $id before piping into index — inside index(...), `.` would be $keys.
  def mark_loaded($keys):
    (.ns+"/"+ .name) as $id
    | if ($loaded.hasDump|not) then "na"
      elif (($keys | index($id)) != null) then "true"
      else "false" end;

  ($gw | map(select((.spec.gatewayClassName // "")|test("agentgateway")))) as $gws
  | ($gws | map(.metadata.name)) as $gwnames
  | ($gwnames[0] // "agw") as $gw0

  # Backends: union of CR backends + route backendRefs + policy backendRefs. Full Kubernetes
  # resource identity keeps same-named enterprise/community CRs as separate graph nodes.
  | ([ ($rt[] | .metadata.namespace as $rns | .spec.rules[]?.backendRefs[]?
         | . as $ref
         | {key:($ref|backend_key($rns; "service")), ns:(.namespace // $rns), name:.name,
            rtype:($ref|backend_rtype("service")), cr:false}),
       ($pol[] | .metadata.namespace as $pns | .. | objects | .backendRef?
         | select(type=="object" and .name? != null) | . as $ref
         | {key:($ref|backend_key($pns; "agentgatewaybackends.agentgateway.dev")),
            ns:(.namespace // $pns), name:.name,
            rtype:($ref|backend_rtype("agentgatewaybackends.agentgateway.dev")), cr:false}),
       ($be[] | {key:(._rtype+":"+.metadata.namespace+"/"+.metadata.name),
                 ns:.metadata.namespace, name:.metadata.name, origin:(._source // null),
                 cr:true, btype:((.spec|keys|map(select(.!="policies"))|first)//"?"), rtype:._rtype,
                 status:stat("Accepted"), conds:(if honor then [.status.conditions[]?|(.type+"="+.status)] else ["(status not evaluated)"] end)}) ]
     | group_by(.key) | map((map(select(.cr)) | first) // add)) as $backends

  # control-plane deployments (enterprise-agentgateway + its sidecar services)
  | ($deps | map(select(.metadata.name=="enterprise-agentgateway" or (.metadata.name|endswith("-enterprise-agentgateway"))))) as $cp
  # GatewayClass(es) the agentgateway Gateways reference
  | ($gws | map(.spec.gatewayClassName) | unique) as $classes
  # is the core control plane present? (drives the control-plane compound + its edges)
  | ($cp | any(.metadata.name=="enterprise-agentgateway")) as $hasCP

  | {
      cluster:$cluster, edition:$edition, gateways:$gwnames, fileMode:($fileMode=="true"),
      version:$version, versionSource:$versionSource, gitRevision:$gitRevision,
      elements: (
        # ── Gateway nodes (data plane) ──
        [ $gws[] | {data:{
            id:("gateway:"+.metadata.namespace+"/"+.metadata.name), label:.metadata.name,
            kind:"Gateway", role:"dataplane", plane:"data", ns:.metadata.namespace, name:.metadata.name,
            status:stat("Programmed"), rtype:"gateway", loaded:"na",
            origin:(._source // null),
            kubectl:("kubectl get gateway "+.metadata.name+" -n "+.metadata.namespace+" -o yaml"),
            detail:{ class:.spec.gatewayClassName, address:(if honor then (.status.addresses[0].value//"-") else "-" end),
                     listeners:[.spec.listeners[]|(.protocol+"/"+(.port|tostring)+" ("+(.hostname//"*")+")")],
                     conditions:(if honor then [.status.conditions[]?|(.type+"="+.status)] else ["(status not evaluated)"] end) } }} ]

        # ── Control-plane deployment nodes (control plane) ──
        + [ $cp[] | {data:{
            id:("deploy:"+.metadata.namespace+"/"+.metadata.name), label:.metadata.name,
            kind:"Deployment", role:"controlplane", plane:"control", ns:.metadata.namespace, name:.metadata.name,
            aux:(.metadata.name != "enterprise-agentgateway"),
            status:(if honor|not then "na" elif (.status.readyReplicas//0)==(.status.replicas//0) and (.status.replicas//0)>0 then "ok" else "bad" end),
            rtype:"deploy", loaded:"na",
            origin:(._source // null),
            kubectl:("kubectl get deploy "+.metadata.name+" -n "+.metadata.namespace+" -o yaml"),
            detail:{ ready:((.status.readyReplicas//0|tostring)+"/"+(.status.replicas//0|tostring)) } }} ]

        # ── GatewayClass node(s) + the real chain: ──
        #   Gateway --gatewayClassName--> GatewayClass --controllerName--> control plane --manages--> Gateway
        + [ $classes[] as $cn | ($gc[]|select(.metadata.name==$cn)) as $gcx | {data:{
            id:("gatewayclass:"+$cn), label:$cn, kind:"GatewayClass", role:"class", name:$cn, ns:"(cluster-scoped)",
            status:(if honor|not then "na" else ([$gcx.status.conditions[]?|select(.type=="Accepted").status] as $c
                     | if ($c|length)==0 then "na" elif ($c|all(.=="True")) then "ok" else "bad" end) end),
            rtype:"gatewayclass", loaded:"na", origin:(($gcx // {})._source // null),
            kubectl:("kubectl get gatewayclass "+$cn+" -o yaml"),
            detail:{ controllerName:($gcx.spec.controllerName//"-"),
                     conditions:(if honor then [$gcx.status.conditions[]?|(.type+"="+.status)] else ["(status not evaluated)"] end) } }} ]
        + [ $gws[] | {data:{
            id:("e:class:"+.metadata.namespace+":"+.metadata.name), source:("gateway:"+.metadata.namespace+"/"+.metadata.name),
            target:("gatewayclass:"+.spec.gatewayClassName), rel:"gatewayClassName" }} ]
        + (if $hasCP then ($cp[]|select(.metadata.name=="enterprise-agentgateway")) as $d |
            ([ $classes[] as $cn | {data:{ id:("e:ctrl:"+$cn), source:("gatewayclass:"+$cn),
                 target:("deploy:"+$d.metadata.namespace+"/enterprise-agentgateway"), rel:"controllerName" }} ]
             + [ $gws[] as $g | {data:{ id:("e:manages:"+$g.metadata.name),
                 source:("deploy:"+$d.metadata.namespace+"/enterprise-agentgateway"),
                 target:("gateway:"+$g.metadata.namespace+"/"+$g.metadata.name), rel:"manages" }} ])
           else [] end)

        # ── Data-plane pod nodes (labelled with the gateway name) + edge ──
        + [ $pods[] | select(.metadata.labels["gateway.networking.k8s.io/gateway-name"] as $g | $g != null and ($gwnames|index($g))) | {data:{
            id:("pod:"+.metadata.namespace+"/"+.metadata.name), label:.metadata.name,
            kind:"Pod", role:"dataplane", plane:"data", ns:.metadata.namespace, name:.metadata.name,
            status:(if honor|not then "na" elif .status.phase=="Running" then "ok" else "bad" end), rtype:"pod", loaded:"na",
            origin:(._source // null),
            kubectl:("kubectl get pod "+.metadata.name+" -n "+.metadata.namespace+" -o yaml"),
            detail:{ phase:.status.phase, node:(.spec.nodeName//"-") } }} ]
        + [ $pods[] | (.metadata.labels["gateway.networking.k8s.io/gateway-name"]) as $g
            | select($g != null and ($gwnames|index($g)))
            | {data:{ id:("e:pod:"+.metadata.namespace+":"+.metadata.name),
                      source:("gateway:"+.metadata.namespace+"/"+$g), target:("pod:"+.metadata.namespace+"/"+.metadata.name), rel:"pod" }} ]

        # ── HTTPRoute nodes (ALL — including ones not attached to a known Gateway, so
        #    orphans surface) + parentRef edges (drawn only to Gateways that exist) ──
        + [ $rt[] | {data:{
            id:("httproute:"+.metadata.namespace+"/"+.metadata.name), label:.metadata.name,
            kind:"HTTPRoute", role:"route", ns:.metadata.namespace, name:.metadata.name,
            status:rstat, rtype:"httproute",
            loaded:({ns:.metadata.namespace, name:.metadata.name} | mark_loaded($loaded.routes)),
            origin:(._source // null),
            kubectl:("kubectl get httproute "+.metadata.name+" -n "+.metadata.namespace+" -o yaml"),
            detail:{ hostnames:([.spec.hostnames[]?]|if length==0 then ["*"] else . end),
                     paths:([.spec.rules[]?.matches[]?.path.value]|unique|map(select(.!=null))),
                     conditions:(if honor then [.status.parents[]?.conditions[]?|(.type+"="+.status)] else ["(status not evaluated)"] end) } }} ]
        + [ $rt[] | .metadata.namespace as $rns | .metadata.name as $rn
            | .spec.parentRefs[]? | select(.name as $p | $gwnames|index($p))
            | {data:{ id:("e:parent:"+$rns+":"+$rn+":"+.name), source:("httproute:"+$rns+"/"+$rn),
                      target:("gateway:"+((.namespace)//$rns)+"/"+.name), rel:"parentRef" }} ]

        # ── Backend nodes + backendRef edges from routes ──
        + [ $backends[] | {data:{
            # A plain Kubernetes Service named in a backendRef is a Gateway-API backend, but not an
            # agentgateway Backend CR — draw it as its own kind so the two aren'"'"'t confused.
            id:("backend:"+.key), label:.name, kind:(if (.rtype // "service")=="service" then "Service" else "Backend" end),
            role:(if .cr then "backend" else "external" end), ns:.ns, name:.name,
            status:(.status // "na"), rtype:(.rtype // "service"),
            # Service: found on a loaded route → true; otherwise "na", not false — a Service used
            # only by a policy (e.g. a JWKS fetch) is not recorded on any route.
            loaded:(if (.rtype // "service")=="service"
                    then ({ns:.ns, name:.name} | mark_loaded($loaded.services) | if .=="false" then "na" else . end)
                    else ({ns:.ns, name:.name} | mark_loaded($loaded.backends)) end),
            origin:(.origin // null),
            kubectl:(if .cr then ("kubectl get "+(.rtype)+" "+.name+" -n "+.ns+" -o yaml")
                     elif (.rtype // "service")=="service" then ("kubectl get service "+.name+" -n "+.ns+" -o yaml")
                     else ("kubectl get "+(.rtype)+" "+.name+" -n "+.ns+" -o yaml   # referenced, but no such object") end),
            detail:{ resource:(.rtype // "service"), type:(.btype // "-"),
                     declared:(if .cr then "CR" else "route/policy ref" end),
                     conditions:(.conds // []) } }} ]
        + ([ $rt[] | .metadata.namespace as $rns | .metadata.name as $rn
            | .spec.rules[]?.backendRefs[]? | . as $ref
            | {data:{ id:("e:be:"+$rns+":"+$rn+":"+($ref|backend_key($rns; "service"))),
                      source:("httproute:"+$rns+"/"+$rn),
                      target:("backend:"+($ref|backend_key($rns; "service"))) }} ]
           | aggregate_refs("backendRef"))

        # ── Policy nodes + targetRef edges + backendRef (jwks) edges ──
        + [ $pol[] | {data:{
            id:("policy:"+.metadata.namespace+"/"+.metadata.name), label:.metadata.name,
            kind:.kind, role:"policy", ns:.metadata.namespace, name:.metadata.name,
            status:pstat, rtype:._rtype,
            loaded:({ns:.metadata.namespace, name:.metadata.name} | mark_loaded($loaded.policies)),
            origin:(._source // null),
            kubectl:("kubectl get "+._rtype+" "+.metadata.name+" -n "+.metadata.namespace+" -o yaml"),
            detail:{ targets:[.spec.targetRefs[]?|(.kind+"/"+.name)],
                     conditions:(if honor|not then ["(status not evaluated)"] else
                                 (( [pconds[] | .type+"="+.status+(if .status!="True" then " — "+(.reason//"")+": "+(.message//"") else "" end)] )
                                 | if length==0 then ["(none reported)"] else . end) end) } }} ]
        + [ $pol[] | .metadata.namespace as $pns | .metadata.name as $pn
            | .spec.targetRefs[]?
            | {data:{ id:("e:target:"+$pns+":"+$pn+":"+.kind+":"+.name), source:("policy:"+$pns+"/"+$pn),
                      target:(if .kind=="Gateway" then "gateway:"+(.namespace // $pns)+"/"+.name
                              elif .kind=="HTTPRoute" then "httproute:"+(.namespace // $pns)+"/"+.name
                              elif (.kind|test("Backend")) then "backend:"+(.|backend_key($pns; "agentgatewaybackends.agentgateway.dev"))
                              else "unknown:"+(.namespace // $pns)+"/"+.name end),
                      rel:"targetRef" }} ]
        + ([ $pol[] | .metadata.namespace as $pns | .metadata.name as $pn
            | .. | objects | .backendRef? | select(type=="object" and .name? != null) | . as $ref
            | {data:{ id:("e:polbe:"+$pns+":"+$pn+":"+($ref|backend_key($pns; "agentgatewaybackends.agentgateway.dev"))),
                      source:("policy:"+$pns+"/"+$pn),
                      target:("backend:"+($ref|backend_key($pns; "agentgatewaybackends.agentgateway.dev"))) }} ]
           | aggregate_refs("uses"))
      )
    }')"

# No agentgateway → drop its half (the jq above still emits an empty frame).
[ "$HAS_AGW" = false ] && DATA="$(printf '%s' "$DATA" | jq -c '.elements=[]')"
# Every agentgateway node belongs to the agentgateway view.
DATA="$(printf '%s' "$DATA" | jq -c '.elements |= map(if (.data.source|not) then .data.product //= "agentgateway" else . end)')"

# ── kagent + Agent Substrate elements (lib/graph/kagent.jq), merged onto the same canvas. ──
KDATA='{"elements":[],"objs":{},"kagentVersion":"","kagentEdition":"","substrateVersion":""}'
if [ "$HAS_KAGENT" = true ] || [ "$HAS_SUBSTRATE" = true ]; then
  KDATA="$(jq -cn -f "$KAGENT_JQ" \
    --arg fileMode "$FILE_MODE" --arg honorStatus "$HONOR_STATUS" \
    --slurpfile kobjs <(_json "$KOBJS") --slurpfile deps <(_json "$DEPS") --slurpfile pods <(_json "$PODS") \
    --slurpfile svcs <(_json "$SVCS") \
    --slurpfile gws <(echo "$GW" | jq '[.[]|select((.spec.gatewayClassName // "")|test("agentgateway"))]') \
    --slurpfile rts <(_json "$RT") --slurpfile bes <(_json "$BE"))"
fi
KAGENT_VERSION="$(printf '%s' "$KDATA" | jq -r '.kagentVersion')"
KAGENT_EDITION="$(printf '%s' "$KDATA" | jq -r '.kagentEdition')"
SUBSTRATE_VERSION="$(printf '%s' "$KDATA" | jq -r '.substrateVersion')"
DATA="$(jq -cn --argjson d "$DATA" --slurpfile k <(_json "$KDATA") \
  --argjson agw "$HAS_AGW" --argjson kagent "$HAS_KAGENT" --argjson substrate "$HAS_SUBSTRATE" \
  --arg kv "$KAGENT_VERSION" --arg ke "$KAGENT_EDITION" --arg sv "$SUBSTRATE_VERSION" '
  $d + {elements:($d.elements + $k[0].elements),
        products:{agentgateway:$agw, kagent:$kagent, substrate:$substrate},
        kagentVersion:$kv, kagentEdition:$ke, substrateVersion:$sv}')"

if [ "$HAS_AGW" = true ]; then
  VER_NOTE="${VERSION:-unknown}"
  [ -n "$VERSION_SOURCE" ] && [ "$VERSION_SOURCE" != "unknown" ] && VER_NOTE="${VER_NOTE} (${VERSION_SOURCE})"
  echo "    agentgateway: edition=${EDITION}, version=${VER_NOTE}, gateways=${GWNAMES:-none}"
fi
[ "$HAS_KAGENT" = true ] && echo "    kagent: edition=${KAGENT_EDITION}, version=${KAGENT_VERSION:-unknown}, agents=$(printf '%s' "$KOBJS" | jq '[.[]|select(.kind=="Agent" or .kind=="SandboxAgent")]|length')"
[ "$HAS_SUBSTRATE" = true ] && echo "    substrate: version=${SUBSTRATE_VERSION:-unknown}, worker pools=$(printf '%s' "$KOBJS" | jq '[.[]|select(.kind=="WorkerPool")]|length')"

# Refs whose target is not in the snapshot become ghost nodes (same kind, dashed in the HTML).
DATA="$(jq -cn -f "$GHOSTS_JQ" \
  --arg fileMode "$FILE_MODE" \
  --slurpfile data <(_json "$DATA") \
  --slurpfile gw <(_json "$GW") \
  --slurpfile rt <(_json "$RT") \
  --slurpfile svcs <(_json "$SVCS"))"

# Prune edges whose endpoints don't exist (a ghost node is added above for a ref that
# points at nothing; a Gateway that exists but is not agentgateway is left dangling on
# purpose and dropped here). Keeps Cytoscape from erroring on edges with unknown source/target.
DATA="$(printf '%s' "$DATA" | jq '
  ([.elements[]|select(.data.source|not)|.data.id]) as $ids
  | .elements |= map(
      (.data.source) as $s | (.data.target) as $t
      | select(($s|not) or (($ids|index($s)) and ($ids|index($t)))))')"
NODE_N="$(printf '%s' "$DATA" | jq '[.elements[]|select(.data.source|not)]|length')"
EDGE_N="$(printf '%s' "$DATA" | jq '[.elements[]|select(.data.source)]|length')"
GHOST_N="$(printf '%s' "$DATA" | jq '[.elements[]|select(.data.ghost==true)]|length')"
ghost_note=""
[ "$GHOST_N" != 0 ] && ghost_note=", ${GHOST_N} ghost(s)"
echo "    ${NODE_N} node(s), ${EDGE_N} edge(s)${ghost_note}"

# ── Per-node manifests → inlined YAML (raw + cleaned). We already fetched every object, so
# map each node id to its full object, then render two YAML views: the raw manifest and a
# cleaned one for copy/paste into a new cluster/bundle (kubectl-neat if installed, else a
# built-in strip of server-managed fields). All done at generate time — no extra cluster calls.
MANIFESTS="$(jq -n --slurpfile data <(_json "$DATA") --argjson gws "$GW" --slurpfile rts <(_json "$RT") --argjson gcs "$GC" \
  --slurpfile deps <(_json "$DEPS") --slurpfile pods <(_json "$PODS") --slurpfile bes <(_json "$BE") --slurpfile pols <(_json "$POL") \
  --slurpfile kobjs <(printf '%s' "$KDATA" | jq '.objs') '
  def redact:
    if type == "object" then
      with_entries(
        if ((.value | type) == "string") and (.key | test("^(accessKey|secretKey|sessionToken|apiKey|api_key|token|password|clientSecret|authorization)$"))
        then .value = "<redacted>"
        elif ((.key == "data") or (.key == "stringData")) and ((.value | type) == "object")
        then .value |= with_entries(.value = (if (.value | type) == "object" or (.value | type) == "array" then .value else "<redacted>" end))
        else .value |= redact end)
    elif type == "array" then map(redact)
    else . end;
  $data[0] as $data | $rts[0] as $rts | $deps[0] as $deps | $pods[0] as $pods | $bes[0] as $bes
  | $pols[0] as $pols | $kobjs[0] as $kobjs
  | ($data.elements | map(select(.data.source|not) | .data)) as $nodes
  | reduce $nodes[] as $n ({};
      ($n.rtype) as $k | ($n.ns) as $ns | ($n.name) as $nm | ($n.id) as $id
      | (( if   ($id|startswith("k:")) then $kobjs[$id]
           elif $k=="gateway"      then first($gws[]|select(.metadata.namespace==$ns and .metadata.name==$nm))
           elif $k=="httproute"    then first($rts[]|select(.metadata.namespace==$ns and .metadata.name==$nm))
           elif $k=="gatewayclass" then first($gcs[]|select(.metadata.name==$nm))
           elif $k=="deploy"       then first($deps[]|select(.metadata.namespace==$ns and .metadata.name==$nm))
           elif $k=="pod"          then first($pods[]|select(.metadata.namespace==$ns and .metadata.name==$nm))
           elif ($k|test("backend")) then first($bes[]|select(._rtype==$k and .metadata.namespace==$ns and .metadata.name==$nm))
           elif ($k|test("polic"))   then first($pols[]|select(.metadata.namespace==$ns and .metadata.name==$nm))
           else null end ) // null ) as $obj
      # Drop kubectl'"'"'s last-applied-configuration bookkeeping annotation (a redundant
      # serialized copy of the object). It'"'"'s huge noise and — because it'"'"'s stored with a
      # trailing newline — YAML-serializes to a blank line + lone "'"'"'" that reads like a
      # stray comma. Strip it from BOTH raw and clean (clean stripped it already); drop the
      # annotations map entirely if it was the only key.
      | if $obj != null then .[$id]=($obj
            | del(._rtype, ._source, .metadata._defaultedNamespace)
            | redact
            | del(.metadata.annotations."kubectl.kubernetes.io/last-applied-configuration")
            | if ((.metadata.annotations // {}) | length)==0 then del(.metadata.annotations) else . end)
          else . end)')"

RAW_YAML="$(printf '%s' "$MANIFESTS" | ruby -ryaml -rjson -e 'h=JSON.parse(STDIN.read);print JSON.generate(h.transform_values{|v| YAML.dump(v)})' 2>/dev/null || echo '{}')"
if command -v kubectl-neat >/dev/null 2>&1; then
  CLEAN_BY="kubectl-neat"
  # kubectl-neat cleans metadata/status noise for copy/paste, but it also PRUNES empty-valued
  # keys — and under .spec an empty object can be a meaningful selector (e.g.
  # policies.auth.passthrough: {} chooses JWT passthrough over SigV4). Pruning it silently
  # changes behavior on re-apply. So neat for the metadata cleanup, then restore .spec verbatim
  # from the original object. Collect JSON, then one YAML transform (mirrors RAW_YAML / built-in).
  NEATED="{}"
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    obj="$(printf '%s' "$MANIFESTS" | jq -c --arg k "$id" '.[$k]')"
    n="$(printf '%s' "$obj" | kubectl-neat -f - -o json 2>/dev/null || true)"
    [ -z "$n" ] && n="$obj"
    merged="$(jq -cn --argjson n "$n" --argjson o "$obj" '$n | if ($o|has("spec")) then .spec=$o.spec else . end')"
    NEATED="$(printf '%s' "$NEATED" | jq -c --arg k "$id" --argjson v "$merged" '.[$k]=$v')"
  done <<EOF
$(printf '%s' "$MANIFESTS" | jq -r 'keys[]')
EOF
  CLEAN_YAML="$(printf '%s' "$NEATED" | ruby -ryaml -rjson -e 'h=JSON.parse(STDIN.read);print JSON.generate(h.transform_values{|v| YAML.dump(v)})' 2>/dev/null || echo '{}')"
else
  CLEAN_BY="built-in strip"
  CLEAN_YAML="$(printf '%s' "$MANIFESTS" | jq '
    def clean: del(.metadata.managedFields, .metadata.resourceVersion, .metadata.uid,
      .metadata.generation, .metadata.creationTimestamp, .metadata.selfLink, .status,
      .metadata.annotations."kubectl.kubernetes.io/last-applied-configuration")
      | if ((.metadata.annotations // {}) | length)==0 then del(.metadata.annotations) else . end;
    map_values(clean)' \
    | ruby -ryaml -rjson -e 'h=JSON.parse(STDIN.read);print JSON.generate(h.transform_values{|v| YAML.dump(v)})' 2>/dev/null || echo '{}')"
fi
YAML_MAP="$(jq -n --argjson raw "$RAW_YAML" --argjson clean "$CLEAN_YAML" --arg by "$CLEAN_BY" '
  reduce ($raw|keys[]) as $k ({}; .[$k]={raw:$raw[$k], clean:($clean[$k] // ""), cleanBy:$by})')"
echo "    manifests embedded for $(printf '%s' "$YAML_MAP" | jq 'length') node(s)  (clean via ${CLEAN_BY})"

# Build a compact dump payload for the HTML (per-gateway dumps + summary counts).
DUMP_PAYLOAD="$(jq -cn --argjson dumps "$DUMPS" --arg version "$VERSION" --arg versionSource "$VERSION_SOURCE" --arg gitRevision "$GIT_REVISION" '
  def route_count:
    [.binds[]? | (.listeners // {}) | to_entries[]? | (.value.routes // {}) | keys[]] | length;
  ($dumps | [.[]] | {
    binds:     (map((.binds // []) | length) | add // 0),
    routes:    (map(route_count) | add // 0),
    backends:  (map((.backends // []) | length) | add // 0),
    policies:  (map((.policies // []) | length) | add // 0),
    gateways:  ($dumps | keys | length)
  }) as $summary
  | { version:$version, versionSource:$versionSource, gitRevision:$gitRevision,
      summary:$summary, gateways:$dumps }
')"

# Subtitle: one segment per product present. A file render says so, and does not
# pretend the files were accepted by a controller.
if [ "$FILE_MODE" = true ]; then
  SUBTITLE="files ${CLUSTER}"
  if [ "$HONOR_STATUS" = true ]; then
    SUBTITLE="${SUBTITLE} · exported status"
  else
    SUBTITLE="${SUBTITLE} · status not evaluated"
  fi
else
  SUBTITLE="cluster ${CLUSTER}"
fi
[ "$HAS_AGW" = true ] && SUBTITLE="${SUBTITLE} · agentgateway (${EDITION})${VERSION:+ ${VERSION}}"
[ "$HAS_KAGENT" = true ] && SUBTITLE="${SUBTITLE} · kagent${KAGENT_EDITION:+ (${KAGENT_EDITION})}${KAGENT_VERSION:+ ${KAGENT_VERSION}}"
[ "$HAS_SUBSTRATE" = true ] && SUBTITLE="${SUBTITLE} · substrate${SUBSTRATE_VERSION:+ ${SUBSTRATE_VERSION}}"

# ── Assemble the self-contained HTML (vendored Cytoscape + inlined data + app). ─
mkdir -p "$(dirname "$OUT")"
{
  cat <<HTMLHEAD
<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>solomog graph · ${CLUSTER}</title>
<style>
  :root{--bg:#0f1420;--panel:#171e2e;--line:#2a344a;--txt:#e6ebf5;--dim:#8a97b0;--accent:#7aa2ff}
  *{box-sizing:border-box} html,body{margin:0;height:100%;font:14px/1.45 -apple-system,Segoe UI,Roboto,sans-serif;background:var(--bg);color:var(--txt)}
  #wrap{display:flex;height:100vh}
  #cy{flex:1;height:100%;min-width:0}
  #grip{flex:0 0 6px;cursor:col-resize;background:var(--line);border-left:1px solid var(--bg)}
  #grip:hover,#grip.drag{background:var(--accent)}
  #side{flex:0 0 380px;min-width:300px;max-width:88vw;background:var(--panel);padding:16px;overflow:auto}
  h1{font-size:14px;margin:0 0 4px} .sub{color:var(--dim);font-size:12px;margin-bottom:14px}
  .empty{color:var(--dim)} .k{color:var(--dim);font-size:11px;text-transform:uppercase;letter-spacing:.06em}
  .name{font-size:16px;font-weight:600;margin:2px 0 8px;word-break:break-all}
  .badge{display:inline-block;padding:1px 8px;border-radius:10px;font-size:11px;font-weight:600;margin-right:4px}
  .ok{background:#153a25;color:#5fe3a1} .bad{background:#42121a;color:#ff8098} .na{background:#26314a;color:#9fb0d0}
  .warn{background:#3a2a12;color:#ffb454}
  table{width:100%;border-collapse:collapse;margin:10px 0} td{padding:3px 0;vertical-align:top;font-size:13px}
  td.key{color:var(--dim);width:34%;padding-right:8px} pre{background:#0b0f18;border:1px solid var(--line);border-radius:6px;padding:10px;overflow:auto;font-size:12px;white-space:pre-wrap;word-break:break-all}
  button{background:var(--accent);color:#0b0f18;border:0;border-radius:6px;padding:6px 12px;font-weight:600;cursor:pointer}
  .hint{color:var(--dim);font-size:12px;margin-top:6px}
  .tabs{display:flex;gap:6px;margin:14px 0 0;align-items:flex-end}
  .tab{background:transparent;color:var(--dim);border:1px solid var(--line);border-bottom:0;border-radius:6px 6px 0 0;padding:4px 11px;font-size:12px;font-weight:600}
  .tab.active{color:var(--txt);border-color:var(--accent)}
  .tab.mini{margin-left:auto;border:1px solid var(--line);border-radius:6px;padding:3px 9px;font-weight:400}
  pre.yaml{margin-top:0;border-top-left-radius:0;max-height:48vh;white-space:pre;word-break:normal}
  pre.yaml .yk{color:#82aaff} pre.yaml .ys{color:#c3e88d} pre.yaml .yn{color:#f78c6c}
  pre.yaml .yc{color:#546178;font-style:italic} pre.yaml .yd{color:#8a97b0}
  #legend{position:fixed;left:12px;bottom:12px;background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:8px 10px;font-size:12px;color:var(--dim)}
  #legend span{display:inline-block;margin-right:10px}
  #legend i{display:inline-block;width:11px;height:11px;margin-right:5px;vertical-align:middle;background:#9fb0d0}
  #legend i.ellipse{border-radius:50%}
  #legend i.rrect{border-radius:3px}
  #legend i.diamond{width:9px;height:9px;transform:rotate(45deg)}
  #legend i.hex{clip-path:polygon(25% 0,75% 0,100% 50%,75% 100%,25% 100%,0 50%)}
  #legend i.tag{clip-path:polygon(0 0,68% 0,100% 50%,68% 100%,0 100%)}
  #legend i.ring{background:transparent;border:2px solid #9fb0d0;border-radius:50%}
  #legend i.ring.dash{border-style:dashed;border-radius:3px}
  #legend i.star{clip-path:polygon(50% 0,61% 35%,98% 35%,68% 57%,79% 91%,50% 70%,21% 91%,32% 57%,2% 35%,39% 35%)}
  #legend i.rhomb{clip-path:polygon(25% 0,100% 0,75% 100%,0 100%)}
  #legend i.cut{clip-path:polygon(25% 0,75% 0,100% 25%,100% 75%,75% 100%,25% 100%,0 75%,0 25%);border-radius:0}
  #legend i.tri{clip-path:polygon(50% 0,100% 100%,0 100%)}
  #legend i.pent{clip-path:polygon(50% 0,100% 38%,82% 100%,18% 100%,0 38%)}
  #legend i.barrel{border-radius:35%/50%}
  #legend i.oct{clip-path:polygon(30% 0,70% 0,100% 30%,100% 70%,70% 100%,30% 100%,0 70%,0 30%)}
  #controls{position:fixed;left:12px;top:12px;background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:8px 12px;font-size:12px;color:var(--dim);display:flex;gap:14px;align-items:center}
  #controls label{cursor:pointer;user-select:none} #controls input{vertical-align:middle;margin-right:5px}
  #controls button{background:transparent;color:var(--accent);border:1px solid var(--line);border-radius:6px;padding:3px 9px;font-size:12px}
  #views{display:flex;gap:4px;align-items:center;padding-right:10px;border-right:1px solid var(--line)}
  #views button{color:var(--dim)} #views button.on{color:#0b0f18;background:var(--accent);border-color:var(--accent)}
</style></head><body><div id="wrap"><div id="cy"></div>
<div id="grip" title="drag to resize"></div>
<div id="side"><h1>solomog graph</h1><div class="sub">${SUBTITLE}</div>
<div id="detail"><div class="empty">Click a node to inspect it, or open the dump panel.</div></div></div></div>
<div id="controls">
  <span id="views"></span>
  <label><input type="checkbox" id="unused"> unused components</label>
  <label><input type="checkbox" id="aux"> control-plane services</label>
  <button id="relayout">re-layout</button>
  <button id="show-dump" title="proxy /config_dump">dump</button>
</div>
<div id="legend"></div>
<script>
HTMLHEAD
  cat "$CYTO"
  echo '</script><script>'
  printf 'window.SOLOMOG_DATA=%s;\n' "$DATA"
  printf 'window.SOLOMOG_YAML=%s;\n' "$YAML_MAP"
  printf 'window.SOLOMOG_DUMP=%s;\n' "$DUMP_PAYLOAD"
  cat <<'APPJS'
(function(){
  var D=window.SOLOMOG_DATA;
  var DUMP=window.SOLOMOG_DUMP||{};
  var COLOR={Gateway:'#7aa2ff',Deployment:'#c792ea',Pod:'#82aaff',HTTPRoute:'#5fe3a1',Backend:'#ffcb6b',Policy:'#f78c6c',GatewayClass:'#80cbc4',
    Agent:'#ff79c6',SandboxAgent:'#ff79c6',AgentTemplate:'#b39ddb',Harness:'#4dd0e1',AgentHarness:'#4dd0e1',SandboxTemplate:'#4dd0e1',
    ModelConfig:'#e6c07b',ModelProviderConfig:'#bcaaa4',RemoteMCPServer:'#9ccc65',MCPServer:'#9ccc65',Service:'#9fb0d0',
    WorkerPool:'#4fc3f7',SandboxConfig:'#80cbc4',EnterpriseKagentRBACPolicy:'#f78c6c'};
  // legend swatch class per kind (mirrors the canvas shape)
  var SHAPE={Gateway:'rrect',GatewayClass:'tag',Deployment:'rrect',Pod:'ellipse',HTTPRoute:'ellipse',Backend:'diamond',Policy:'hex',
    Agent:'star',SandboxAgent:'star',AgentTemplate:'rhomb',Harness:'cut',AgentHarness:'cut',SandboxTemplate:'cut',
    ModelConfig:'tri',ModelProviderConfig:'tri',RemoteMCPServer:'pent',MCPServer:'pent',Service:'barrel',
    WorkerPool:'oct',SandboxConfig:'tag',EnterpriseKagentRBACPolicy:'hex'};
  var PRODUCTS=D.products||{agentgateway:true};
  var KSIDE={kagent:true,substrate:true};
  function side(p){return KSIDE[p]?'kagent':'agentgateway';}
  function statColor(s){return s==='ok'?'#3fe08f':s==='bad'?'#ff5f7a':'#4a5578';}
  var cy=cytoscape({
    container:document.getElementById('cy'),
    elements:D.elements,
    style:[
      {selector:'node',style:{
        'label':'data(label)','font-size':10,'color':'#dfe6f5','text-wrap':'wrap','text-max-width':120,
        'text-valign':'bottom','text-margin-y':4,'width':26,'height':26,
        'background-color':function(n){return COLOR[n.data('kind')]||'#9fb0d0';},
        'border-width':3,'border-color':function(n){return statColor(n.data('status'));}}},
      {selector:'node[kind="Gateway"]',style:{'shape':'round-rectangle','width':40,'height':30}},
      {selector:'node[kind="Deployment"]',style:{'shape':'round-rectangle'}},
      {selector:'node[kind="Backend"]',style:{'shape':'diamond','width':30,'height':30}},
      // plain Kubernetes Service (an agentgateway backendRef, or a 0.10 kagent tool)
      {selector:'node[kind="Service"]',style:{'shape':'barrel','width':30,'height':22}},
      {selector:'node[kind="GatewayClass"], node[kind="SandboxConfig"]',style:{'shape':'round-tag','width':34,'height':26}},
      // policies' kind is the CR kind (EnterpriseAgentgatewayPolicy / AgentgatewayPolicy),
      // not "Policy", so the kind→COLOR lookup misses — set their fill by role instead.
      {selector:'node[role="policy"]',style:{'shape':'hexagon','background-color':'#f78c6c'}},
      // kagent + substrate
      {selector:'node[kind="Agent"], node[kind="SandboxAgent"]',style:{'shape':'star','width':34,'height':34}},
      {selector:'node[kind="AgentTemplate"]',style:{'shape':'rhomboid','width':34,'height':24}},
      {selector:'node[kind="Harness"], node[kind="AgentHarness"], node[kind="SandboxTemplate"]',style:{'shape':'cut-rectangle','width':32,'height':24}},
      {selector:'node[kind="ModelConfig"], node[kind="ModelProviderConfig"]',style:{'shape':'round-triangle','width':30,'height':28}},
      {selector:'node[kind="RemoteMCPServer"], node[kind="MCPServer"]',style:{'shape':'round-pentagon','width':30,'height':30}},
      {selector:'node[kind="WorkerPool"]',style:{'shape':'octagon','width':32,'height':32}},
      {selector:'node[kind="EnterpriseKagentRBACPolicy"]',style:{'shape':'hexagon'}},
      // a ref whose target is not in the snapshot: same shape and color, dashed and dimmed
      {selector:'node[?ghost]',style:{'background-opacity':0.35,'border-style':'dashed','border-width':2,'opacity':0.9}},
      // other product's node, pulled into a single-product view by a cross-product edge
      {selector:'node.bridge',style:{'opacity':0.55}},
      // unused config (not reachable from any Gateway / Agent) + the anchor it clusters under
      {selector:'node.orphan',style:{'border-color':'#ffb454','border-style':'dashed','border-width':3}},
      {selector:'node[?isUnusedAnchor]',style:{'shape':'round-rectangle','background-color':'#ffb454','background-opacity':0.15,
        'border-color':'#ffb454','border-width':1,'border-style':'dashed','width':18,'height':18,
        'label':'data(label)','color':'#ffb454','font-size':11,'text-valign':'bottom','text-margin-y':4}},
      {selector:'edge[rel="unused"]',style:{'line-style':'dashed','line-color':'#7a5a2a','target-arrow-shape':'none','width':1}},
      {selector:'node:selected',style:{'border-color':'#fff','border-width':4}},
      {selector:'edge',style:{
        'label':'data(rel)','font-size':8,'color':'#8a97b0','text-background-color':'#0f1420','text-background-opacity':1,
        'width':function(e){return 1.5+Math.min(Math.max(Number(e.data('refCount')||1)-1,0),4)*.9;},
        'line-color':'#39435c','target-arrow-color':'#39435c',
        'target-arrow-shape':'triangle','curve-style':'bezier','arrow-scale':.8}},
      {selector:'edge[rel="manages"]',style:{'line-style':'dashed','line-color':'#c792ea','target-arrow-color':'#c792ea'}},
      {selector:'edge[rel="controllerName"]',style:{'line-style':'dashed','line-color':'#80cbc4','target-arrow-color':'#80cbc4'}},
      {selector:'edge[rel="gatewayClassName"], edge[rel="sandboxClass"]',style:{'line-color':'#80cbc4','target-arrow-color':'#80cbc4'}},
      {selector:'edge[rel="pod"]',style:{'line-style':'dotted'}},
      {selector:'edge[rel="config"]',style:{'line-style':'dotted','line-color':'#c792ea','target-arrow-color':'#c792ea'}},
      // cross-product traffic: kagent → agentgateway route, agentgateway backend → kagent
      {selector:'edge[?cross]',style:{'line-style':'dashed','line-color':'#ff9e64','target-arrow-color':'#ff9e64','color':'#ff9e64','width':2}}
    ],
    layout:{name:'grid'}
  });

  // ── visibility: view (product) × unused toggle × aux toggle ──────────────────
  var STATE={view:'all',unused:false,aux:false};
  var SIDES={agentgateway:false,kagent:false};
  cy.nodes().forEach(function(n){ if(n.data('product')) SIDES[side(n.data('product'))]=true; });
  var BOTH=SIDES.agentgateway&&SIDES.kagent;
  function passesToggles(n){
    if(n.data('isUnusedAnchor')) return STATE.unused;
    if(n.data('orphan')&&!STATE.unused) return false;
    if(n.data('aux')&&!STATE.aux) return false;
    return true;
  }
  function applyVisibility(){
    cy.batch(function(){
      cy.nodes().removeClass('bridge');
      var shown={};
      cy.nodes().forEach(function(n){
        var inView=STATE.view==='all'||side(n.data('product'))===STATE.view;
        if(inView&&passesToggles(n)) shown[n.id()]=true;
      });
      // single-product view: pull in the far end of each cross-product edge as a bridge
      if(STATE.view!=='all'){
        cy.edges('[?cross]').forEach(function(e){
          var s=e.source(), t=e.target();
          if(shown[s.id()]&&!shown[t.id()]&&passesToggles(t)){shown[t.id()]=true;t.addClass('bridge');}
          else if(shown[t.id()]&&!shown[s.id()]&&passesToggles(s)){shown[s.id()]=true;s.addClass('bridge');}
        });
      }
      cy.nodes().forEach(function(n){ if(shown[n.id()]) n.show(); else n.hide(); });
      cy.edges().forEach(function(e){
        if(shown[e.source().id()]&&shown[e.target().id()]) e.show(); else e.hide();
      });
    });
    renderLegend();
  }

  // Hierarchical layout per product side, then the sides placed left→right. Per-side layout keeps
  // each product's tree readable; cross edges simply span the gap. In a single-product view the
  // bridge nodes join that side's layout so they sit next to what references them.
  function relayout(){
    var vis=cy.nodes(':visible');
    var groups;
    if(STATE.view==='all'&&BOTH){
      groups=[vis.filter(function(n){return side(n.data('product'))==='agentgateway';}),
              vis.filter(function(n){return side(n.data('product'))==='kagent';})];
    } else groups=[vis];
    var x=0;
    groups.forEach(function(nodes){
      if(!nodes.length) return;
      var eles=nodes.union(nodes.edgesWith(nodes).filter(':visible'));
      // Roots: Gateways (agentgateway) and kagent controllers. Substrate is deliberately NOT a
      // root — it is kagent's runtime layer, so it lands below the Harnesses that select its
      // pools (a second root would hoist pools/pods up beside the Agents and tangle the tree).
      // Substrate-only cluster: fall back to its controller.
      function ctl(p){return function(n){return n.data('kind')==='Deployment'&&n.data('role')==='controlplane'&&!n.data('aux')&&n.data('product')===p;};}
      // bridge nodes (the other product's end of a cross edge) are never roots
      var roots=nodes.filter(function(n){return !n.hasClass('bridge')&&(n.data('kind')==='Gateway'||n.data('isUnusedAnchor')||ctl('kagent')(n));});
      if(!roots.filter(function(n){return !n.data('isUnusedAnchor');}).length) roots=roots.union(nodes.filter(function(n){return !n.hasClass('bridge')&&ctl('substrate')(n);}));
      // No Gateway and no controller (a file render of routes or Agents): root on those objects.
      if(!roots.filter(function(n){return !n.data('isUnusedAnchor');}).length){
        roots=roots.union(nodes.filter(function(n){
          return !n.hasClass('bridge')&&!n.data('ghost')&&(n.data('kind')==='HTTPRoute'||n.data('kind')==='Agent'||n.data('kind')==='SandboxAgent');
        }));
      }
      eles.layout({name:'breadthfirst',directed:false,roots:roots.length?roots:undefined,
        spacingFactor:1.3,padding:30,avoidOverlap:true,animate:false}).run();
      var bb=nodes.boundingBox();
      nodes.shift({x:x-bb.x1,y:-bb.y1});
      x+=bb.w+220;
    });
    cy.fit(cy.elements(':visible'),40);
  }

  // Unused detection.
  //  agentgateway: config (route/backend/policy) not reachable from any Gateway — undirected,
  //    since policies point AT what they attach to.
  //  kagent: config no Agent (or SandboxTemplate) reaches by following references outward —
  //    directed, so an unused template that points at a used ModelConfig is still unused.
  function markOrphans(){
    var agw={}, fr=cy.nodes('[kind="Gateway"]').toArray();
    fr.forEach(function(g){agw[g.id()]=true;});
    while(fr.length){
      fr.pop().connectedEdges().filter(function(e){return !e.data('cross');}).connectedNodes().forEach(function(m){
        if(!agw[m.id()]&&m.data('product')==='agentgateway'){agw[m.id()]=true;fr.push(m);}
      });
    }
    var kr={}; fr=cy.nodes('[kind="Agent"], [kind="SandboxAgent"], [kind="SandboxTemplate"]').toArray();
    fr.forEach(function(a){kr[a.id()]=true;});
    while(fr.length){
      fr.pop().outgoers('edge').filter(function(e){return !e.data('cross');}).targets().forEach(function(m){
        if(!kr[m.id()]){kr[m.id()]=true;fr.push(m);}
      });
    }
    var KORPH={AgentTemplate:1,Harness:1,AgentHarness:1,ModelConfig:1,RemoteMCPServer:1,MCPServer:1,WorkerPool:1};
    var groups={agentgateway:[],kagent:[]};
    cy.nodes().forEach(function(n){
      var k=n.data('kind');
      if(n.data('product')==='agentgateway'){
        if((k==='HTTPRoute'||k==='Backend'||k==='Service'||n.data('role')==='policy')&&!agw[n.id()]&&!n.data('ghost')) groups.agentgateway.push(n);
      } else if(KSIDE[n.data('product')]&&KORPH[k]&&!kr[n.id()]&&!n.data('missing')) groups.kagent.push(n);
    });
    Object.keys(groups).forEach(function(p){
      var o=groups[p]; if(!o.length) return;
      var anchor='__unused_'+p;
      cy.add({group:'nodes',data:{id:anchor,label:'⚠ unused',isUnusedAnchor:true,product:p==='kagent'?'kagent':'agentgateway'}});
      o.forEach(function(n){
        n.addClass('orphan'); n.data('orphan',true);
        cy.add({group:'edges',data:{id:'ue_'+n.id(),source:anchor,target:n.id(),rel:'unused'}});
      });
    });
  }

  function esc(s){return String(s).replace(/[&<>]/g,function(c){return{'&':'&amp;','<':'&lt;','>':'&gt;'}[c];});}
  function row(k,v){return '<tr><td class="key">'+esc(k)+'</td><td>'+v+'</td></tr>';}
  // Minimal, safe YAML syntax highlighter (best-effort colour; never breaks layout).
  function hlYaml(s){
    return esc(s).split('\n').map(function(l){
      if(/^\s*#/.test(l)) return '<span class="yc">'+l+'</span>';
      var m=l.match(/^(\s*)(- )?([^\s:][^:]*)(:)(\s*)(.*)$/);
      if(m){
        var v=m[6], vh='';
        if(v!==''){
          if(/^#/.test(v)) vh='<span class="yc">'+v+'</span>';
          else if(/^(true|false|null|~|-?\d+(\.\d+)?)$/.test(v)) vh='<span class="yn">'+v+'</span>';
          else vh='<span class="ys">'+v+'</span>';
        }
        return m[1]+(m[2]?'<span class="yd">- </span>':'')+'<span class="yk">'+m[3]+'</span>'+m[4]+m[5]+vh;
      }
      var li=l.match(/^(\s*)(- )(.*)$/);
      if(li) return li[1]+'<span class="yd">- </span><span class="ys">'+li[3]+'</span>';
      return l;
    }).join('\n');
  }
  var CUR=null;  // current node's YAML {raw, clean, cleanBy}
  function loadedLabel(l){
    if(l==='true') return {cls:'ok', text:'loaded in proxy'};
    if(l==='false') return {cls:'bad', text:'not in proxy'};
    return null;
  }
  function who(n){return esc((n.data('kind')||n.data('role')||'component')+' '+n.data('name'));}
  var STRUCTURAL={manages:1,pod:1,unused:1,config:1,controllerName:1,gatewayClassName:1};
  function render(n){
    var d=n.data(), det=d.detail||{}, s=d.status||'na';
    var prod=d.product?esc(d.product)+' · ':'';
    var h='<div class="k">'+prod+esc(d.kind)+'</div><div class="name">'+esc(d.name)+'</div>';
    h+='<span class="badge '+s+'">'+(s==='ok'?'✓ active':s==='bad'?'✗ inactive':'—')+'</span>';
    var ld=loadedLabel(d.loaded);
    if(ld) h+='<span class="badge '+ld.cls+'">'+ld.text+'</span>';
    if(d.orphan) h+='<div class="hint" style="color:#ffb454;margin-top:6px">⚠ unused — '
      +(KSIDE[d.product]?'no Agent references this (applied, but nothing uses it)':'not reachable from any Gateway (applied, but not wired in)')+'</div>';
    if(d.ghost||d.missing) h+='<div class="hint" style="margin-top:6px">'+(D.fileMode?'Referenced, but not in this input.':'Referenced, but not in the cluster.')+'</div>';
    if(n.hasClass('bridge')) h+='<div class="hint" style="margin-top:6px">shown from the '+esc(side(d.product))+' side because a cross-product edge reaches it — switch to “all” for its full context</div>';
    if(d.loaded==='false' && s==='ok')
      h+='<div class="hint" style="color:#ffb454;margin-top:6px">⚠ CR status is active but this resource is not in the proxy /config_dump</div>';
    h+='<table>'+row('namespace',esc(d.ns||'-'));
    if(d.loaded && d.loaded!=='na')
      h+=row('loaded in proxy', d.loaded==='true'?'yes':'no');
    Object.keys(det).forEach(function(k){
      var v=det[k]; if(v==null) return;
      if(Array.isArray(v)) v=v.length?v.map(esc).join('<br>'):'—';
      else v=esc(v===''?'—':v);
      h+=row(k,v);
    });
    // who points at this node (excluding structural control-plane edges)
    var refs=n.incomers('edge').filter(function(e){return !STRUCTURAL[e.data('rel')];});
    if(refs.length&&d.kind!=='Gateway'){
      var total=0, by=[];
      refs.forEach(function(e){
        var count=Number(e.data('refCount')||1), rel=e.data('relation')||e.data('rel');
        total+=count;
        by.push(who(e.source())+' — '+esc(rel+(count>1?' ×'+count:'')));
      });
      h+=row('references',esc(total));
      h+=row('referenced by',by.join('<br>'));
    }
    var cross=n.outgoers('edge').filter(function(e){return e.data('cross');});
    if(cross.length) h+=row('cross-product',cross.map(function(e){return esc(e.data('rel'))+' → '+who(e.target());}).join('<br>'));
    h+='</table>';
    if(D.fileMode){
      if(!d.ghost && d.origin) h+='<div class="k">source</div><pre id="kc">'+esc(d.origin)+'</pre>';
    }else{
      h+='<div class="k">kubectl</div><pre id="kc">'+esc(d.kubectl)+'</pre>';
      h+='<button onclick="solomogCopy(\'kc\')">Copy kubectl</button><div class="hint" id="cpm"></div>';
    }
    CUR=(window.SOLOMOG_YAML||{})[d.id]||null;
    if(CUR){
      h+='<div class="tabs">'
        +'<button class="tab active" id="tab-clean" onclick="solomogTab(\'clean\')">clean</button>'
        +'<button class="tab" id="tab-raw" onclick="solomogTab(\'raw\')">raw</button>'
        +'<button class="tab mini" onclick="solomogCopy(\'yaml\')">copy YAML</button></div>';
      h+='<pre class="yaml" id="yaml"></pre><div class="hint" id="ypm"></div>';
    }
    document.getElementById('detail').innerHTML=h;
    if(CUR) solomogTab('clean');
  }
  function renderDump(){
    var s=DUMP.summary||{}, gws=DUMP.gateways||{}, keys=Object.keys(gws);
    var h='<div class="k">proxy config_dump</div><div class="name">runtime snapshot</div>';
    if(!keys.length){
      h+='<div class="empty">No /config_dump fetched (no agentgateway, DUMP=false, or admin :15000 unreachable). Version may still come from the image tag.</div>';
      if(D.version) h+='<table>'+row('version',esc(D.version))
        +row('source',esc(D.versionSource||'—'))+'</table>';
      document.getElementById('detail').innerHTML=h;
      return;
    }
    h+='<table>'
      +row('version',esc(DUMP.version||D.version||'—'))
      +row('source',esc(DUMP.versionSource||D.versionSource||'—'))
      +(DUMP.gitRevision?row('git revision',esc(DUMP.gitRevision)):'')
      +row('gateways dumped',esc(String(s.gateways!=null?s.gateways:keys.length)))
      +row('binds',esc(String(s.binds!=null?s.binds:0)))
      +row('routes (in binds)',esc(String(s.routes!=null?s.routes:0)))
      +row('backends',esc(String(s.backends!=null?s.backends:0)))
      +row('policies',esc(String(s.policies!=null?s.policies:0)))
      +'</table>';
    h+='<div class="k">gateways</div><pre>'+esc(keys.join('\n'))+'</pre>';
    h+='<button id="dl-dump">Download JSON</button><div class="hint" id="dpm"></div>';
    h+='<div class="hint" style="margin-top:10px">CR graph is primary; dump marks which routes/backends/policies the proxy actually loaded.</div>';
    document.getElementById('detail').innerHTML=h;
    document.getElementById('dl-dump').onclick=function(){
      try{
        var blob=new Blob([JSON.stringify(DUMP,null,2)],{type:'application/json'});
        var a=document.createElement('a');
        a.href=URL.createObjectURL(blob);
        a.download='solomog-config_dump-'+(D.cluster||'cluster')+'.json';
        document.body.appendChild(a); a.click(); document.body.removeChild(a);
        setTimeout(function(){URL.revokeObjectURL(a.href);},1000);
        document.getElementById('dpm').innerText='download started ✓';
      }catch(e){ document.getElementById('dpm').innerText='download failed'; }
    };
  }
  window.solomogTab=function(which){
    if(!CUR)return;
    var txt=which==='raw'?CUR.raw:(CUR.clean||CUR.raw);
    document.getElementById('yaml').innerHTML=hlYaml(txt||'(empty)');
    var tc=document.getElementById('tab-clean'), tr=document.getElementById('tab-raw');
    tc.className='tab'+(which==='clean'?' active':''); tr.className='tab'+(which==='raw'?' active':'');
    document.getElementById('ypm').innerText = which==='clean'
      ? (CUR.clean?('cleaned via '+CUR.cleanBy+' — ready to apply/bundle'):('clean unavailable — showing raw'))
      : 'full manifest as fetched';
  };
  window.solomogCopy=function(id){
    id=id||'kc';
    var el=document.getElementById(id); if(!el)return;
    var t=el.innerText, m=document.getElementById(id==='yaml'?'ypm':'cpm');
    function done(msg){ if(m) m.innerText=msg; }
    function fallback(){  // works from file:// where navigator.clipboard may be unavailable
      try{var ta=document.createElement('textarea');ta.value=t;ta.style.position='fixed';ta.style.opacity='0';
        document.body.appendChild(ta);ta.select();var ok=document.execCommand('copy');document.body.removeChild(ta);
        done(ok?'copied ✓':'press ⌘C to copy');}catch(e){done('press ⌘C to copy');}
    }
    if(navigator.clipboard&&navigator.clipboard.writeText){
      navigator.clipboard.writeText(t).then(function(){done('copied ✓');},fallback);
    }else fallback();
  };
  cy.on('tap','node',function(e){ if(e.target.data('isUnusedAnchor'))return; render(e.target); });
  var EMPTY='<div class="empty">Click a node to inspect it'+((SIDES.agentgateway&&!D.fileMode)?', or open the dump panel.':'.')+'</div>';
  document.getElementById('detail').innerHTML=EMPTY;
  cy.on('tap',function(e){if(e.target===cy){document.getElementById('detail').innerHTML=EMPTY;}});
  document.getElementById('show-dump').addEventListener('click',function(){cy.nodes().unselect();renderDump();});

  // legend — only the kinds in the current view, each with its canvas SHAPE + fill colour; then
  // the plane grouping the colours encode; then status as a ring (status is the node BORDER).
  var ORDER=['Gateway','GatewayClass','Deployment','Pod','HTTPRoute','Backend','Service','Policy',
    'Agent','SandboxAgent','AgentTemplate','Harness','AgentHarness','SandboxTemplate','ModelConfig','ModelProviderConfig',
    'RemoteMCPServer','MCPServer','WorkerPool','SandboxConfig','EnterpriseKagentRBACPolicy'];
  function sw(shape,color){return '<i class="'+shape+'" style="background:'+color+'"></i>';}
  function ring(color){return '<i class="ring" style="border-color:'+color+'"></i>';}
  function renderLegend(){
    var present={}, hasCross=false, hasMissing=false;
    cy.nodes(':visible').forEach(function(n){
      if(n.data('isUnusedAnchor')) return;
      present[n.data('role')==='policy'?'Policy':n.data('kind')]=true;
      if(n.data('missing')||n.data('ghost')) hasMissing=true;
    });
    hasCross=cy.edges('[?cross]').filter(':visible').length>0;
    var kinds=ORDER.filter(function(k){return present[k];});
    var h=kinds.map(function(k){return '<span>'+sw(SHAPE[k]||'ellipse',COLOR[k]||'#9fb0d0')+k+'</span>';}).join('')
      +'<br><b style="color:#8a97b0">planes:</b> '
      +'<span>'+sw('rrect',COLOR.Gateway)+'data (Gateway, Pod)</span>'
      +'<span>'+sw('rrect',COLOR.Deployment)+'control (Deployment)</span>'
      +'<span>'+sw('tag',COLOR.GatewayClass)+'class</span>'
      +'<br><b style="color:#8a97b0">status (border):</b> '
      +'<span>'+ring('#3fe08f')+'active</span><span>'+ring('#ff5f7a')+'inactive</span>'
      +'<span><i class="ring dash" style="border-color:#ffb454"></i>unused</span>'
      +(hasMissing?'<span><i class="ring dash" style="border-color:#9fb0d0"></i>'+(D.fileMode?'not in this input':'not in the cluster')+'</span>':'')
      +'<br><b style="color:#8a97b0">edges:</b> ×N + thicker line = repeated use'
      +(hasCross?' · <span style="color:#ff9e64">- - cross-product traffic</span>':'');
    document.getElementById('legend').innerHTML=h;
  }

  // view switch — only when both sides have something to show
  function setView(v){
    STATE.view=v;
    Array.prototype.forEach.call(document.querySelectorAll('#views button'),function(b){
      b.className=b.getAttribute('data-view')===v?'on':'';
    });
    applyVisibility(); relayout();
  }
  // One button per product side that is actually on the cluster (plus "all" when there are
  // two or more) — an agentgateway-only graph never advertises an empty kagent view. Future
  // sides (kgateway, istio) slot in here.
  var VIEWS=[
    {id:'agentgateway',label:'agentgateway'},
    {id:'kagent',label:PRODUCTS.kagent?(PRODUCTS.substrate?'kagent · substrate':'kagent'):'substrate'}
  ].filter(function(v){return SIDES[v.id];});
  if(VIEWS.length>1){
    VIEWS.push({id:'all',label:'all'});
    document.getElementById('views').innerHTML='view '+VIEWS.map(function(v){
      return '<button data-view="'+v.id+'"'+(v.id===STATE.view?' class="on"':'')+'>'+esc(v.label)+'</button>';
    }).join('');
    Array.prototype.forEach.call(document.querySelectorAll('#views button'),function(b){
      b.addEventListener('click',function(){setView(b.getAttribute('data-view'));});
    });
  } else document.getElementById('views').style.display='none';
  if(!SIDES.agentgateway || D.fileMode) document.getElementById('show-dump').style.display='none';

  // A file render with no Gateway would hide every route behind the unused toggle.
  if(D.fileMode){
    var realGw=0;
    cy.nodes('[kind="Gateway"]').forEach(function(n){ if(!n.data('ghost')) realGw++; });
    if(!realGw){ STATE.unused=true; document.getElementById('unused').checked=true; }
  }

  // controls
  document.getElementById('unused').addEventListener('change',function(e){STATE.unused=e.target.checked;applyVisibility();relayout();});
  document.getElementById('aux').addEventListener('change',function(e){STATE.aux=e.target.checked;applyVisibility();relayout();});
  document.getElementById('relayout').addEventListener('click',relayout);
  markOrphans();      // flag + cluster config nothing uses
  applyVisibility();  // unused config + aux control-plane services hidden by default
  relayout();
  // deep-link: opening #<node-id> selects that node (shareable link to a resource's panel)
  function pickFromHash(){
    var id=decodeURIComponent((location.hash||'').slice(1));if(!id)return;
    if(id==='dump'){renderDump();return;}
    var n=cy.getElementById(id);
    if(n&&n.length){
      var changed=false;
      if(n.data('orphan')&&!STATE.unused){document.getElementById('unused').checked=true;STATE.unused=true;changed=true;}
      if(n.data('aux')&&!STATE.aux){document.getElementById('aux').checked=true;STATE.aux=true;changed=true;}
      if(STATE.view!=='all'&&side(n.data('product'))!==STATE.view){setView('all');changed=false;}
      if(changed){applyVisibility();relayout();}
      render(n);n.select();
    }
  }
  window.addEventListener('hashchange',pickFromHash); pickFromHash();
  // resizable side panel — drag the grip; cy re-fits its canvas to the new width
  var grip=document.getElementById('grip'), sidep=document.getElementById('side'), dragging=false;
  grip.addEventListener('mousedown',function(e){dragging=true;grip.classList.add('drag');document.body.style.userSelect='none';e.preventDefault();});
  window.addEventListener('mousemove',function(e){
    if(!dragging)return;
    var w=Math.max(300,Math.min(window.innerWidth-e.clientX-3, window.innerWidth*0.88));
    sidep.style.flexBasis=w+'px'; cy.resize();
  });
  window.addEventListener('mouseup',function(){if(dragging){dragging=false;grip.classList.remove('drag');document.body.style.userSelect='';cy.resize();}});
})();
APPJS
  echo '</script></body></html>'
} > "$OUT"

echo "    HTML → ${OUT}  ($(wc -c < "$OUT" | tr -d ' ') bytes)"

# ── Open / serve. ───────────────────────────────────────────────────────────
# The HTML is fully self-contained, so by DEFAULT we just open the file — the task then
# exits cleanly with nothing to stop. OPEN=false just writes it. SERVE=true runs a local
# http server instead (localhost is a secure context → native clipboard copy); stop that
# one with Enter for a clean exit (Ctrl-C signals the whole `task` chain → reported as a
# failure, which is exactly the non-error-that-looks-like-an-error to avoid).
OPEN="${OPEN:-true}"

if [ "$SERVE" != "true" ]; then
  if [ "$OPEN" = "true" ] && command -v open >/dev/null 2>&1; then
    open "$OUT" 2>/dev/null || true
    echo "✓ opened in your browser: ${OUT}"
  else
    echo "✓ graph written: ${OUT}"
    echo "  open it:  open \"$OUT\""
  fi
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 not found — opening the file directly instead." >&2
  command -v open >/dev/null 2>&1 && open "$OUT" 2>/dev/null || echo "  open \"$OUT\""
  exit 0
fi
PORT="${PORT:-$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()' 2>/dev/null || echo 8765)}"
DIR="$(dirname "$OUT")"; FILE="$(basename "$OUT")"
URL="http://127.0.0.1:${PORT}/${FILE}"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$DIR" >/dev/null 2>&1 &
SRV=$!
cleanup() { kill "$SRV" 2>/dev/null || true; }
trap 'cleanup' EXIT
trap 'echo; cleanup; echo "✓ graph server stopped."; exit 0' INT TERM   # Ctrl-C: best-effort clean
[ "$OPEN" = "true" ] && command -v open >/dev/null 2>&1 && open "$URL" 2>/dev/null || true
echo "✓ serving at ${URL}"
if [ -t 0 ]; then
  printf '  Press Enter to stop the server and finish.\n'
  read -r _ || true          # clean exit — no signal, so `task`/wrapper see success
else
  echo "  (Ctrl-C to stop)"; wait "$SRV" 2>/dev/null || true
fi
cleanup
echo "✓ graph server stopped."
exit 0
