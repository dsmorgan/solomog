# agw.jq — agentgateway kinds the graph draws besides Gateway / HTTPRoute / Policy / Backend.
#
# Included by the element builder in graph.sh. Callers pass the fetched lists in.
#
# The identity Deployment reads only an EnterpriseIdentityConfig named `default` in its
# namespace. A connector is not a child of that object: it is `entConnector` on a policy
# or backend, and that edge points at `default`. Any other name is drawn and marked not
# served. Secret refs stay in the detail panel; this file does not draw Secret nodes.
#
# Budget, role binding, RBAC policy, and external secret have no name reference to a
# Gateway. They are nodes with role "side" and no edges.

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

def param_rtype:
  if (.kind // "") == "EnterpriseAgentgatewayParameters"
  then "enterpriseagentgatewayparameters.enterpriseagentgateway.solo.io"
  else "agentgatewayparameters.agentgateway.dev" end;

# Id of the node a ref points at. Callers apply kind defaults first.
def target_id($default_ns):
  (.kind // "Object") as $k
  | (.namespace // $default_ns) as $ns
  | (.name // "") as $n
  | if $k == "Gateway" then "gateway:" + $ns + "/" + $n
    elif $k == "HTTPRoute" then "httproute:" + $ns + "/" + $n
    elif $k == "GRPCRoute" then "grpcroute:" + $ns + "/" + $n
    elif $k == "ListenerSet" then "listenerset:" + $ns + "/" + $n
    elif $k == "EnterpriseListenerSet" then "enterpriselistenerset:" + $ns + "/" + $n
    elif $k == "ServiceEntry" then "serviceentry:" + $ns + "/" + $n
    elif $k == "Service" or $k == "" then "backend:" + (.|backend_key($default_ns; "service"))
    elif ($k | test("Backend")) then "backend:" + (.|backend_key($default_ns; "agentgatewaybackends.agentgateway.dev"))
    elif $k == "AgentgatewayPolicy" or $k == "EnterpriseAgentgatewayPolicy" then "policy:" + $ns + "/" + $n
    elif $k == "AgentgatewayParameters" or $k == "EnterpriseAgentgatewayParameters"
      then "parameters:" + param_rtype + ":" + $ns + "/" + $n
    elif $k == "AuthConfig" then "authconfig:" + $ns + "/" + $n
    elif $k == "RateLimitConfig" then "ratelimitconfig:" + $ns + "/" + $n
    elif $k == "WAFPolicy" then "wafpolicy:" + $ns + "/" + $n
    elif $k == "AgentgatewayModel" then "model:" + $ns + "/" + $n
    elif $k == "EnterpriseIdentityConfig" then "identity:" + $ns + "/" + $n
    else "obj:" + $k + ":" + $ns + "/" + $n
    end;

def fill_ref($kind; $group; $ns):
  (if (.kind // "") == "" then .kind = $kind else . end)
  | (if (.group // "") == "" and $group != "" then .group = $group else . end)
  | (if (.namespace // "") == "" then .namespace = $ns else . end);

def honor: $honorStatus == "true";

def accepted:
  if honor|not then "na"
  else ([.status.conditions[]? | select(.type=="Accepted") | .status]) as $c
    | if ($c|length)==0 then "na" elif ($c|all(.=="True")) then "ok" else "bad" end
  end;

def declares_connector:
  [ .. | objects | select(has("entConnector")) | .entConnector | select(type=="object") ] | length > 0;

def is_identity_deploy:
  (.metadata.labels["app.kubernetes.io/component"] == "identity")
  or ((.metadata.name // "") | test("-identity$"));

# Namespace whose `default` EnterpriseIdentityConfig the identity service reads.
# One identity Deployment wins; otherwise the only config named default.
def identity_home($deps; $idc):
  ([ $deps[] | select(is_identity_deploy) | .metadata.namespace ] | unique) as $dns
  | ([ $idc[] | select(.metadata.name=="default") | .metadata.namespace ] | unique) as $cns
  | if ($dns|length)==1 then $dns[0]
    elif ($cns|length)==1 then $cns[0]
    else null end;

def edge($id; $source; $target; $rel; $kind):
  {data:{ id:$id, source:$source, target:$target, rel:$rel, refKind:$kind }};

def agw_extra($grt; $ls; $els; $se; $par; $idc; $mod; $ext; $side; $deps; $gc; $pol; $be):
  (
  (identity_home($deps; $idc)) as $home
  # ── GRPCRoute ──
  | [ $grt[] | {data:{
      id:("grpcroute:"+.metadata.namespace+"/"+.metadata.name), label:.metadata.name,
      kind:"GRPCRoute", role:"route", ns:.metadata.namespace, name:.metadata.name,
      status:(if honor|not then "na" else
        ([.status.parents[]?.conditions[]?|select(.type=="Accepted").status]) as $a
        | if ($a|length)==0 then "na" elif ($a|all(.=="True")) then "ok" else "bad" end end),
      rtype:(._rtype // "grpcroutes.gateway.networking.k8s.io"), loaded:"na",
      origin:(._source // null),
      kubectl:("kubectl get "+(._rtype // "grpcroute")+" "+.metadata.name+" -n "+.metadata.namespace+" -o yaml"),
      detail:{ hostnames:([.spec.hostnames[]?]|if length==0 then ["*"] else . end) } }} ]
  + [ $grt[] | .metadata.namespace as $rns | .metadata.name as $rn
      | .spec.parentRefs[]? | fill_ref("Gateway"; "gateway.networking.k8s.io"; $rns) | . as $ref
      | edge("e:grpcparent:"+$rns+":"+$rn+":"+$ref.name;
            "grpcroute:"+$rns+"/"+$rn; ($ref|target_id($rns)); "parentRef"; $ref.kind) ]
  + [ $grt[] | .metadata.namespace as $rns | .metadata.name as $rn
      | .spec.rules[]?.backendRefs[]? | . as $ref
      | edge("e:grpcbe:"+$rns+":"+$rn+":"+($ref|backend_key($rns; "service"));
            "grpcroute:"+$rns+"/"+$rn;
            "backend:"+($ref|backend_key($rns; "service")); "backendRef"; ($ref.kind // "Service")) ]

  # ── Listener sets. Parentheses keep both kinds in one stream (comma binds looser than pipe). ──
  + [ (($ls[] | . + {_lk:"ListenerSet", _lid:"listenerset"}),
       ($els[] | . + {_lk:"EnterpriseListenerSet", _lid:"enterpriselistenerset"}))
      | . as $o
      | {data:{
          id:($o._lid+":"+$o.metadata.namespace+"/"+$o.metadata.name), label:$o.metadata.name,
          kind:$o._lk, role:"listener", ns:$o.metadata.namespace, name:$o.metadata.name,
          status:($o|accepted), rtype:($o._rtype // $o._lid), loaded:"na",
          origin:($o._source // null),
          kubectl:("kubectl get "+($o._rtype // $o._lid)+" "+$o.metadata.name+" -n "+$o.metadata.namespace+" -o yaml"),
          detail:{
            parent:((($o.spec.parentRef.kind) // "Gateway")+"/"+(($o.spec.parentRef.name) // "-")),
            listeners:([$o.spec.listeners[]? | (.protocol // "?")+"/"+((.port // 0)|tostring)+" ("+(.hostname // "*")+")"])
          } }} ]
  + [ (($ls[] | . + {_lid:"listenerset"}), ($els[] | . + {_lid:"enterpriselistenerset"}))
      | . as $o
      | ($o.spec.parentRef // null) | select(type=="object" and .name != null)
      | fill_ref("Gateway"; "gateway.networking.k8s.io"; $o.metadata.namespace) | . as $ref
      | edge("e:lsparent:"+$o.metadata.namespace+":"+$o.metadata.name;
            $o._lid+":"+$o.metadata.namespace+"/"+$o.metadata.name;
            ($ref|target_id($o.metadata.namespace)); "parentRef"; $ref.kind) ]

  # ── ServiceEntry ──
  + [ $se[] | {data:{
      id:("serviceentry:"+.metadata.namespace+"/"+.metadata.name), label:.metadata.name,
      kind:"ServiceEntry", role:"external", ns:.metadata.namespace, name:.metadata.name,
      status:"na", rtype:(._rtype // "serviceentries.networking.istio.io"), loaded:"na",
      origin:(._source // null),
      kubectl:("kubectl get "+(._rtype // "serviceentry")+" "+.metadata.name+" -n "+.metadata.namespace+" -o yaml"),
      detail:{ hosts:([.spec.hosts[]?] | if length==0 then ["-"] else . end) } }} ]

  # ── Parameters, from GatewayClass.spec.parametersRef ──
  + [ $par[] | {data:{
      id:("parameters:"+._rtype+":"+.metadata.namespace+"/"+.metadata.name), label:.metadata.name,
      kind:.kind, role:"parameters", ns:.metadata.namespace, name:.metadata.name,
      status:accepted, rtype:._rtype, loaded:"na",
      origin:(._source // null),
      kubectl:("kubectl get "+._rtype+" "+.metadata.name+" -n "+.metadata.namespace+" -o yaml"),
      detail:{ logging:(.spec.logging.format // .spec.logging.level // "-") } }} ]
  + [ $gc[] | .metadata.name as $cn
      | (.spec.parametersRef // null) | select(type=="object" and .name != null)
      | fill_ref("EnterpriseAgentgatewayParameters"; "enterpriseagentgateway.solo.io"; (.namespace // "default"))
      | . as $ref
      | edge("e:paramref:"+$cn; "gatewayclass:"+$cn; ($ref|target_id($ref.namespace)); "parametersRef"; $ref.kind) ]

  # ── AgentgatewayModel ──
  + [ $mod[] | {data:{
      id:("model:"+.metadata.namespace+"/"+.metadata.name), label:.metadata.name,
      kind:"AgentgatewayModel", role:"model", ns:.metadata.namespace, name:.metadata.name,
      status:accepted, rtype:(._rtype // "agentgatewaymodels.agentgateway.dev"), loaded:"na",
      origin:(._source // null),
      kubectl:("kubectl get "+(._rtype // "agentgatewaymodel")+" "+.metadata.name+" -n "+.metadata.namespace+" -o yaml"),
      detail:{
        provider:(if (.spec.virtualModel|type)=="object" then "virtual" else (.spec.provider // "-") end),
        match:(.spec.match.model // "-"),
        parents:([.spec.parentRefs[]? | (.kind // "Gateway")+"/"+(.name // "-")] | if length==0 then ["-"] else . end)
      } }} ]
  + [ $mod[] | .metadata.namespace as $ns | .metadata.name as $mn
      | .spec.parentRefs[]? | fill_ref("Gateway"; "gateway.networking.k8s.io"; $ns) | . as $ref
      | edge("e:modelparent:"+$ns+":"+$mn+":"+$ref.name;
            "model:"+$ns+"/"+$mn; ($ref|target_id($ns)); "parentRef"; $ref.kind) ]
  + [ $mod[] | .metadata.namespace as $ns | .metadata.name as $mn
      | .. | objects | .modelRef? | select(type=="object" and (.name|type)=="string")
      | fill_ref("AgentgatewayModel"; "agentgateway.dev"; $ns) | . as $ref
      | edge("e:modelref:"+$ns+":"+$mn+":"+($ref.namespace // $ns)+":"+$ref.name;
            "model:"+$ns+"/"+$mn; ($ref|target_id($ns)); "modelRef"; $ref.kind) ]
  + [ $mod[] | .metadata.namespace as $ns | .metadata.name as $mn
      | (.spec.custom.backendRef, .spec.virtualModel.callout.backendRef)
      | select(type=="object" and (.name|type)=="string")
      | . as $ref
      | edge("e:modelbe:"+$ns+":"+$mn+":"+($ref|backend_key($ns; "service"));
            "model:"+$ns+"/"+$mn;
            "backend:"+($ref|backend_key($ns; "service")); "backendRef"; ($ref.kind // "Service")) ]

  # ── AuthConfig / RateLimitConfig / WAFPolicy ──
  + [ $ext[] |
      (if .kind=="AuthConfig" then "authconfig"
       elif .kind=="RateLimitConfig" then "ratelimitconfig"
       elif .kind=="WAFPolicy" then "wafpolicy"
       else "ext" end) as $prefix
      | {data:{
          id:($prefix+":"+.metadata.namespace+"/"+.metadata.name), label:.metadata.name,
          kind:.kind, role:"extension", ns:.metadata.namespace, name:.metadata.name,
          status:accepted, rtype:(._rtype // $prefix), loaded:"na",
          origin:(._source // null),
          kubectl:("kubectl get "+(._rtype // $prefix)+" "+.metadata.name+" -n "+.metadata.namespace+" -o yaml"),
          detail:{ note:"named by an enterprise policy ref" } }} ]
  + [ $pol[] | . as $p
      | $p | .. | objects
      | (
          (.authConfigRef | select(type=="object" and (.name|type)=="string") | . + {kind:"AuthConfig"}),
          (.wafPolicyRef | select(type=="object" and (.name|type)=="string") | . + {kind:"WAFPolicy"}),
          (.rateLimitConfigRefs[]? | select(type=="object" and (.name|type)=="string") | . + {kind:"RateLimitConfig"})
        )
      | fill_ref(.kind; ""; $p.metadata.namespace) | . as $ref
      | edge("e:ext:"+$p.metadata.namespace+":"+$p.metadata.name+":"+$ref.kind+":"+($ref.namespace // $p.metadata.namespace)+":"+$ref.name;
            "policy:"+$p.metadata.namespace+"/"+$p.metadata.name;
            ($ref|target_id($p.metadata.namespace)); "uses"; $ref.kind) ]

  # ── Policy imports (kind + name, same namespace) ──
  + [ $pol[] | .metadata.namespace as $pns | .metadata.name as $pn
      | .spec.imports[]? | select((.name // "") != "")
      | fill_ref((.kind // "EnterpriseAgentgatewayPolicy"); ""; $pns) | . as $ref
      | edge("e:import:"+$pns+":"+$pn+":"+$ref.kind+":"+$ref.name;
            "policy:"+$pns+"/"+$pn; ($ref|target_id($pns)); "import"; $ref.kind) ]

  # ── EnterpriseIdentityConfig + the Deployment that reads `default` ──
  + [ $idc[] | {data:{
      id:("identity:"+.metadata.namespace+"/"+.metadata.name), label:.metadata.name,
      kind:"EnterpriseIdentityConfig", role:"identity", ns:.metadata.namespace, name:.metadata.name,
      status:accepted, rtype:(._rtype // "enterpriseidentityconfigs.enterpriseagentgateway.solo.io"),
      loaded:"na",
      origin:(._source // null),
      kubectl:("kubectl get "+(._rtype // "enterpriseidentityconfig")+" "+.metadata.name+" -n "+.metadata.namespace+" -o yaml"),
      detail:{
        served:(if .metadata.name=="default" then "yes — identity reads this name" else "no — identity reads only default" end),
        publicBaseUrl:(.spec.connectors.publicBaseUrl // "-"),
        ui:(.spec.connectors.ui.baseUrl // "-"),
        grantIdle:(.spec.connectors.grant.idleTimeout // "-"),
        grantMax:(.spec.connectors.grant.maxLifetime // "-"),
        issuers:([.spec.trust.issuers[]?.issuer] | if length==0 then ["-"] else . end),
        conditions:(if honor then ([.status.conditions[]? | .type+"="+.status] | if length==0 then ["(none reported)"] else . end) else ["(status not evaluated)"] end)
      } }} ]
  + [ $deps[] | select(is_identity_deploy) | {data:{
      id:("deploy:"+.metadata.namespace+"/"+.metadata.name), label:.metadata.name,
      kind:"Deployment", role:"controlplane", plane:"control", ns:.metadata.namespace, name:.metadata.name,
      aux:false,
      status:(if honor|not then "na" elif (.status.readyReplicas//0)==(.status.replicas//0) and (.status.replicas//0)>0 then "ok" else "bad" end),
      rtype:"deploy", loaded:"na",
      origin:(._source // null),
      kubectl:("kubectl get deploy "+.metadata.name+" -n "+.metadata.namespace+" -o yaml"),
      detail:{ ready:((.status.readyReplicas//0|tostring)+"/"+(.status.replicas//0|tostring)), component:"identity" } }} ]
  + [ $deps[] | select(is_identity_deploy)
      | .metadata.namespace as $ns | .metadata.name as $dn
      | edge("e:reads:"+$ns+":"+$dn;
            "deploy:"+$ns+"/"+$dn; "identity:"+$ns+"/default"; "reads"; "EnterpriseIdentityConfig") ]

  # ── entConnector on a policy or backend points at that namespace's `default` config ──
  + [ $pol[] | select(declares_connector)
      | .metadata.namespace as $ns | .metadata.name as $pn
      | ($home // $ns) as $h
      | edge("e:connector:policy:"+$ns+":"+$pn;
            "policy:"+$ns+"/"+$pn; "identity:"+$h+"/default"; "entConnector"; "EnterpriseIdentityConfig") ]
  + [ $be[] | select(declares_connector)
      | .metadata.namespace as $ns | .metadata.name as $bn
      | ($home // $ns) as $h
      | edge("e:connector:backend:"+$ns+":"+$bn;
            "backend:"+._rtype+":"+$ns+"/"+$bn;
            "identity:"+$h+"/default"; "entConnector"; "EnterpriseIdentityConfig") ]

  # ── Issuer JWKS / discovery backends ──
  + [ $idc[] | .metadata.namespace as $ns | .metadata.name as $in
      | .spec.trust.issuers[]? | (.discovery.backendRef, .jwks.remote.backendRef)
      | select(type=="object" and (.name|type)=="string") | . as $ref
      | edge("e:issuerbe:"+$ns+":"+$in+":"+($ref|backend_key($ns; "service"));
            "identity:"+$ns+"/"+$in;
            "backend:"+($ref|backend_key($ns; "service")); "backendRef"; ($ref.kind // "Service")) ]

  # ── No structural edge: budget, role binding, RBAC, external secret ──
  + [ $side[] |
      (.metadata.namespace // "(cluster-scoped)") as $ns
      | {data:{
          id:("side:"+.kind+":"+$ns+"/"+.metadata.name), label:.metadata.name,
          kind:.kind, role:"side", ns:$ns, name:.metadata.name,
          status:accepted, rtype:(._rtype // "side"), loaded:"na",
          origin:(._source // null),
          kubectl:(if $ns=="(cluster-scoped)"
                   then "kubectl get "+(._rtype // "side")+" "+.metadata.name+" -o yaml"
                   else "kubectl get "+(._rtype // "side")+" "+.metadata.name+" -n "+$ns+" -o yaml" end),
          detail:(
            if .kind=="EnterpriseAgentgatewayBudget" then
              { budgets:([.spec.budgets[]?.name] | if length==0 then ["-"] else . end) }
            elif .kind=="EnterpriseAgentgatewayRoleBinding" then
              { roles:([.spec.roles[]?] | if length==0 then ["-"] else . end) }
            elif .kind=="EnterpriseAgentgatewayRBACPolicy" then
              { grants:([.spec.grants[]?.name] | if length==0 then ["-"] else . end) }
            else
              { store:(.spec.storeRef.name // "-") }
            end) }} ]
  ) | unique_by(.data.id)
;
