# AWS Bedrock routing (SSO temp credentials)

Path-per-model routes to AWS Bedrock backends on agentgateway, authenticated with
short-lived AWS SSO credentials. Cheap subset of the workshop set.

## Routes
- `/bedrock/haiku`     → Claude Haiku 4.5  (`us.anthropic.claude-haiku-4-5-20251001-v1:0`)
- `/bedrock/mistral`   → Mistral Voxtral Mini (`mistral.voxtral-mini-3b-2507`)
- `/bedrock/llama3-8b` → Llama 3.1 8B      (`meta.llama3-1-8b-instruct-v1:0`)
- `/bedrock`           → catch-all → mistral

All backends pin `region: us-west-2`.

## Credentials (SSO)
Auth uses temporary SSO credentials (access key + secret + **session token**) that expire
with the SSO session (≤12h). One-time setup:
```bash
aws configure sso          # session name: SOlo, start URL https://soloio.awsapps.com/start#/, region us-east-1
```
Then set `AWS_PROFILE` in `.env` to the profile that created (so `aws:refresh` targets it).

Refresh + apply (mirrors `gcp:refresh`):
```bash
solomog aws:refresh apply BUNDLE=llmroute-bedrock CLUSTER=<cluster>
```
`aws:refresh` exports fresh creds into `.env` (running `aws sso login` first if the session
is stale); re-applying the bundle pushes them into the `bedrock-secret`. The creds are
short-lived (≤12h) — re-run the command above manually whenever a route starts returning
401/403/ExpiredToken.

## Test
```bash
solomog test BUNDLE=llmroute-bedrock CLUSTER=<cluster>
```

## Notes
- `policies.ai` (`promptCaching: {}`) is added to every backend — required by the CEL rule on
  enterprise agentgateway **2.3.x** (the workshop manifests omit it; they target CalVer).
- The API-key auth variant (long/short-term Bedrock Bearer key, `policies.auth.secretRef`)
  is an alternative not built here — it needs a console-generated key and doesn't pair with
  an SSO refresh.
