# multi-service MCP path based routing


Install:

`solomog agentgateway:ui expose apply ROUTE=true BUNDLE=mcp-multiple-backend CLUSTER=<cluster>`

Test:

`solomog test BUNDLE=mcp-multiple-backend CLUSTER=a6`


In addition to the tests, theat just check list tools for each endpoint, 

use `npx @modelcontextprotocol/inspector` to further explore the capabilities of each endpoint.
