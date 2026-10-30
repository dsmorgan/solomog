# direct response sample for agentgateway

simple add on to enable /healthz endpoint that always returns status: ok

Enterprise only. The route attaches to Gateway `agw`. The [Quickstart](../../README.md#enterprise) applies this bundle in the install command, then runs `solomog test` once the gateway is ready.

```bash
solomog bundles:show BUNDLE=agw-directresponse
solomog apply BUNDLE=agw-directresponse CLUSTER=<cluster>
solomog test BUNDLE=agw-directresponse CLUSTER=<cluster>
kubectl --context vcluster-docker_<cluster> get httproute,EnterpriseAgentgatewayPolicy -n agentgateway-system
```
