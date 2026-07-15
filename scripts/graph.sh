#!/usr/bin/env bash
set -euo pipefail
#
# graph.sh — `solomog graph`. Snapshots a cluster's agentgateway configuration and
# renders it as an interactive, self-contained HTML graph you explore in a browser:
# Gateway (data plane) + control-plane deployment + pods → HTTPRoutes → Backends →
# Policies, with Gateway-API edges (parentRef / backendRef / targetRef). Click any node
# for its details and a copy-paste `kubectl` command.
#
# The relationship model is the same one `routes` computes (kubectl + jq); this just emits
# it as Cytoscape.js elements, inlines them + the vendored graph lib into ONE HTML file
# (self-contained → works offline, shareable, could drop into an `export`), then serves it
# on an ephemeral local port and opens a browser tab.
#
# Usage: graph.sh <cluster>
# Env:
#   OPEN    true|false (default true) — open the generated HTML in a browser
#   SERVE   true (default false) — serve on a local port (Enter to stop) instead of just
#           opening the self-contained file. localhost gives native clipboard copy.
#   OUT     output HTML path (default .solomog/graph/<cluster>-<ts>.html)
#   PORT    serve port, SERVE=true only (default: an ephemeral free port)

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_DIR/scripts/lib/gateway.sh"

CLUSTER="${1:?Usage: graph.sh <cluster>}"
CTX="vcluster-docker_$CLUSTER"
SERVE="${SERVE:-false}"
TS="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo graph)"
OUT="${OUT:-$REPO_DIR/.solomog/graph/${CLUSTER}-${TS}.html}"
CYTO="$REPO_DIR/scripts/lib/graph/cytoscape.min.js"

if ! kubectl --context "$CTX" get gatewayclass >/dev/null 2>&1; then
  echo "Error: can't reach context '$CTX' (is cluster '$CLUSTER' up?)." >&2
  exit 1
fi
[ -f "$CYTO" ] || { echo "Error: vendored graph lib missing: $CYTO" >&2; exit 1; }

# Sanitize raw C0 control bytes (live controllers sometimes write an unescaped newline into
# a status field → invalid JSON → jq bails). Lossless: valid JSON escapes control chars.
_items() {
  local out
  out="$(kubectl --context "$CTX" get "$1" -A -o json 2>/dev/null | LC_ALL=C tr -d '\000-\037')"
  case "$out" in '') echo '[]' ;; *) printf '%s' "$out" | jq '[.items[]?]' ;; esac
}
# Merge a CRD's items, tagging each with its full resource type (for kubectl hints).
_tagged() { _items "$1" | jq --arg t "$1" 'map(. + {_rtype:$t})'; }

echo "==> Snapshotting agentgateway config on '${CLUSTER}'"
GW="$(_items gateways.gateway.networking.k8s.io)"
RT="$(_items httproutes.gateway.networking.k8s.io)"
POL="$(jq -s 'add' <(_tagged enterpriseagentgatewaypolicies.enterpriseagentgateway.solo.io) <(_tagged agentgatewaypolicies.agentgateway.dev))"
BE="$(jq -s 'add' <(_tagged enterpriseagentgatewaybackends.enterpriseagentgateway.solo.io) <(_tagged agentgatewaybackends.agentgateway.dev))"
PODS="$(_items pods)"
DEPS="$(_items deployments.apps)"
GC="$(_items gatewayclasses.gateway.networking.k8s.io)"

GWNAMES="$(echo "$GW" | jq -r '[.[]|select(.spec.gatewayClassName|test("agentgateway"))|.metadata.name]|join(",")')"
if [ -z "$GWNAMES" ]; then
  echo "No agentgateway Gateways on '${CLUSTER}' — nothing to graph." >&2
  exit 0
fi
EDITION="community"; echo "$GW" | jq -e '.[]|select(.spec.gatewayClassName=="enterprise-agentgateway")' >/dev/null 2>&1 && EDITION="enterprise"

# ── Build Cytoscape elements (nodes + edges) from the snapshot. ─────────────────
DATA="$(jq -cn \
  --argjson gw "$GW" --argjson rt "$RT" --argjson pol "$POL" --argjson be "$BE" \
  --argjson pods "$PODS" --argjson deps "$DEPS" --argjson gc "$GC" --arg cluster "$CLUSTER" --arg edition "$EDITION" '
  def cond(t): [.status.conditions[]?|select(.type==t).status];
  def stat(t): cond(t) as $c | if ($c|length)==0 then "na" elif ($c|all(.=="True")) then "ok" else "bad" end;
  def rstat:
    ([.status.parents[]?.conditions[]?|select(.type=="Accepted").status]) as $a
    | ([.status.parents[]?.conditions[]?|select(.type=="ResolvedRefs").status]) as $r
    | if ($a|length)==0 then "na" elif (($a|all(.=="True")) and ($r|all(.=="True"))) then "ok" else "bad" end;
  # Policies use the Gateway-API GEP-713 PolicyStatus shape: conditions live under
  # .status.ancestors[].conditions[] (Accepted + Attached), NOT .status.conditions.
  def pconds: [.status.ancestors[]?.conditions[]?];
  def pstat: pconds as $c | if ($c|length)==0 then "na" elif ($c|any(.status!="True")) then "bad" else "ok" end;

  ($gw | map(select(.spec.gatewayClassName|test("agentgateway")))) as $gws
  | ($gws | map(.metadata.name)) as $gwnames
  | ($gwnames[0] // "agw") as $gw0

  # Backends: union of CR backends + route backendRefs + policy backendRefs, deduped by ns/name.
  # CR entries are concatenated LAST so their fields (cr/type/_rtype) win on merge.
  | ([ ($rt[] | .metadata.namespace as $rns | .spec.rules[]?.backendRefs[]?
         | {key:((.namespace // $rns)+"/"+.name), ns:(.namespace // $rns), name:.name, cr:false}),
       ($pol[] | .metadata.namespace as $pns
         | [paths(scalars) as $p | select($p[-1]=="name" and ($p|index("backendRef"))) | getpath($p)][]
         | {key:($pns+"/"+.), ns:$pns, name:., cr:false}),
       ($be[] | {key:(.metadata.namespace+"/"+.metadata.name), ns:.metadata.namespace, name:.metadata.name,
                 cr:true, btype:((.spec|keys|map(select(.!="policies"))|first)//"?"), rtype:._rtype,
                 status:stat("Accepted"), conds:[.status.conditions[]?|(.type+"="+.status)]}) ]
     | group_by(.key) | map(add)) as $backends

  # control-plane deployments (enterprise-agentgateway + its sidecar services)
  | ($deps | map(select(.metadata.name=="enterprise-agentgateway" or (.metadata.name|endswith("-enterprise-agentgateway"))))) as $cp
  # GatewayClass(es) the agentgateway Gateways reference
  | ($gws | map(.spec.gatewayClassName) | unique) as $classes
  # is the core control plane present? (drives the control-plane compound + its edges)
  | ($cp | any(.metadata.name=="enterprise-agentgateway")) as $hasCP

  | {
      cluster:$cluster, edition:$edition, gateways:$gwnames,
      elements: (
        # ── Gateway nodes (data plane) ──
        [ $gws[] | {data:{
            id:("gateway:"+.metadata.namespace+"/"+.metadata.name), label:.metadata.name,
            kind:"Gateway", role:"dataplane", plane:"data", ns:.metadata.namespace, name:.metadata.name,
            status:stat("Programmed"), rtype:"gateway",
            kubectl:("kubectl get gateway "+.metadata.name+" -n "+.metadata.namespace+" -o yaml"),
            detail:{ class:.spec.gatewayClassName, address:(.status.addresses[0].value//"-"),
                     listeners:[.spec.listeners[]|(.protocol+"/"+(.port|tostring)+" ("+(.hostname//"*")+")")],
                     conditions:[.status.conditions[]?|(.type+"="+.status)] } }} ]

        # ── Control-plane deployment nodes (control plane) ──
        + [ $cp[] | {data:{
            id:("deploy:"+.metadata.namespace+"/"+.metadata.name), label:.metadata.name,
            kind:"Deployment", role:"controlplane", plane:"control", ns:.metadata.namespace, name:.metadata.name,
            aux:(.metadata.name != "enterprise-agentgateway"),
            status:(if (.status.readyReplicas//0)==(.status.replicas//0) and (.status.replicas//0)>0 then "ok" else "bad" end),
            rtype:"deploy",
            kubectl:("kubectl get deploy "+.metadata.name+" -n "+.metadata.namespace+" -o yaml"),
            detail:{ ready:((.status.readyReplicas//0|tostring)+"/"+(.status.replicas//0|tostring)) } }} ]

        # ── GatewayClass node(s) + the real chain: ──
        #   Gateway --gatewayClassName--> GatewayClass --controllerName--> control plane --manages--> Gateway
        + [ $classes[] as $cn | ($gc[]|select(.metadata.name==$cn)) as $gcx | {data:{
            id:("gatewayclass:"+$cn), label:$cn, kind:"GatewayClass", role:"class", name:$cn, ns:"(cluster-scoped)",
            status:( [$gcx.status.conditions[]?|select(.type=="Accepted").status] as $c
                     | if ($c|length)==0 then "na" elif ($c|all(.=="True")) then "ok" else "bad" end ),
            rtype:"gatewayclass", kubectl:("kubectl get gatewayclass "+$cn+" -o yaml"),
            detail:{ controllerName:($gcx.spec.controllerName//"-"),
                     conditions:[$gcx.status.conditions[]?|(.type+"="+.status)] } }} ]
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
            status:(if .status.phase=="Running" then "ok" else "bad" end), rtype:"pod",
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
            kubectl:("kubectl get httproute "+.metadata.name+" -n "+.metadata.namespace+" -o yaml"),
            detail:{ hostnames:([.spec.hostnames[]?]|if length==0 then ["*"] else . end),
                     paths:([.spec.rules[]?.matches[]?.path.value]|unique|map(select(.!=null))),
                     conditions:[.status.parents[]?.conditions[]?|(.type+"="+.status)] } }} ]
        + [ $rt[] | .metadata.namespace as $rns | .metadata.name as $rn
            | .spec.parentRefs[]? | select(.name as $p | $gwnames|index($p))
            | {data:{ id:("e:parent:"+$rns+":"+$rn+":"+.name), source:("httproute:"+$rns+"/"+$rn),
                      target:("gateway:"+((.namespace)//$rns)+"/"+.name), rel:"parentRef" }} ]

        # ── Backend nodes + backendRef edges from routes ──
        + [ $backends[] | {data:{
            id:("backend:"+.key), label:.name, kind:"Backend",
            role:(if .cr then "backend" else "external" end), ns:.ns, name:.name,
            status:(.status // "na"), rtype:(.rtype // "service"),
            kubectl:(if .cr then ("kubectl get "+(.rtype)+" "+.name+" -n "+.ns+" -o yaml")
                     else ("kubectl get service "+.name+" -n "+.ns+" -o yaml  # or a backend CR") end),
            detail:{ type:(.btype // "-"), declared:(if .cr then "CR" else "route ref (Service?)" end),
                     conditions:(.conds // []) } }} ]
        + [ $rt[] | .metadata.namespace as $rns | .metadata.name as $rn
            | .spec.rules[]?.backendRefs[]?
            | {data:{ id:("e:be:"+$rns+":"+$rn+":"+.name), source:("httproute:"+$rns+"/"+$rn),
                      target:("backend:"+((.namespace)//$rns)+"/"+.name), rel:"backendRef" }} ]

        # ── Policy nodes + targetRef edges + backendRef (jwks) edges ──
        + [ $pol[] | {data:{
            id:("policy:"+.metadata.namespace+"/"+.metadata.name), label:.metadata.name,
            kind:.kind, role:"policy", ns:.metadata.namespace, name:.metadata.name,
            status:pstat, rtype:._rtype,
            kubectl:("kubectl get "+._rtype+" "+.metadata.name+" -n "+.metadata.namespace+" -o yaml"),
            detail:{ targets:[.spec.targetRefs[]?|(.kind+"/"+.name)],
                     conditions:(( [pconds[] | .type+"="+.status+(if .status!="True" then " — "+(.reason//"")+": "+(.message//"") else "" end)] )
                                 | if length==0 then ["(none reported)"] else . end) } }} ]
        + [ $pol[] | .metadata.namespace as $pns | .metadata.name as $pn
            | .spec.targetRefs[]?
            | {data:{ id:("e:target:"+$pns+":"+$pn+":"+.kind+":"+.name), source:("policy:"+$pns+"/"+$pn),
                      target:((if .kind=="Gateway" then "gateway:" elif .kind=="HTTPRoute" then "httproute:" elif (.kind|test("Backend")) then "backend:" else "unknown:" end)+$pns+"/"+.name),
                      rel:"targetRef" }} ]
        + [ $pol[] | .metadata.namespace as $pns | .metadata.name as $pn
            | [paths(scalars) as $p | select($p[-1]=="name" and ($p|index("backendRef"))) | getpath($p)][]
            | {data:{ id:("e:polbe:"+$pns+":"+$pn+":"+.), source:("policy:"+$pns+"/"+$pn),
                      target:("backend:"+$pns+"/"+.), rel:"uses" }} ]
      )
    }')"

NODE_N="$(printf '%s' "$DATA" | jq '[.elements[]|select(.data.source|not)]|length')"
EDGE_N="$(printf '%s' "$DATA" | jq '[.elements[]|select(.data.source)]|length')"
echo "    ${NODE_N} node(s), ${EDGE_N} edge(s)  (edition=${EDITION}, gateways=${GWNAMES})"

# Prune edges whose endpoints don't exist (e.g. a backendRef to a Service we didn't node-ify
# as a CR still has a node; but a stray targetRef to a missing route would dangle). Keeps
# Cytoscape from erroring on edges with unknown source/target.
DATA="$(printf '%s' "$DATA" | jq '
  ([.elements[]|select(.data.source|not)|.data.id]) as $ids
  | .elements |= map(
      (.data.source) as $s | (.data.target) as $t
      | select(($s|not) or (($ids|index($s)) and ($ids|index($t)))))')"

# ── Per-node manifests → inlined YAML (raw + cleaned). We already fetched every object, so
# map each node id to its full object, then render two YAML views: the raw manifest and a
# cleaned one for copy/paste into a new cluster/bundle (kubectl-neat if installed, else a
# built-in strip of server-managed fields). All done at generate time — no extra cluster calls.
MANIFESTS="$(jq -n --argjson data "$DATA" --argjson gws "$GW" --argjson rts "$RT" --argjson gcs "$GC" \
  --argjson deps "$DEPS" --argjson pods "$PODS" --argjson bes "$BE" --argjson pols "$POL" '
  ($data.elements | map(select(.data.source|not) | .data)) as $nodes
  | reduce $nodes[] as $n ({};
      ($n.rtype) as $k | ($n.ns) as $ns | ($n.name) as $nm | ($n.id) as $id
      | (( if   $k=="gateway"      then first($gws[]|select(.metadata.namespace==$ns and .metadata.name==$nm))
           elif $k=="httproute"    then first($rts[]|select(.metadata.namespace==$ns and .metadata.name==$nm))
           elif $k=="gatewayclass" then first($gcs[]|select(.metadata.name==$nm))
           elif $k=="deploy"       then first($deps[]|select(.metadata.namespace==$ns and .metadata.name==$nm))
           elif $k=="pod"          then first($pods[]|select(.metadata.namespace==$ns and .metadata.name==$nm))
           elif ($k|test("backend")) then first($bes[]|select(.metadata.namespace==$ns and .metadata.name==$nm))
           elif ($k|test("polic"))   then first($pols[]|select(.metadata.namespace==$ns and .metadata.name==$nm))
           else null end ) // null ) as $obj
      | if $obj != null then .[$id]=($obj | del(._rtype)) else . end)')"

RAW_YAML="$(printf '%s' "$MANIFESTS" | ruby -ryaml -rjson -e 'h=JSON.parse(STDIN.read);print JSON.generate(h.transform_values{|v| YAML.dump(v)})' 2>/dev/null || echo '{}')"
if command -v kubectl-neat >/dev/null 2>&1; then
  CLEAN_BY="kubectl-neat"
  CLEAN_YAML="{}"
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    cy="$(printf '%s' "$MANIFESTS" | jq -c --arg k "$id" '.[$k]' | kubectl-neat -f - -o yaml 2>/dev/null || true)"
    CLEAN_YAML="$(printf '%s' "$CLEAN_YAML" | jq --arg k "$id" --arg v "$cy" '.[$k]=$v')"
  done <<EOF
$(printf '%s' "$MANIFESTS" | jq -r 'keys[]')
EOF
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
  .badge{display:inline-block;padding:1px 8px;border-radius:10px;font-size:11px;font-weight:600}
  .ok{background:#153a25;color:#5fe3a1} .bad{background:#42121a;color:#ff8098} .na{background:#26314a;color:#9fb0d0}
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
  #controls{position:fixed;left:12px;top:12px;background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:8px 12px;font-size:12px;color:var(--dim);display:flex;gap:14px;align-items:center}
  #controls label{cursor:pointer;user-select:none} #controls input{vertical-align:middle;margin-right:5px}
  #controls button{background:transparent;color:var(--accent);border:1px solid var(--line);border-radius:6px;padding:3px 9px;font-size:12px}
</style></head><body><div id="wrap"><div id="cy"></div>
<div id="grip" title="drag to resize"></div>
<div id="side"><h1>solomog graph</h1><div class="sub">cluster ${CLUSTER} · agentgateway (${EDITION})</div>
<div id="detail"><div class="empty">Click a node to inspect it.</div></div></div></div>
<div id="controls">
  <label><input type="checkbox" id="aux"> control-plane services</label>
  <button id="relayout">re-layout</button>
</div>
<div id="legend"></div>
<script>
HTMLHEAD
  cat "$CYTO"
  echo '</script><script>'
  printf 'window.SOLOMOG_DATA=%s;\n' "$DATA"
  printf 'window.SOLOMOG_YAML=%s;\n' "$YAML_MAP"
  cat <<'APPJS'
(function(){
  var D=window.SOLOMOG_DATA;
  var COLOR={Gateway:'#7aa2ff',Deployment:'#c792ea',Pod:'#82aaff',HTTPRoute:'#5fe3a1',Backend:'#ffcb6b',Policy:'#f78c6c',GatewayClass:'#80cbc4'};
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
      {selector:'node[kind="GatewayClass"]',style:{'shape':'round-tag','width':34,'height':26}},
      // policies' kind is the CR kind (EnterpriseAgentgatewayPolicy / AgentgatewayPolicy),
      // not "Policy", so the kind→COLOR lookup misses — set their fill by role instead.
      {selector:'node[role="policy"]',style:{'shape':'hexagon','background-color':'#f78c6c'}},
      // orphaned config (not reachable from any Gateway) + the anchor it clusters under
      {selector:'node.orphan',style:{'border-color':'#ffb454','border-style':'dashed','border-width':3}},
      {selector:'node[?isAnchor]',style:{'shape':'round-rectangle','background-color':'#ffb454','background-opacity':0.15,
        'border-color':'#ffb454','border-width':1,'border-style':'dashed','width':18,'height':18,
        'label':'data(label)','color':'#ffb454','font-size':11,'text-valign':'bottom','text-margin-y':4}},
      {selector:'edge[rel="unattached"]',style:{'line-style':'dashed','line-color':'#7a5a2a','target-arrow-shape':'none','width':1}},
      {selector:'node:selected',style:{'border-color':'#fff','border-width':4}},
      {selector:'edge',style:{
        'label':'data(rel)','font-size':8,'color':'#8a97b0','text-background-color':'#0f1420','text-background-opacity':1,
        'width':1.5,'line-color':'#39435c','target-arrow-color':'#39435c',
        'target-arrow-shape':'triangle','curve-style':'bezier','arrow-scale':.8}},
      {selector:'edge[rel="manages"]',style:{'line-style':'dashed','line-color':'#c792ea','target-arrow-color':'#c792ea'}},
      {selector:'edge[rel="controllerName"]',style:{'line-style':'dashed','line-color':'#80cbc4','target-arrow-color':'#80cbc4'}},
      {selector:'edge[rel="gatewayClassName"]',style:{'line-color':'#80cbc4','target-arrow-color':'#80cbc4'}},
      {selector:'edge[rel="pod"]',style:{'line-style':'dotted'}}
    ],
    layout:{name:'grid'}
  });
  // Hierarchical layout rooted at the Gateway(s); operates on visible elements only so a
  // hidden group doesn't leave gaps. Called on load and after any show/hide.
  function relayout(){
    var vis=cy.elements(':visible');
    vis.layout({name:'breadthfirst',directed:false,
      roots:cy.$('node[kind="Gateway"], node[?isAnchor]').filter(':visible'),
      spacingFactor:1.3,padding:30,avoidOverlap:true,animate:false}).run();
    cy.fit(vis,40);
  }
  // Orphan detection: config (route/backend/policy) not reachable from any Gateway is
  // "unattached" — the applied-but-not-wired-in case. Flag it and cluster it under a
  // labelled anchor so it's obvious instead of a lone node drifting at the edge.
  function markOrphans(){
    var reached={}, frontier=cy.nodes('[kind="Gateway"]').toArray();
    frontier.forEach(function(g){reached[g.id()]=true;});
    while(frontier.length){
      frontier.pop().connectedEdges().connectedNodes().forEach(function(m){
        if(!reached[m.id()]){reached[m.id()]=true;frontier.push(m);}
      });
    }
    var orphans=cy.nodes().filter(function(n){
      var k=n.data('kind');
      return (k==='HTTPRoute'||k==='Backend'||n.data('role')==='policy') && !reached[n.id()];
    });
    if(!orphans.length) return;
    orphans.addClass('orphan'); orphans.data('orphan',true);
    cy.add({group:'nodes',data:{id:'__unattached',label:'⚠ unattached',isAnchor:true}});
    orphans.forEach(function(n){cy.add({group:'edges',data:{id:'oe_'+n.id(),source:'__unattached',target:n.id(),rel:'unattached'}});});
  }
  // Toggle the auxiliary control-plane services (ext-auth / rate-limiter / waf). The core
  // control plane (enterprise-agentgateway) and the data-plane pod always stay.
  function applyAux(show){ var a=cy.nodes('[?aux]'); if(show){a.show();}else{a.hide();} }
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
  function render(n){
    var d=n.data(), det=d.detail||{}, s=d.status||'na';
    var h='<div class="k">'+esc(d.kind)+'</div><div class="name">'+esc(d.name)+'</div>';
    h+='<span class="badge '+s+'">'+(s==='ok'?'✓ active':s==='bad'?'✗ inactive':'—')+'</span>';
    if(d.orphan) h+='<div class="hint" style="color:#ffb454;margin-top:6px">⚠ unattached — not reachable from any Gateway (applied, but not wired in)</div>';
    h+='<table>'+row('namespace',esc(d.ns||'-'));
    Object.keys(det).forEach(function(k){
      var v=det[k]; if(Array.isArray(v)) v=v.length?v.map(esc).join('<br>'):'—';
      else v=esc(v==null||v===''?'—':v);
      h+=row(k,v);
    });
    h+='</table>';
    h+='<div class="k">kubectl</div><pre id="kc">'+esc(d.kubectl)+'</pre>';
    h+='<button onclick="solomogCopy(\'kc\')">Copy kubectl</button><div class="hint" id="cpm"></div>';
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
  cy.on('tap','node',function(e){ if(e.target.data('isAnchor'))return; render(e.target); });
  cy.on('tap',function(e){if(e.target===cy){document.getElementById('detail').innerHTML='<div class="empty">Click a node to inspect it.</div>';}});
  // legend — kinds shown with their canvas SHAPE + fill colour; then the plane grouping the
  // colours encode; then status as a ring (status is the node BORDER on canvas, not the fill).
  var SHAPE={Gateway:'rrect',GatewayClass:'tag',Deployment:'rrect',Pod:'ellipse',HTTPRoute:'ellipse',Backend:'diamond',Policy:'hex'};
  function sw(shape,color){return '<i class="'+shape+'" style="background:'+color+'"></i>';}
  function ring(color){return '<i class="ring" style="border-color:'+color+'"></i>';}
  var kinds=['Gateway','GatewayClass','Deployment','Pod','HTTPRoute','Backend','Policy'];
  document.getElementById('legend').innerHTML=
    kinds.map(function(k){return '<span>'+sw(SHAPE[k],COLOR[k]||'#9fb0d0')+k+'</span>';}).join('')
    +'<br><b style="color:#8a97b0">planes:</b> '
    +'<span>'+sw('rrect',COLOR.Gateway)+'data (Gateway, Pod)</span>'
    +'<span>'+sw('rrect',COLOR.Deployment)+'control (Deployment)</span>'
    +'<span>'+sw('rrect',COLOR.GatewayClass)+'class</span>'
    +'<br><b style="color:#8a97b0">status (border):</b> '
    +'<span>'+ring('#3fe08f')+'active</span><span>'+ring('#ff5f7a')+'inactive</span>'
    +'<span><i class="ring dash" style="border-color:#ffb454"></i>unattached</span>';
  // controls
  document.getElementById('aux').addEventListener('change',function(e){applyAux(e.target.checked);relayout();});
  document.getElementById('relayout').addEventListener('click',relayout);
  markOrphans();     // flag + cluster config not reachable from a Gateway
  applyAux(false);   // aux control-plane services hidden by default
  relayout();
  // deep-link: opening #<node-id> selects that node (shareable link to a resource's panel)
  function pickFromHash(){var id=decodeURIComponent((location.hash||'').slice(1));if(!id)return;var n=cy.getElementById(id);if(n&&n.length){render(n);n.select();}}
  window.addEventListener('hashchange',pickFromHash); pickFromHash();
  // resizable side panel — drag the grip; cy re-fits its canvas to the new width
  var grip=document.getElementById('grip'), side=document.getElementById('side'), dragging=false;
  grip.addEventListener('mousedown',function(e){dragging=true;grip.classList.add('drag');document.body.style.userSelect='none';e.preventDefault();});
  window.addEventListener('mousemove',function(e){
    if(!dragging)return;
    var w=Math.max(300,Math.min(window.innerWidth-e.clientX-3, window.innerWidth*0.88));
    side.style.flexBasis=w+'px'; cy.resize();
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
