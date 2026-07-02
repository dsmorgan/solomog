# demonstrated multiple route LLM failover in agw

Install with new cluster:

`solomog agentgateway:ui apps:mock-openai expose apply ROUTE=true BUNDLE=mock-openai-override-failover2 CLUSTER=<cluster>`

Test/validate:

`solomog test `BUNDLE=mock-openai-override-failover2` CLUSTER=a5`

