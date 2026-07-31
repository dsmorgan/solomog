# Agentgateway policy logging lab

A self-contained, local-only lab for comparing persistent proxy logging, runtime
log-level changes, access logs, and per-request policy traces. It creates:

- `EnterpriseAgentgatewayParameters/policy-logging` with JSON `info` logs
- an `/logging/healthz` direct-response route and policy
- a Gateway-wide access-log policy with recognizable `solomog.*` attributes

The bundle expects the enterprise agentgateway and an exposed Gateway named `agw`.

## Create the lab

```bash
solomog agentgateway expose apply \
  BUNDLE=agw-policy-logging \
  CLUSTER=citizens-logging

solomog test \
  BUNDLE=agw-policy-logging \
  CLUSTER=citizens-logging
```

For the Solo UI and metrics dashboards too:

```bash
solomog agentgateway:ui monitoring expose apply \
  ROUTE=true \
  BUNDLE=agw-policy-logging \
  CLUSTER=citizens-logging
```

`monitoring` installs Prometheus and Grafana metrics. It does not collect logs.
`agentgateway:ui` adds OTEL request tracing, which is separate from the `agctl`
debug trace used below.

## Install agctl for Solo Enterprise

Solo does not publish a separate enterprise-only `agctl` binary. The
[Solo Enterprise installation guide](https://docs.solo.io/agentgateway/latest/operations/agctl/)
installs the shared `agctl` binary from the agentgateway GitHub releases. The
enterprise-specific APIs and behavior come from the Solo Enterprise control
plane, CRDs, and proxy installed by solomog.

`agctl` is experimental and unsupported for production. Install the current
Apple Silicon binary as documented by Solo:

```bash
curl -fL \
  https://github.com/agentgateway/agentgateway/releases/latest/download/agctl-darwin-arm64 \
  -o /tmp/agctl
chmod +x /tmp/agctl
sudo install /tmp/agctl /usr/local/bin/agctl
rm /tmp/agctl

agctl version
```

Intel macOS uses `agctl-darwin-amd64` instead. Solo recommends using an `agctl`
version compatible with the agentgateway version in the cluster; avoid major
version skew. Verify that the CLI can inspect this enterprise-managed proxy:

```bash
agctl proxy config all gateway/agw \
  -n agentgateway-system -o yaml
```

## 1. Persistent level and format

The parameters resource starts with `level: info` and `format: json`. Follow the
proxy logs:

```bash
kubectl --context vcluster-docker_citizens-logging \
  logs -n agentgateway-system deployment/agw -f
```

Change one module persistently:

```bash
kubectl --context vcluster-docker_citizens-logging \
  patch enterpriseagentgatewayparameters policy-logging \
  -n agentgateway-system --type=merge \
  -p '{"spec":{"logging":{"level":"info,agentgateway::proxy=debug","format":"json"}}}'

kubectl --context vcluster-docker_citizens-logging \
  rollout status -n agentgateway-system deployment/agw
```

This is declarative and survives a pod replacement, but controller reconciliation
can roll the proxy. Reapply the bundle to restore JSON `info` logging.

## 2. Runtime level change

Runtime changes use the admin API and do not restart the proxy:

```bash
agctl proxy log gateway/agw -n agentgateway-system
agctl proxy log gateway/agw -n agentgateway-system --level debug
agctl proxy log gateway/agw -n agentgateway-system

# Restore the runtime level.
agctl proxy log gateway/agw -n agentgateway-system --level info
```

Runtime settings are ephemeral. A proxy restart returns to the parameters
resource's persistent setting.

## 3. Access logs

Generate a successful policy response and a missing-route response:

```bash
curl -i https://agw.citizens-logging.test/logging/healthz
curl -i https://agw.citizens-logging.test/logging/missing
```

The proxy's JSON logs include `solomog.bundle`, `solomog.request_path`,
`solomog.request_method`, and `solomog.status_code` attributes:

```bash
kubectl --context vcluster-docker_citizens-logging \
  logs -n agentgateway-system deployment/agw --since=5m |
  grep 'solomog.bundle'
```

To demonstrate selective audit logging, add this field under
`spec.frontend.accessLog` in `40-access-logs.yaml.tmpl`, then reapply:

```yaml
filter: response.code >= 400
```

The missing request is then logged and the successful request is not.

## 4. Trace effective policy selection

Inject a request through the proxy's admin port. The URL host sets the HTTP Host
header; `agctl` sends the request through its port-forward rather than resolving
the hostname.

```bash
agctl proxy trace gateway/agw -n agentgateway-system \
  --raw --port 8080 -- \
  http://agw.citizens-logging.test/logging/healthz
```

Omit `--raw` for the interactive TUI. Look for route-selection and
policy-selection events, especially the effective direct-response policy.

Watch mode traces the next request from any client:

```bash
agctl proxy trace gateway/agw -n agentgateway-system
```

Then run the curl request in another terminal.

## Demonstrate a policy attachment failure

Point the direct-response policy at a nonexistent route:

```bash
kubectl --context vcluster-docker_citizens-logging \
  patch enterpriseagentgatewaypolicy logging-direct-response \
  -n agentgateway-system --type=merge \
  -p '{"spec":{"targetRefs":[{"group":"gateway.networking.k8s.io","kind":"HTTPRoute","name":"missing-route"}]}}'

solomog routes CLUSTER=citizens-logging WIDE=true
solomog graph CLUSTER=citizens-logging
```

Repeat the trace. The direct-response policy is absent from the effective policy
set; the resource status and route graph explain why. Restore the known-good
configuration and retest:

```bash
solomog apply test \
  BUNDLE=agw-policy-logging \
  CLUSTER=citizens-logging
```

Use `rawConfig` only for proxy configuration that has no typed field. Logging
level and format are typed, validated fields, so `rawConfig` adds risk without
helping this lab.
