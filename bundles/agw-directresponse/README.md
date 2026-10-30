# direct response sample for agentgateway

simple add on to enable /healthz endpoint that always returns status: ok

Enterprise only. The route attaches to Gateway `agw`, so run it after `solomog agentgateway expose` on an enterprise cluster. The [Quickstart](../../README.md#enterprise) does that, then runs the test.

```bash
solomog bundles:show BUNDLE=agw-directresponse
solomog apply BUNDLE=agw-directresponse CLUSTER=<cluster>
solomog test BUNDLE=agw-directresponse CLUSTER=<cluster>
kubectl --context vcluster-docker_<cluster> get httproute,EnterpriseAgentgatewayPolicy -n agentgateway-system
```
