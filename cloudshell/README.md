# Deploying from AWS CloudShell

CloudShell already has the AWS CLI, credentials, Python and `jq`, which is why
the live path runs there rather than on a laptop.

```bash
git clone https://github.com/astral-fate/agentic-ai-aws-nanodegree-project-2
cd agentic-ai-aws-nanodegree-project-2
bash cloudshell/run-all.sh
```

```bash
bash cloudshell/run-all.sh --status     # what exists, change nothing
bash cloudshell/run-all.sh --teardown   # delete what the script created
```

## What it does

Deterministically, without asking:

1. **Preflight** — identity, region, and whether Nova 2 Lite is actually
   visible. The model-access check is first on purpose: without the grant
   everything downstream fails in confusing ways, and it is a two-click fix.
2. **IAM** — a Lambda execution role with `AWSLambdaBasicExecutionRole`, then
   a deliberate 30-second pause. IAM is eventually consistent and Lambda
   rejects a role it cannot see yet; the pause is cheaper than the retry loop.
3. **Lambda** — zips and deploys `order_tracker.py` and
   `refund_processor.py` from `project/starter/lambda/`, unmodified.
4. **Smoke tests** — three of them, and the second is the one that matters:
   - `ORD-001` returns `TRK987654321`
   - `ORD-999` returns **404**, rather than an invented order
   - the refund handler, called with the Gateway's base64 client context,
     strips the `refund-processor___` prefix and approves
5. **API Gateway** — a REST API with `/orders/{order_id}`,
   `/customers/{customer_id}` and `/customers/{customer_id}/orders`, each a
   Lambda proxy integration carrying the `operationName` that becomes its MCP
   tool name, deployed to a `prod` stage, then curled to confirm it answers.
6. **S3** — a bucket with `product_catalog.txt` in it.
7. **AgentCore Memory** — `CustomerSupportMemory` with both strategies on the
   namespaces `main.py` expects.
8. **`.env`** — every ID it created, ready to source.

It is **resumable**. State is kept in `~/.cs-agent-state/`, and re-running
skips anything that already exists. Safe to paste again after a dropped
session.

It **never deletes working resources**. Teardown is a separate, confirmed
flag.

## What it does not do

Three steps stay in the console, and the script prints them with your values
already filled in:

- **the Knowledge Base**, because creating one from the CLI means first
  hand-building an OpenSearch Serverless collection plus an encryption policy,
  a network policy, a data-access policy and a vector index — a lot of surface
  area to get wrong in a script that is supposed to be safely re-runnable
- **the Gateway and its two targets**
- **`agentcore configure` / `agentcore deploy`**

## Cost

Under $15 for the whole project, and the shape of it is worth knowing:

| | |
|---|---|
| Lambda, API Gateway, S3, DynamoDB | effectively free at this volume |
| Gateway, Memory, the agent at rest | nothing |
| Bedrock invocations | per token, scales with how much you test |
| **OpenSearch Serverless** | **per OCU-hour, whether or not anything queries it** |

The last row is the one that empties a student budget. It bills while idle.
Delete the collection first when tearing down — before the Knowledge Base,
because deleting the Knowledge Base does not take the collection with it.

## Reading it before running it

[`run-all.sh`](run-all.sh) is plain bash with no packing or encoding — the
whole thing is meant to be read before you paste it. Every AWS-mutating call
is inside a function named for what it creates.
