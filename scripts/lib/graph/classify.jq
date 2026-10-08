# classify.jq — split a JSON array of Kubernetes objects (from ingest.rb) into the
# buckets graph.sh already builds from kubectl. Tags policies, backends, and kagent
# objects with the same `_rtype` the live path uses, so node ids match.
#
# Objects with no namespace get `default`, except cluster-scoped kinds. Duplicate
# kind+namespace+name among graphed objects is an error the caller prints.

def group:
  (.apiVersion // "") as $a
  | if ($a | index("/")) then ($a | split("/")[0])
    elif $a == "v1" or $a == "" then "core"
    else $a end;

def group_ok($g):
  (.apiVersion // "") as $a | if $a == "" then true else group == $g end;

def plural:
  {
    "Agent": "agents",
    "AgentTemplate": "agenttemplates",
    "Harness": "harnesses",
    "AgentHarness": "agentharnesses",
    "SandboxAgent": "sandboxagents",
    "SandboxTemplate": "sandboxtemplates",
    "ModelConfig": "modelconfigs",
    "ModelProviderConfig": "modelproviderconfigs",
    "RemoteMCPServer": "remotemcpservers",
    "MCPServer": "mcpservers",
    "EnterpriseKagentRBACPolicy": "enterprisekagentrbacpolicies",
    "WorkerPool": "workerpools",
    "SandboxConfig": "sandboxconfigs"
  }[.kind] // "";

def rtype:
  if .kind == "EnterpriseAgentgatewayPolicy" then "enterpriseagentgatewaypolicies.enterpriseagentgateway.solo.io"
  elif .kind == "AgentgatewayPolicy" then "agentgatewaypolicies.agentgateway.dev"
  elif .kind == "EnterpriseAgentgatewayBackend" then "enterpriseagentgatewaybackends.enterpriseagentgateway.solo.io"
  elif .kind == "AgentgatewayBackend" then "agentgatewaybackends.agentgateway.dev"
  elif .kind == "EnterpriseKagentRBACPolicy" then "enterprisekagentrbacpolicies.enterprisekagent.solo.io"
  elif .kind == "WorkerPool" then "workerpools.ate.dev"
  elif .kind == "SandboxConfig" then "sandboxconfigs.ate.dev"
  else (plural + "." + group) end;

def cluster_scoped: .kind == "GatewayClass" or .kind == "SandboxConfig";

def bucket:
  if ._skip then "skip"
  elif (.metadata.name // "") == "" then "skip"
  elif .kind == "Gateway" and group_ok("gateway.networking.k8s.io") then "gw"
  elif .kind == "HTTPRoute" and group_ok("gateway.networking.k8s.io") then "rt"
  elif .kind == "GatewayClass" and group_ok("gateway.networking.k8s.io") then "gc"
  elif .kind == "EnterpriseAgentgatewayPolicy" or .kind == "AgentgatewayPolicy" then "pol"
  elif .kind == "EnterpriseAgentgatewayBackend" or .kind == "AgentgatewayBackend" then "be"
  elif .kind == "Pod" and group_ok("core") then "pods"
  elif .kind == "Deployment" and group_ok("apps") then "deps"
  elif .kind == "Service" and group_ok("core") then "svcs"
  elif (plural != "") then "kobjs"
  else "skip" end;

def withns:
  (if .metadata == null then .metadata = {} else . end)
  | if cluster_scoped then .
    elif ((.metadata.namespace // "") == "") then
      .metadata.namespace = "default" | .metadata._defaultedNamespace = true
    else . end;

def tagged:
  if bucket == "pol" or bucket == "be" or bucket == "kobjs" then . + {_rtype: rtype} else . end;

[.[] | select(type == "object")] as $raw
| ($raw | map(if bucket == "skip" then . else withns | tagged end)) as $docs
| def take($b): [$docs[] | select(bucket == $b)];
  ($docs | map(select(bucket != "skip")) | group_by(.kind + "|" + (.metadata.namespace // "") + "|" + .metadata.name)
    | map(select(length > 1) | {
        kind: .[0].kind,
        ns: (.[0].metadata.namespace // ""),
        name: .[0].metadata.name,
        sources: [.[]._source]
      })) as $dups
| {
    gw: take("gw"),
    rt: take("rt"),
    pol: take("pol"),
    be: take("be"),
    pods: take("pods"),
    deps: take("deps"),
    gc: take("gc"),
    svcs: take("svcs"),
    kobjs: take("kobjs"),
    duplicates: $dups,
    defaulted: ([$docs[] | select(.metadata._defaultedNamespace == true)] | length),
    skipped: (
      [$docs[] | select(bucket == "skip") | (.kind // ._skip // "unknown")]
      | group_by(.) | map({kind: .[0], count: length}) | sort_by(.kind)
    ),
    objects: ($raw | length)
  }
