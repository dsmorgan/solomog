# Snowflake setup — recreate runbook (agw-okta-mcp Snowflake elicitation backend)

Everything on the **Snowflake side** for the elicitation → Snowflake-managed-MCP flow. Run in a
Snowsight **SQL File** (`+` → SQL File) as `ACCOUNTADMIN` with a warehouse selected.

Architecture: user (Okta JWT) → agentgateway `/snowflake/mcp` → **elicitation** (browser OAuth
consent against Snowflake) → gateway replays the user's Snowflake token → **Snowflake-managed
MCP server** → Cortex Analyst tool over a semantic view on the built-in sample data.

> **Newer-object grammar warning:** `CREATE SEMANTIC VIEW` and `CREATE MCP SERVER` are recent
> and their grammar is exact. **Run steps 2–3 one at a time**; if either errors, paste the exact
> message and we'll adjust — the surrounding steps are standard and safe.

---

## Step 1 — OAuth security integration ✅ (already done)

```sql
CREATE SECURITY INTEGRATION IF NOT EXISTS AGW_MCP_OAUTH
  TYPE = OAUTH  ENABLED = TRUE
  OAUTH_CLIENT = CUSTOM  OAUTH_CLIENT_TYPE = 'CONFIDENTIAL'
  OAUTH_REDIRECT_URI = 'https://ui.agw.a8.test/age/elicitations'
  OAUTH_ISSUE_REFRESH_TOKENS = TRUE  OAUTH_REFRESH_TOKEN_VALIDITY = 86400;
SELECT SYSTEM$SHOW_OAUTH_CLIENT_SECRETS('AGW_MCP_OAUTH');   -- client id/secret → .env
```
(Redirect URI is changeable later without recreating: `ALTER SECURITY INTEGRATION AGW_MCP_OAUTH SET OAUTH_REDIRECT_URI='…'`.)

## Step 2 — Demo DB/warehouse + a non-admin role (OAuth blocks ACCOUNTADMIN)

```sql
USE ROLE ACCOUNTADMIN;
CREATE DATABASE  IF NOT EXISTS AGW_DEMO;
CREATE WAREHOUSE IF NOT EXISTS AGW_WH
  WAREHOUSE_SIZE=XSMALL AUTO_SUSPEND=60 AUTO_RESUME=TRUE INITIALLY_SUSPENDED=TRUE;

-- The role you'll pick at the Snowflake consent screen (ACCOUNTADMIN/SECURITYADMIN are blocked for OAuth)
CREATE ROLE IF NOT EXISTS AGW_ANALYST;
GRANT USAGE ON WAREHOUSE AGW_WH               TO ROLE AGW_ANALYST;
GRANT USAGE ON DATABASE  AGW_DEMO             TO ROLE AGW_ANALYST;
GRANT USAGE ON SCHEMA    AGW_DEMO.PUBLIC      TO ROLE AGW_ANALYST;
GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE_SAMPLE_DATA TO ROLE AGW_ANALYST;  -- sample data
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER      TO ROLE AGW_ANALYST;               -- required for Cortex
GRANT ROLE AGW_ANALYST TO USER DAVID_MORGAN;   -- so you can select it at consent
```

## Step 3 — Semantic view over the sample TPC-H data (single table = simplest valid form)

```sql
USE ROLE ACCOUNTADMIN; USE WAREHOUSE AGW_WH;
CREATE OR REPLACE SEMANTIC VIEW AGW_DEMO.PUBLIC.TPCH_ANALYST
  TABLES (
    orders AS SNOWFLAKE_SAMPLE_DATA.TPCH_SF1.ORDERS PRIMARY KEY (O_ORDERKEY)
  )
  DIMENSIONS (
    orders.order_status   AS orders.O_ORDERSTATUS,
    orders.order_priority AS orders.O_ORDERPRIORITY,
    orders.order_date     AS orders.O_ORDERDATE
  )
  METRICS (
    orders.total_revenue AS SUM(orders.O_TOTALPRICE),
    orders.order_count   AS COUNT(orders.O_ORDERKEY)
  );
GRANT REFERENCES ON SEMANTIC VIEW AGW_DEMO.PUBLIC.TPCH_ANALYST TO ROLE AGW_ANALYST;
```

## Step 4 — Managed MCP server exposing the semantic view as a Cortex Analyst tool

```sql
CREATE OR REPLACE MCP SERVER AGW_DEMO.PUBLIC.SNOWFLAKE_MCP
  FROM SPECIFICATION $$
tools:
  - name: "tpch-analyst"
    type: "CORTEX_ANALYST_MESSAGE"
    identifier: "AGW_DEMO.PUBLIC.TPCH_ANALYST"
    description: "Ask natural-language questions about TPC-H orders (revenue, counts by status/priority/date)."
    title: "TPC-H Orders Analyst"
$$;
GRANT USAGE ON MCP SERVER AGW_DEMO.PUBLIC.SNOWFLAKE_MCP TO ROLE AGW_ANALYST;
```

Resulting MCP endpoint (what the gateway backend targets):
```
https://<account>/api/v2/databases/AGW_DEMO/schemas/PUBLIC/mcp-servers/SNOWFLAKE_MCP
```
These names map to `.env`: `SNOWFLAKE_MCP_DATABASE=AGW_DEMO`, `SNOWFLAKE_MCP_SCHEMA=PUBLIC`,
`SNOWFLAKE_MCP_SERVER=SNOWFLAKE_MCP` (all default, so you can leave them blank).

---

## OAuth scope — must be `session:role:<ROLE>`, not `session:role-any`
Snowflake OAuth **CUSTOM** clients (this integration) require a **specific role** scope:
`session:role:AGW_ANALYST refresh_token`. The `session:role-any` scope is an **External OAuth**
feature (requires `OAUTH_ANY_ROLE_MODE`) — with a custom client Snowflake's authorize endpoint
rejects it with *"Error occurred in authorization — The requested scope is invalid."* The bundle
default is now the specific-role form; override per-role via `SNOWFLAKE_OAUTH_SCOPES` in `.env`.
Because the scope pins the role, the consent screen no longer prompts you to pick one.

## At the browser consent screen (during elicitation)
The token is pre-scoped to **`AGW_ANALYST`** (via the scope above; not ACCOUNTADMIN — it's blocked
for OAuth). That's the identity Snowflake evaluates for the Cortex Analyst query — the whole point
of the per-user elicitation flow. Log into Snowflake as a user that has `AGW_ANALYST` granted
(SNOWFLAKE-SETUP grants it to `DAVID_MORGAN`).
