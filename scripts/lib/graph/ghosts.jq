# ghosts.jq — nodes for refs whose target is not in the snapshot.
#
# A ghost keeps the kind's shape and color. The HTML draws it dashed and dimmed.
# The label is the referenced name.
#
# Live cluster: a Service backend stays solid. Graph does not list every Service,
# so absence is not evidence. A Gateway that exists but is not an agentgateway
# class is skipped, not ghosted — pass the full Gateway list in $gw.
# File render ($fileMode == "true"): a Service that is not in $svcs is a ghost.
#
# Inputs are --slurpfile (one-element arrays): $data $gw $rt $svcs. $fileMode is --arg.

$data[0] as $data
| $gw[0] as $gw
| $rt[0] as $rt
| $svcs[0] as $svcs
| def note:
    if $fileMode == "true" then "Referenced, but not in this input"
    else "Referenced, but not in the cluster" end;
  def srcnote:
    if $fileMode == "true" then "not in this input" else "not in the cluster" end;
  def gw_exists($ns; $name):
    any($gw[]; .metadata.namespace == $ns and .metadata.name == $name);
  def tail($id):
    if ($id | startswith("backend:")) then ($id | split(":") | last)
    else $id | sub("^[^:]+:"; "") end;
  def ns_of($id): (tail($id) | split("/"))[0];
  def name_of($id): (tail($id) | split("/"))[1];
  def ghost($id; $kind; $role; $ns; $name):
    {data:{
      id: $id, label: $name, kind: $kind, role: $role, product: "agentgateway",
      plane: (if $kind == "Gateway" then "data" else null end),
      ns: $ns, name: $name, status: "na", ghost: true, missing: true, loaded: "na",
      rtype: "ghost", origin: srcnote,
      kubectl: ("# " + srcnote + " — " + $kind + " " + $ns + "/" + $name),
      detail: {note: note}
    }};
  def has($ids; $id): ($ids | index($id)) != null;

  [ $rt[] | .metadata.namespace as $rns | .metadata.name as $rn
    | .spec.parentRefs[]? | select((.kind // "Gateway") == "Gateway")
    | (.namespace // $rns) as $pns | .name as $pname
    | select(gw_exists($pns; $pname) | not)
    | {ns: $pns, name: $pname, routeNs: $rns, route: $rn}
  ] as $missing_parents

  | ($data.elements | map(
      if (.data.source | not) and .data.kind == "Backend"
         and (((.data.detail // {}).declared // "") != "CR")
      then .data.ghost = true | .data.missing = true | .data.status = "na"
           | .data.origin = srcnote
           | .data.detail = ((.data.detail // {}) + {note: note})
      elif (.data.source | not) and .data.kind == "Service" and ($fileMode == "true")
      then (.data.ns) as $ns | (.data.name) as $nm
           | if any($svcs[]; .metadata.namespace == $ns and .metadata.name == $nm) then .
             else .data.ghost = true | .data.missing = true | .data.status = "na"
                  | .data.origin = srcnote
                  | .data.detail = ((.data.detail // {}) + {note: note}) end
      elif (.data.source | not) and .data.missing == true
      then .data.ghost = true | .data.status = "na" | .data.origin = srcnote
      else . end
    )) as $flagged

  | ($flagged | map(select(.data.source | not) | .data.id)) as $ids
  | [ $missing_parents | unique_by(.ns + "/" + .name)[]
      | select(has($ids; "gateway:" + .ns + "/" + .name) | not)
      | ghost("gateway:" + .ns + "/" + .name; "Gateway"; "dataplane"; .ns; .name)
    ] as $gw_nodes
  | [ $missing_parents[]
      | {data:{
          id: ("e:parent:" + .routeNs + ":" + .route + ":" + .name),
          source: ("httproute:" + .routeNs + "/" + .route),
          target: ("gateway:" + .ns + "/" + .name),
          rel: "parentRef"
        }}
    ] as $parent_edges

  | ($flagged + $gw_nodes) as $with_gw
  | ($with_gw | map(select(.data.source | not) | .data.id)) as $ids2
  | [ $with_gw[] | select(.data.rel == "targetRef")
      | . as $e
      | select(has($ids2; $e.data.target) | not)
      | ($e.data.id | split(":")) as $parts
      | ($parts[4] // "Object") as $refkind
      | select(
          if ($e.data.target | startswith("gateway:")) then
            gw_exists(ns_of($e.data.target); name_of($e.data.target)) | not
          else true end)
      | (if $refkind == "HTTPRoute" then "HTTPRoute"
         elif $refkind == "Gateway" then "Gateway"
         elif $refkind == "Service" then "Service"
         elif ($refkind | test("Backend")) then "Backend"
         else $refkind end) as $kind
      | (if $kind == "Gateway" then "dataplane"
         elif $kind == "HTTPRoute" then "route"
         elif $kind == "Service" then "external"
         elif $kind == "Backend" then "backend"
         else "ghost" end) as $role
      | ghost($e.data.target; $kind; $role; ns_of($e.data.target); name_of($e.data.target))
    ] as $target_ghosts

  | $data | .elements = (($with_gw + $parent_edges + $target_ghosts) | unique_by(.data.id))
