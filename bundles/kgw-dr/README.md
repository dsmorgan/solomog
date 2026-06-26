# direct response sample for kgateway

simple add on to enable /healthz endpoint that always returns status: ok

```bash
solomog bundles:show BUNDLE=kgw-dr
solomog apply BUNDLE=kgw-dr CLUSTER=<cluster>
kubectl --context vcluster-docker_<cluster> get httproute,directresponse -n kgateway-system
```
