# Troubleshooting Agentgateway Policies with Logs and Request Traces

This guide shows how to:

- emit structured agentgateway access logs for collection by Datadog
- change proxy log levels persistently or at runtime
- inspect the effective policies applied to an individual request
- troubleshoot locally with `kubectl` and `agctl`

The examples use Solo Enterprise for agentgateway. Resource names, namespaces,
listener ports, and hostnames vary between environments.

## Set environment-specific values

Set these values before running the examples:

```bash
export AGW_CONTEXT="<kube-context>"
export AGW_NAMESPACE="<agentgateway-namespace>"
export AGW_GATEWAY="<gateway-name>"
export AGW_PARAMETERS="<parameters-resource-name>"
export AGW_LISTENER_PORT="<gateway-listener-port>"
export AGW_HOST="<hostname-routed-by-the-gateway>"
```

Confirm the target:

```bash
kubectl --context "$AGW_CONTEXT" get gateway "$AGW_GATEWAY" \
  -n "$AGW_NAMESPACE" -o wide
```

`agctl` uses the current context from the kubeconfig. Before running the `agctl`
examples later in this guide, select the same cluster:

```bash
kubectl config use-context "$AGW_CONTEXT"
```

## Understand the three logging and tracing mechanisms

These mechanisms answer different questions:

1. **Access logs** provide a durable request record. Write them as JSON to
   stdout so the existing Datadog Agent can collect them.
2. **Proxy debug logs** explain internal proxy behavior. Increase their level
   temporarily because debug and trace output can be high volume.
3. **Request traces** show route selection and the effective policies evaluated
   for one request. This is the most direct way to answer, "Did this policy
   apply, and what did it do?"

Access logs do not automatically list every effective policy. Use `agctl proxy
trace` when policy selection itself is the question.

## 1. Configure structured proxy logs

First, determine whether the Gateway already references an
`EnterpriseAgentgatewayParameters` resource:

```bash
kubectl --context "$AGW_CONTEXT" get gateway "$AGW_GATEWAY" \
  -n "$AGW_NAMESPACE" \
  -o jsonpath='{.spec.infrastructure.parametersRef}{"\n"}'
```

If a parameters resource is already attached, update that resource instead of
replacing it. Replacing an existing reference can discard settings for images,
resources, environment variables, overlays, or other gateway customization.

Edit the existing resource:

```bash
kubectl --context "$AGW_CONTEXT" edit \
  enterpriseagentgatewayparameters "$AGW_PARAMETERS" \
  -n "$AGW_NAMESPACE"
```

Add or merge:

```yaml
spec:
  logging:
    level: info
    format: json
```

If the Gateway does not have a parameters resource, create and attach one:

```bash
kubectl --context "$AGW_CONTEXT" apply -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayParameters
metadata:
  name: ${AGW_PARAMETERS}
  namespace: ${AGW_NAMESPACE}
spec:
  logging:
    level: info
    format: json
EOF

kubectl --context "$AGW_CONTEXT" patch gateway "$AGW_GATEWAY" \
  -n "$AGW_NAMESPACE" --type=merge \
  -p "{\"spec\":{\"infrastructure\":{\"parametersRef\":{\"group\":\"enterpriseagentgateway.solo.io\",\"kind\":\"EnterpriseAgentgatewayParameters\",\"name\":\"${AGW_PARAMETERS}\"}}}}"
```

Changing the parameters resource is persistent and can trigger a proxy rollout.
Check the Gateway and workload before continuing:

```bash
kubectl --context "$AGW_CONTEXT" get gateway "$AGW_GATEWAY" \
  -n "$AGW_NAMESPACE" -o yaml
kubectl --context "$AGW_CONTEXT" rollout status \
  deployment/"$AGW_GATEWAY" -n "$AGW_NAMESPACE"
```

Resources:

- [Customize an enterprise gateway](https://docs.solo.io/agentgateway/latest/setup/customize/customize/)
- [Enterprise agentgateway API reference](https://docs.solo.io/agentgateway/latest/reference/api/solo/)
- [Logging customization options](https://docs.solo.io/agentgateway/latest/setup/customize/options/)

## 2. Add an access-log policy for Datadog

The following policy targets the Gateway, writes an access log for every
request, and adds fields that are easy to find in Datadog:

```bash
kubectl --context "$AGW_CONTEXT" apply -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: policy-access-logs
  namespace: ${AGW_NAMESPACE}
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: ${AGW_GATEWAY}
  frontend:
    accessLog:
      attributes:
        add:
          - name: log_purpose
            expression: '"policy-troubleshooting"'
          - name: request_path
            expression: request.path
          - name: request_method
            expression: request.method
          - name: status_code
            expression: string(response.code)
EOF
```

Check whether the policy attached successfully:

```bash
kubectl --context "$AGW_CONTEXT" get \
  enterpriseagentgatewaypolicy policy-access-logs \
  -n "$AGW_NAMESPACE" -o yaml
```

Look for an `Attached=True` condition. An absent or false condition usually
indicates a target name, namespace, API group, or resource-kind mismatch.

Send representative successful and unsuccessful requests:

```bash
curl -i "https://${AGW_HOST}/<known-path>"
curl -i "https://${AGW_HOST}/<missing-path>"
```

Verify locally before checking Datadog:

```bash
kubectl --context "$AGW_CONTEXT" logs \
  deployment/"$AGW_GATEWAY" -n "$AGW_NAMESPACE" \
  --since=5m | grep policy-troubleshooting
```

If the generated workload has a customized name, locate its pods and use the
actual Deployment or pod name:

```bash
kubectl --context "$AGW_CONTEXT" get pods -n "$AGW_NAMESPACE" \
  -l "gateway.networking.k8s.io/gateway-name=${AGW_GATEWAY}"
```

### Find the records in Datadog

Because the policy writes to container stdout, an existing Datadog Kubernetes
log collector should ingest the records without another agentgateway exporter.
The exact Kubernetes tags depend on the Datadog installation and processing
pipelines.

Start with a broad search for:

```text
policy-troubleshooting
```

If Datadog parses the JSON attributes as facets, narrow the query:

```text
@log_purpose:policy-troubleshooting
```

Then add the environment's namespace, cluster, pod, service, or container tags.
Confirm that `request_path`, `request_method`, and `status_code` are parsed as
attributes. If the complete log is stored only in `message`, configure or adjust
the Datadog JSON parsing pipeline.

Do not add request bodies, response bodies, authorization headers, API keys,
prompts, or completions to access logs without an explicit data-handling review.
Those fields can contain credentials, personal data, or proprietary content.

To log failures only, add this filter under `accessLog`:

```yaml
filter: response.code >= 400
```

Generate both a successful and unsuccessful request and confirm that only the
unsuccessful request reaches Datadog.

Resources:

- [Agentgateway access logging](https://docs.solo.io/agentgateway/latest/security/access-logging/)
- [Log CEL variables in access logs](https://docs.solo.io/agentgateway/latest/traffic-management/transformations/access-logs/)
- [Agentgateway CEL expression reference](https://docs.solo.io/agentgateway/latest/reference/cel/)
- [Datadog Kubernetes log collection](https://docs.datadoghq.com/containers/kubernetes/log/)
- [Datadog log parsing](https://docs.datadoghq.com/logs/log_configuration/parsing/)

## 3. Increase the persistent proxy log level

Use the typed `logging.level` field with standard `RUST_LOG` syntax. For
example, keep the global level at `info` and enable debug logs for one module:

```yaml
spec:
  logging:
    level: "info,agentgateway::proxy=debug"
    format: json
```

Apply the change to the attached `EnterpriseAgentgatewayParameters` resource,
wait for reconciliation, and follow the proxy logs:

```bash
kubectl --context "$AGW_CONTEXT" logs \
  deployment/"$AGW_GATEWAY" -n "$AGW_NAMESPACE" -f
```

Persistent configuration survives pod replacement but can roll the proxy.
Restore the normal level after troubleshooting to control volume and cost in
Datadog.

Use `rawConfig` only for settings that do not have typed fields. Logging level
and format are typed and validated, so `rawConfig` is unnecessary here.

## 4. Change the runtime level without restarting

`agctl proxy log` changes the active proxy filter through the admin API without
restarting the pod:

Install `agctl` by following Solo's platform-specific instructions. For example,
on Apple Silicon macOS:

```bash
curl -sL \
  https://github.com/agentgateway/agentgateway/releases/latest/download/agctl-darwin-arm64 \
  -o agctl
chmod +x agctl
sudo install agctl /usr/local/bin/agctl
rm agctl

agctl version
```

Then inspect and change the runtime level:

```bash
agctl proxy log "gateway/${AGW_GATEWAY}" \
  -n "$AGW_NAMESPACE"

agctl proxy log "gateway/${AGW_GATEWAY}" \
  -n "$AGW_NAMESPACE" --level debug

agctl proxy log "gateway/${AGW_GATEWAY}" \
  -n "$AGW_NAMESPACE" --set agentgateway::proxy=trace
```

Restore the normal runtime level:

```bash
agctl proxy log "gateway/${AGW_GATEWAY}" \
  -n "$AGW_NAMESPACE" --level info
```

Runtime changes are ephemeral. A pod restart restores the persistent level from
the parameters resource.

Resources:

- [Install agctl](https://docs.solo.io/agentgateway/latest/operations/agctl/)
- [agctl proxy log reference](https://docs.solo.io/agentgateway/latest/reference/agctl/agctl-proxy-log/)
- [Debug agentgateway](https://docs.solo.io/agentgateway/latest/operations/debug/)

## 5. Trace policy evaluation for one request

`agctl proxy trace` opens a port-forward to the proxy admin endpoint and captures
the next request. Inject a request:

```bash
agctl proxy trace "gateway/${AGW_GATEWAY}" \
  -n "$AGW_NAMESPACE" \
  --raw --port "$AGW_LISTENER_PORT" -- \
  "http://${AGW_HOST}/<path>"
```

The URL hostname sets the request's Host header. It is not used for DNS
resolution in inject mode.

Review the route-selection and policy-selection events. The trace can show:

- evaluated and selected routes
- the effective policy at each processing stage
- request snapshots before and after policy execution
- the selected backend and response status

For an interactive terminal UI, omit `--raw`.

To trace the next request from an external client, use watch mode:

```bash
agctl proxy trace "gateway/${AGW_GATEWAY}" \
  -n "$AGW_NAMESPACE"
```

Send the request from another terminal while the trace is waiting.

Request tracing is experimental and not supported for production use. It is
intended for focused troubleshooting, not continuous observability or Datadog
ingestion.

Resources:

- [Trace requests with agctl](https://docs.solo.io/agentgateway/latest/operations/trace-requests/)
- [agctl proxy trace reference](https://docs.solo.io/agentgateway/latest/reference/agctl/agctl-proxy-trace/)
- [Inspect loaded proxy configuration](https://docs.solo.io/agentgateway/latest/operations/inspect-config/)

## 6. Inspect MCP authorization decisions

For MCP authorization, the access log and request trace answer different
questions:

- The access log records the request identity, MCP method, tool, target, and
  terminal MCP error.
- The debug trace records the actual authorization decision and the result of
  every CEL rule.

The trace is the authoritative source for whether an RBAC expression matched.
Access-log CEL does not currently expose an `authorization.result` or
matched-rule variable.

### Capture the actual rule evaluations

Start a trace in watch mode before making the MCP request:

```bash
agctl proxy trace "gateway/${AGW_GATEWAY}" \
  -n "$AGW_NAMESPACE" --raw |
  tee authorization-trace.jsonl
```

Make the MCP tool call from the normal client. Then display only authorization
events:

```bash
jq 'select(.message.type == "authorizationResult")' \
  authorization-trace.jsonl
```

An allowed call can produce an event like:

```json
{
  "message": {
    "type": "authorizationResult",
    "rules": [
      {
        "name": "jwt.sub == \"alice\" && mcp.tool.name == \"get_me\"",
        "matched": true,
        "mode": "allow"
      }
    ],
    "result": "allow"
  }
}
```

The same policy for another subject can produce:

```json
{
  "message": {
    "type": "authorizationResult",
    "rules": [
      {
        "name": "jwt.sub == \"alice\" && mcp.tool.name == \"get_me\"",
        "matched": false,
        "mode": "allow"
      }
    ],
    "result": "deny"
  }
}
```

Each rule entry contains:

- `name`: the original CEL expression
- `matched`: whether the expression evaluated to true
- `mode`: `allow`, `deny`, or `require`
- `result`: the aggregate authorization result

Interpret the aggregate result in this order:

1. Any matching `deny` rule denies the request.
2. Any `require` rule that does not match denies the request.
3. Any matching `allow` rule allows the request.
4. If allow rules exist but none match, the request is denied.
5. If only deny rules exist and none match, the request is allowed.

Prefer `Allow` or `Require` policies. A CEL evaluation error is treated as a
non-match, so a `Deny` expression that fails to evaluate can fail open.

For `tools/list`, the proxy evaluates authorization once for each tool and
silently removes unauthorized tools from the response. A trace can therefore
contain multiple `authorizationResult` events for one list request. For a direct
`tools/call`, the trace is easier to correlate because the request names one
tool.

### Add MCP context to the access log

Add these attributes to the Gateway access-log policy when MCP context is needed
in Datadog:

```yaml
frontend:
  accessLog:
    attributes:
      add:
        - name: mcp_method
          expression: mcp.methodName
        - name: mcp_tool
          expression: mcp.tool.name
        - name: mcp_target
          expression: mcp.tool.target
        - name: mcp_error
          expression: mcp.tool.error
        - name: jwt_subject
          expression: jwt.sub
```

A denied tool call can resemble:

```json
{
  "scope": "request",
  "gateway": "team-gateway/gateway",
  "http.status": 200,
  "mcp_method": "tools/call",
  "mcp_tool": "delete_issue",
  "mcp_target": "github",
  "mcp_error": {
    "code": -32602,
    "message": "Unknown tool: delete_issue"
  },
  "jwt_subject": "bob"
}
```

MCP authorization intentionally hides the existence of unauthorized tools.
Consequently, a denied call is returned as `Unknown tool`, `Unknown prompt`, or
`Unknown resource`, and can use an HTTP success status containing a JSON-RPC
error. Do not rely on HTTP status alone to identify MCP authorization failures.
The same error can also represent a genuinely unknown tool, so correlate it with
an `authorizationResult` trace during troubleshooting.

For a known rule, the access log can repeat the CEL expression as a diagnostic
field:

```yaml
- name: expected_allow
  expression: 'default(jwt.sub == "alice" && mcp.tool.name == "get_me", false)'
```

This field is useful for searching continuous logs, but it is not the actual
authorization-engine result. Keep it synchronized with the RBAC policy and use
the debug trace as the authoritative decision record.

### Add temporary MCP and CEL debug logs

If a rule unexpectedly reports `matched: false`, temporarily enable the MCP RBAC
and CEL modules:

```bash
agctl proxy log "gateway/${AGW_GATEWAY}" \
  -n "$AGW_NAMESPACE" \
  --set agentgateway::mcp::rbac=debug,cel=trace

kubectl --context "$AGW_CONTEXT" logs \
  deployment/"$AGW_GATEWAY" -n "$AGW_NAMESPACE" -f
```

The MCP RBAC debug log identifies the resource being checked. CEL trace logs can
surface evaluation or type-conversion failures. These logs do not provide the
same structured aggregate decision as `agctl proxy trace`.

Restore normal logging after the investigation:

```bash
agctl proxy log "gateway/${AGW_GATEWAY}" \
  -n "$AGW_NAMESPACE" --level info
```

Resources:

- [Control access to MCP tools](https://docs.solo.io/agentgateway/latest/mcp/tool-access/)
- [CEL expressions and MCP variables](https://docs.solo.io/agentgateway/latest/reference/cel/)
- [Trace requests with agctl](https://docs.solo.io/agentgateway/latest/operations/trace-requests/)
- [Agentgateway access logging](https://docs.solo.io/agentgateway/latest/security/access-logging/)

## Recommended troubleshooting sequence

1. Check the Gateway, route, backend, and policy status conditions.
2. Confirm that the expected configuration reached the proxy with `agctl proxy
   config all`.
3. Confirm request access logs locally and in Datadog.
4. Use a single-request trace to verify route and effective-policy selection.
5. Increase one proxy module's log level only if the trace does not explain the
   behavior.
6. Restore normal logging and remove temporary broad access-log policies.

Inspect the loaded runtime configuration:

```bash
agctl proxy config all "gateway/${AGW_GATEWAY}" \
  -n "$AGW_NAMESPACE" -o yaml
```

Remove the example access-log policy when the investigation is complete:

```bash
kubectl --context "$AGW_CONTEXT" delete \
  enterpriseagentgatewaypolicy policy-access-logs \
  -n "$AGW_NAMESPACE"
```
