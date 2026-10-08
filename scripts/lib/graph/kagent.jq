# kagent.jq — kagent + Agent Substrate elements for `solomog graph` (scripts/graph.sh).
#
# Emits {elements:[...], objs:{<node id>: <object>}} in the same Cytoscape element shape the
# agentgateway half of graph.sh builds, so both halves render on one canvas.
#
# Shape-driven, not group-driven: the same builder handles kagent 0.10 (kagent.dev/v1alpha2:
# Agent.spec.declarative / byo, SandboxAgent) and kagent 1.0 (api.kagent.dev/v1alpha3, and the
# early alphas that served v1alpha3 under kagent.dev: Agent → templateRef / harnessRef). Refs
# resolve by kind + namespace + name across whichever groups the cluster serves.
#
# Inputs (--slurpfile, so each arrives wrapped in a one-element array — large clusters blow
# past ARG_MAX with --argjson):
#   $kobjs  kagent + substrate CRs, each tagged with _rtype (full resource name)
#   $deps   all Deployments          $pods  Pods              $svcs  all Services
#   $gws    agentgateway Gateways    $rts   HTTPRoutes        $bes   agentgateway backend CRs
#
# Edge convention: source = the object that holds the reference. Cross-product edges carry
# cross:true — the page shows them in the "all" view and pulls their far end in as a bridge node.
# A ref with no target becomes a ghost node (same kind, dashed in the HTML). $fileMode and
# $honorStatus are "true"|"false" (--arg). File renders ignore .status unless honor is set.

def file_mode: $fileMode == "true";
def honor: $honorStatus == "true";

def nid: "k:" + ._rtype + ":" + (.metadata.namespace // "") + "/" + .metadata.name;
def conds: [.status.conditions[]? | select(.type != "UnsupportedFeatures")];
def kstat: if honor|not then "na" else (conds as $c
  | if ($c|length)==0 then "na" elif ($c|all(.status=="True")) then "ok" else "bad" end) end;
def condlines:
  if honor|not then ["(status not evaluated)"] else
  [.status.conditions[]? | .type + "=" + .status
     + (if .status != "True" and .type != "UnsupportedFeatures"
        then " — " + (.reason // "") + ": " + (.message // "") else "" end)] end;
def ready: if honor|not then "na" else ((.status.readyReplicas // 0) as $r | (.status.replicas // .spec.replicas // 0) as $w
  | if $w > 0 and $r == $w then "ok" else "bad" end) end;
def readytext: ((.status.readyReplicas // 0)|tostring) + "/" + ((.status.replicas // .spec.replicas // 0)|tostring);
# Pod-template labels ⊇ a Service selector → that Service fronts the Deployment.
def selects($labels): (.spec.selector // {}) as $s
  | ($s|length) > 0 and ($s | to_entries | all(.value == ($labels[.key] // null)));
def imgtag: (.spec.template.spec.containers[0].image // "") | split("@")[0] | split(":") | if length>1 then last else "" end;

$kobjs[0] as $kobjs | $deps[0] as $deps | $pods[0] as $pods | $svcs[0] as $svcs
| $gws[0] as $gws | $rts[0] as $rts | $bes[0] as $bes
| ($kobjs | map(. + {_nid: nid})) as $all

# ── kagent / substrate deployments ──────────────────────────────────────────
# Controller = the chart's controller component, or the conventional name. Agent-owned
# Deployments (0.10 runs each Declarative/BYO Agent as its own Deployment) are runtimes, not
# control plane. Substrate's control plane is ate-controller; the rest of its namespace is aux.
| ($deps | map(select(
      ((.metadata.labels["app.kubernetes.io/name"] // "") | test("^kagent"))
      and ((.metadata.labels["app.kubernetes.io/component"] // "") == "controller")
      or .metadata.name == "kagent-controller"))) as $kctl
| ($deps | map(select([.metadata.ownerReferences[]? | select(.kind=="Agent" or .kind=="SandboxAgent")] | length > 0))) as $agentdeps
| ($kctl | map(.metadata.namespace)) as $kctlns
| ($deps | map(select(
      (.metadata.namespace as $ns | $kctlns | index($ns)) != null
      and ((.metadata.name|test("^(kagent|kmcp)")) or ((.metadata.labels["app.kubernetes.io/name"] // "")|test("^(kagent|kmcp)")))
      and (.metadata.name as $n | ($kctl|map(.metadata.name)|index($n)) == null)
      and ([.metadata.ownerReferences[]? | select(.kind=="Agent" or .kind=="SandboxAgent")] | length == 0)))) as $kaux
| ($deps | map(select(.metadata.name=="ate-controller"))) as $atectl
| ($atectl | map(.metadata.namespace)) as $atens
| ($deps | map(select((.metadata.namespace as $ns | $atens | index($ns)) != null and .metadata.name != "ate-controller"))) as $ateaux

| def depnode($product; $aux; $role):
    {data:{ id:("deploy:" + .metadata.namespace + "/" + .metadata.name), label:.metadata.name,
      kind:"Deployment", role:$role, plane:"control", product:$product, aux:$aux,
      ns:.metadata.namespace, name:.metadata.name, status:ready, rtype:"deploy", loaded:"na",
      kubectl:("kubectl get deploy " + .metadata.name + " -n " + .metadata.namespace + " -o yaml"),
      detail:{ ready:readytext, image:(.spec.template.spec.containers[0].image // "-") } }};

  # Resolve a reference by kind + namespace + name. A ref with no target becomes a "missing"
  # node (a real misconfiguration worth seeing), not a silently pruned edge.
  def ref($kinds; $ns; $name):
    (first($all[] | select((.kind as $k | $kinds | index($k)) != null
                           and (.metadata.namespace // "") == $ns and .metadata.name == $name) | ._nid)
     // ("k:missing:" + $kinds[0] + ":" + $ns + "/" + $name));
  def e($src; $tgt; $rel): {data:{ id:("e:" + $src + ">" + $tgt + ">" + $rel), source:$src, target:$tgt, rel:$rel }};
  # 0.10 refs are plain strings, optionally "ns/name".
  def strref($ns): if test("/") then split("/") | {ns:.[0], name:.[1]} else {ns:$ns, name:.} end;

  def template_edges($src; $ns):
    ( (.modelConfig.name // empty) | e($src; ref(["ModelConfig"]; $ns; .); "modelConfig") ),
    ( .tools[]? | (
        (.mcp.server // empty | e($src; ref([.kind // "RemoteMCPServer"]; $ns; .name); "tool")),
        (.subAgent.templateRef.name // empty | e($src; ref(["AgentTemplate"]; $ns; .); "subAgent")) ) );
  def harness_edges($src; $ns):
    ( (.substrate.workerPoolRef.name // empty) | e($src; ref(["WorkerPool"]; $ns; .); "workerPoolRef") ),
    ( (.kagent.memory.modelConfigRef.name // empty) | e($src; ref(["ModelConfig"]; $ns; .); "memory") ),
    ( (.kagent.compaction.summarizer.modelConfigRef.name // empty) | e($src; ref(["ModelConfig"]; $ns; .); "summarizer") );
  def declarative_edges($src; $ns):
    ( (.modelConfig // empty) | strref($ns) | e($src; ref(["ModelConfig"]; .ns; .name); "modelConfig") ),
    ( (.memory.modelConfig // empty) | strref($ns) | e($src; ref(["ModelConfig"]; .ns; .name); "memory") ),
    ( (.context.compaction.summarizer.modelConfig // empty) | strref($ns) | e($src; ref(["ModelConfig"]; .ns; .name); "summarizer") ),
    ( .tools[]? | (
        (.mcpServer // empty | (.kind // "RemoteMCPServer") as $k
          | if $k == "Service"
            then e($src; "k:svc:" + (.namespace // $ns) + "/" + .name; "tool")
            else e($src; ref([$k]; .namespace // $ns; .name); "tool") end),
        (.agent // empty | e($src; ref([.kind // "Agent", "SandboxAgent"]; .namespace // $ns; .name); "subAgent")) ) );

  # ── agentgateway cross-links: does this URL go through an agentgateway Gateway? ──
  # Matches the Gateway's in-cluster Service name (agentgateway names the Service after the
  # Gateway), its status address, and the solomog.io/host annotation (+ sub-hosts), then picks
  # the attached HTTPRoute whose path match is the longest prefix of the URL path.
  def parseurl:
    (capture("^(?<scheme>https?)://(?<host>[^/:?#]+)(:(?<port>[0-9]+))?(?<path>/[^?#]*)?") // null)
    | if . == null then null else .path = (.path // "/") end;
  def gw_for($host; $ns):
    [$gws[] | .metadata.name as $n | .metadata.namespace as $g
      | (.metadata.annotations["solomog.io/host"] // "") as $a
      | select(([$n+"."+$g+".svc.cluster.local", $n+"."+$g+".svc", $n+"."+$g]
                + (if $ns == $g then [$n] else [] end)
                + [.status.addresses[]?.value] + (if $a != "" then [$a] else [] end)
                | index($host)) != null
               or ($a != "" and ($host|endswith("." + $a))))] | first;
  def route_for($gw; $host; $path):
    [ $rts[] | .metadata.namespace as $rns | . as $r
      | select(any(.spec.parentRefs[]?; .name == $gw.metadata.name and (.namespace // $rns) == $gw.metadata.namespace))
      | select(((.spec.hostnames // []) | length) == 0
               or any(.spec.hostnames[]; . == $host or (startswith("*.") and ($host|endswith(.[1:])))))
      | .spec.rules[]? | (if ((.matches // [])|length) == 0 then [{path:{type:"PathPrefix", value:"/"}}] else .matches end)[]
      | (.path // {type:"PathPrefix", value:"/"}) as $m
      | select(($m.type // "PathPrefix") as $t
               | if $t == "Exact" then $path == $m.value
                 elif $t == "RegularExpression" then ($path | test($m.value))
                 else ($path | startswith($m.value)) end)
      | {score:($m.value|length), id:("httproute:" + $rns + "/" + $r.metadata.name), name:$r.metadata.name} ]
    | max_by(.score);
  # → {gw, route, url} when the URL lands on an agentgateway, else {url} (direct).
  def via($ns):
    . as $url | parseurl as $u
    | if $u == null then {url:$url} else
        gw_for($u.host; $ns) as $gw
        | if $gw == null then {url:$url}
          else route_for($gw; $u.host; $u.path) as $r
               | {url:$url, gw:("gateway:" + $gw.metadata.namespace + "/" + $gw.metadata.name), gwName:$gw.metadata.name,
                  route:($r.id // null), routeName:($r.name // null)} end end;
  def viatext: if .gw then "via agentgateway " + .gwName + (if .routeName then " → HTTPRoute " + .routeName else " (no matching HTTPRoute)" end)
               elif ($gws|length) > 0 then "direct — not through agentgateway" else "direct" end;
  # Every http(s) URL anywhere under .spec (ModelConfig hides it per provider: openAI.baseUrl, ollama.host, …).
  def specurls: [.spec | .. | strings | select(test("^https?://"))] | unique;

  ($all | map(select(.kind=="RemoteMCPServer" or .kind=="ModelConfig")
              | (.metadata.namespace // "") as $ns | {key:._nid, value:[specurls[] | via($ns)]}) | from_entries) as $vias

  # ── nodes ──
  | ([ $all[] | . as $o | (.kind) as $k | (.metadata.namespace // "") as $ns
       | ($k | if . == "SandboxConfig" then "substrate" elif . == "WorkerPool" then "substrate" else "kagent" end) as $product
       | {data:{
           id:._nid, label:.metadata.name, kind:$k, role:"kagent", product:$product,
           plane:(if $k == "SandboxConfig" then "class" else null end),
           ns:(if $ns == "" then "(cluster-scoped)" else $ns end), name:.metadata.name,
           origin:(._source // null),
           status:(if $k == "WorkerPool" then ready elif $k == "SandboxConfig" then "na" else kstat end),
           rtype:._rtype, loaded:"na",
           kubectl:("kubectl get " + ._rtype + " " + .metadata.name + (if $ns == "" then "" else " -n " + $ns end) + " -o yaml"),
           detail:(
             if $k == "Agent" or $k == "SandboxAgent" then
               (if (.spec.templateRef or .spec.template or .spec.harnessRef or .spec.harness) then
                  { api:(.apiVersion + " (template + harness)"),
                    template:(.spec.templateRef.name // (if .spec.template then "(inline)" else "-" end)),
                    harness:(.spec.harnessRef.name // (if .spec.harness then "(inline)" else "-" end)) }
                else
                  { api:(.apiVersion + " (" + (.spec.type // "Declarative") + ")"),
                    modelConfig:(.spec.declarative.modelConfig // "-"),
                    tools:[.spec.declarative.tools[]? | (.mcpServer.name // .agent.name // "?")],
                    workerPool:(.spec.substrate.workerPoolRef.name // null) } end)
               + {description:(.spec.description // .spec.template.description // null), conditions:condlines}
             elif $k == "AgentTemplate" then
               { description:(.spec.description // "-"), modelConfig:(.spec.modelConfig.name // "-"),
                 tools:[.spec.tools[]? | if .mcp then "mcp: " + .mcp.server.name elif .subAgent then "subAgent: " + .subAgent.name else "?" end],
                 skills:([.spec.skills[]? | (.name // "skill")] | if length == 0 then ["-"] else . end) }
             elif $k == "Harness" or $k == "AgentHarness" then
               { workerPool:(.spec.substrate.workerPoolRef.name // "-"),
                 image:(.spec.workload.image // .spec.substrate.workloadImage // "-"),
                 snapshots:(.spec.substrate.snapshotPolicy.location // .spec.substrate.snapshotsConfig.location // "-"),
                 conditions:(condlines | if length == 0 then ["(none reported — kagent records runtime state on the Agent)"] else . end) }
             elif $k == "ModelConfig" then
               { provider:(.spec.provider // "-"), model:(.spec.model // "-"),
                 endpoint:([$vias[$o._nid][]? | .url + "  (" + viatext + ")"] | if length == 0 then ["provider default"] else . end),
                 conditions:condlines }
             elif $k == "RemoteMCPServer" or $k == "MCPServer" then
               { url:([$vias[$o._nid][]? | .url + "  (" + viatext + ")"] | if length == 0 then ["-"] else . end),
                 protocol:(.spec.protocol // .spec.transportType // "-"),
                 tools:([.status.discoveredTools[]?.name] | if length == 0 then ["-"] else . end),
                 conditions:condlines }
             elif $k == "WorkerPool" then
               { ready:readytext, sandboxClass:(.spec.sandboxClass // "-"), image:(.spec.workerImage // "-") }
             elif $k == "SandboxConfig" then
               { sandboxClass:(.spec.sandboxClass // .metadata.name), pauseImage:(.spec.pauseImage // "-") }
             else { conditions:condlines } end) }} ]

    # control-plane + aux deployments
    + [ $kctl[] | depnode("kagent"; false; "controlplane") ]
    + [ $kaux[] | depnode("kagent"; true; "controlplane") ]
    + [ $atectl[] | depnode("substrate"; false; "controlplane") ]
    + [ $ateaux[] | depnode("substrate"; true; "controlplane") ]
    + [ $agentdeps[] | depnode("kagent"; false; "runtime") | .data.plane = "data" ]

    # substrate worker pods (one per pool replica)
    + [ $all[] | select(.kind == "WorkerPool") as $wp | $pods[]
        | select(.metadata.namespace == $wp.metadata.namespace and .metadata.labels["ate.dev/worker-pool"] == $wp.metadata.name)
        # label = the pod-name suffix; the full name repeats the pool name and overlaps its neighbours
        | {data:{ id:("pod:" + .metadata.namespace + "/" + .metadata.name),
            label:("pod …" + (.metadata.name | ltrimstr($wp.metadata.name) | split("-") | last)), kind:"Pod",
            role:"dataplane", plane:"data", product:"substrate", ns:.metadata.namespace, name:.metadata.name,
            status:(if honor|not then "na" elif .status.phase == "Running" then "ok" else "bad" end), rtype:"pod", loaded:"na",
            kubectl:("kubectl get pod " + .metadata.name + " -n " + .metadata.namespace + " -o yaml"),
            detail:{ phase:.status.phase, node:(.spec.nodeName // "-"), workerPool:$wp.metadata.name } }} ]
  ) as $nodes

  # ── edges ──
  | ([ $all[] | ._nid as $s | (.metadata.namespace // "") as $ns | .kind as $k
       | if $k == "Agent" or $k == "SandboxAgent" then
           ( (.spec.templateRef.name // empty) | e($s; ref(["AgentTemplate"]; $ns; .); "templateRef") ),
           ( (.spec.harnessRef.name // empty) | e($s; ref(["Harness","AgentHarness"]; $ns; .); "harnessRef") ),
           ( .spec.template // empty | template_edges($s; $ns) ),
           ( .spec.harness // empty | harness_edges($s; $ns) ),
           ( .spec.declarative // empty | declarative_edges($s; $ns) ),
           ( (.spec.substrate.workerPoolRef.name // empty) | e($s; ref(["WorkerPool"]; $ns; .); "workerPoolRef") )
         elif $k == "AgentTemplate" then .spec | template_edges($s; $ns)
         elif $k == "Harness" or $k == "AgentHarness" or $k == "SandboxTemplate" then .spec | harness_edges($s; $ns)
         elif $k == "WorkerPool" then
           (.spec.sandboxClass // empty) as $c
           | first($all[] | select(.kind == "SandboxConfig" and ((.spec.sandboxClass // .metadata.name) == $c)) | ._nid) // empty
           | e($s; .; "sandboxClass")
         else empty end ]

     # 0.10 Agent → its own Deployment
     + [ $agentdeps[] | . as $d | .metadata.ownerReferences[] | select(.kind == "Agent" or .kind == "SandboxAgent")
         | e(ref([.kind]; $d.metadata.namespace; .name); "deploy:" + $d.metadata.namespace + "/" + $d.metadata.name; "runs") ]

     # controller → the Agents it reconciles: the controller in the Agent's namespace (1.0
     # multi-tenant, rbac.namespaces), else the only controller on the cluster (0.10 watch-all).
     + [ $all[] | select(.kind == "Agent" or .kind == "SandboxAgent" or .kind == "ModelProviderConfig" or .kind == "EnterpriseKagentRBACPolicy")
         | . as $a
         | ( first($kctl[] | select(.metadata.namespace == $a.metadata.namespace))
             // (if ($kctl|length) == 1 then $kctl[0] else empty end) )
         | e("deploy:" + .metadata.namespace + "/" + .metadata.name; $a._nid;
             (if ($a.kind|test("Agent$")) then "manages" else "config" end)) ]

     # substrate control plane → WorkerPools; WorkerPool → its worker pods
     + [ $atectl[] as $c | $all[] | select(.kind == "WorkerPool")
         | e("deploy:" + $c.metadata.namespace + "/ate-controller"; ._nid; "manages") ]
     # SandboxConfigs are chart-installed, cluster-scoped runtime classes — hang them off the
     # substrate controller so an unused class (no pool selects it) still sits in the tree.
     + [ $atectl[] as $c | $all[] | select(.kind == "SandboxConfig")
         | e("deploy:" + $c.metadata.namespace + "/ate-controller"; ._nid; "config") ]
     + [ $all[] | select(.kind == "WorkerPool") as $wp | $pods[]
         | select(.metadata.namespace == $wp.metadata.namespace and .metadata.labels["ate.dev/worker-pool"] == $wp.metadata.name)
         | e($wp._nid; "pod:" + .metadata.namespace + "/" + .metadata.name; "pod") ]

     # kagent → agentgateway: model / MCP traffic that lands on a Gateway
     + [ $vias | to_entries[] | .key as $s | .value[] | select(.gw)
         | e($s; (.route // .gw); "via agentgateway") | .data.cross = true ]

     # agentgateway → kagent: a route/backend whose Service (or static host) fronts a kagent or
     # substrate Deployment (e.g. A2A on kagent-controller, the kagent UI).
     + ( ([$kctl[], $kaux[], $atectl[], $ateaux[]]) as $kd
         | [ $svcs[] | . as $sv
             | first($kd[] | select(.metadata.namespace == $sv.metadata.namespace)
                     | (.spec.template.metadata.labels // {}) as $l | select($sv | selects($l)))
             | {key:($sv.metadata.namespace + "/" + $sv.metadata.name),
                value:("deploy:" + .metadata.namespace + "/" + .metadata.name)} ] | from_entries) as $svc2dep
     | [ ($rts[] | .metadata.namespace as $rns | .spec.rules[]?.backendRefs[]?
           | select((.kind // "Service") == "Service" and ((.group // "") == "" or .group == "core"))
           | ((.namespace // $rns) + "/" + .name) as $key
           | select($svc2dep[$key])
           | e("backend:service:" + $key; $svc2dep[$key]; "routes to") | .data.cross = true),
         ($bes[] | . as $b | (.spec.static.host // empty)
           | capture("^(?<svc>[^.]+)\\.(?<ns>[^.]+)\\.svc") // empty
           | (.ns + "/" + .svc) as $key | select($svc2dep[$key])
           | e("backend:" + $b._rtype + ":" + $b.metadata.namespace + "/" + $b.metadata.name; $svc2dep[$key]; "routes to")
           | .data.cross = true) ]
  ) as $edges

  # Nodes for unresolved refs (missing:) and 0.10 Service tool servers (svc:).
  | ([ $edges[] | .data.target | select(startswith("k:missing:") or startswith("k:svc:")) ] | unique
     | map(. as $id
       | if startswith("k:svc:") then
           (ltrimstr("k:svc:") | split("/")) as $p
           | {data:{ id:$id, label:$p[1], kind:"Service", role:"kagent", product:"kagent", ns:$p[0], name:$p[1],
               status:"na", rtype:"service", loaded:"na",
               kubectl:("kubectl get service " + $p[1] + " -n " + $p[0] + " -o yaml"), detail:{ declared:"Agent tool (Service)" } }}
         else
           (ltrimstr("k:missing:") | split(":")) as $kp | ($kp[1] | split("/")) as $p
           | {data:{ id:$id, label:$p[1], kind:$kp[0], role:"kagent", product:"kagent", missing:true, ghost:true,
               ns:$p[0], name:$p[1], status:"na", rtype:"missing", loaded:"na",
               origin:(if file_mode then "not in this input" else "not in the cluster" end),
               kubectl:("# " + (if file_mode then "not in this input" else "not in the cluster" end)
                        + " — " + $kp[0] + " " + $p[0] + "/" + $p[1]),
               detail:{ note:(if file_mode then "Referenced, but not in this input"
                              else "Referenced, but not in the cluster" end) } }}
         end)) as $extra

  | { elements: ($nodes + $extra + ($edges | unique_by(.data.id))),
      objs: ($all | map({key:._nid, value:(del(._nid))}) | from_entries),
      kagentVersion: ([$kctl[] | imgtag] | map(select(. != "")) | first // ""),
      kagentEdition: (if any($kctl[]; (.metadata.labels["app.kubernetes.io/name"] // "") | test("enterprise"))
                         or any($kctl[]; (.spec.template.spec.containers[0].image // "") | test("enterprise"))
                      then "enterprise" else "community" end),
      substrateVersion: ([$atectl[] | imgtag] | first // "") }
