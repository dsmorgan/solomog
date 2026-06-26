# direct response sample for agentgateway

simple add on to enable /healthz endpoint that always returns status: ok

```bash
solomog bundles:show BUNDLE=agw-dr
solomog apply BUNDLE=agw-dr CLUSTER=<cluster>
kubectl --context vcluster-docker_<cluster> get httproute,EnterpriseAgentgatewayPolicy -n agentgateway-system
```
