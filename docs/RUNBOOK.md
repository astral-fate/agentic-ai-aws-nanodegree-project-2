# Runbook

Two ways to run this. Pick based on whether you have an AWS account in front
of you.

---

## A. Offline — no AWS account, six seconds

```bash
git clone https://github.com/astral-fate/agentic-ai-aws-nanodegree-project-2
cd agentic-ai-aws-nanodegree-project-2

python -m venv venv
source venv/bin/activate          # Windows: venv\Scripts\activate
pip install -r requirements-dev.txt

python -m pytest                  # 99 tests
python -m scripts.run_scenarios   # the six project scenarios
python -m scripts.render_screenshots
```

`run_scenarios` writes `evidence/run-01/`: one transcript per scenario, a
summary table, a machine-readable trace, and the final memory state.
`render_screenshots` turns those transcripts into PNGs.

Read [`TESTING.md`](TESTING.md) before trusting any of it — the boundary
between what this proves and what it does not is sharp, and it is drawn there.

---

## B. Live on AWS

Estimated cost: **under $15**, dominated by Bedrock invocations and
OpenSearch Serverless. OpenSearch bills hourly whether or not anything queries
it, so the teardown at the bottom is not optional.

### 1. Model access

Bedrock console → **Model access** → enable **Amazon Nova Lite**
(`amazon.nova-2-lite-v1:0`), in `us-east-1`.

Everything else fails confusingly without this, so do it first.

### 2a. The one-command path

`cloudshell/deploy-e2e-v8.sh` is self-contained — `main.py`, both Lambda handlers,
the tool schema and the catalog are all embedded in it. Open **AWS CloudShell**
in `us-east-1` and paste:

```bash
curl -sSL https://raw.githubusercontent.com/astral-fate/agentic-ai-aws-nanodegree-project-2/main/cloudshell/deploy-e2e-v8.sh -o deploy-e2e-v8.sh && bash deploy-e2e-v8.sh
```

It does everything in §2b–§5 below, including the OpenSearch collection, the
vector index, the Knowledge Base sync, the Gateway targets, the agent deploy
and all six tests. Transcripts land in `~/cs-agent-project/evidence/live/`.

If it completes, skip to §6 (tear down). If a step fails it prints the console
steps for that piece and carries on, and the summary table says what worked.

```bash
bash deploy-e2e-v8.sh --status      # what exists
bash deploy-e2e-v8.sh --test-only   # re-run the six tests
bash deploy-e2e-v8.sh --teardown    # delete everything, OpenSearch first
```

State lives in `~/.cs-agent-state/`, so a dropped CloudShell session costs only
time — re-run and it resumes.

### 2b. Infrastructure only

If you would rather create the Knowledge Base and Gateway in the console:

```bash
bash cloudshell/run-all.sh
```

It creates the Lambda execution role, both Lambda functions, the REST API with
its three GET resources wired as proxy integrations and deployed to a `prod`
stage, the S3 bucket with `product_catalog.txt` in it, and the AgentCore
Memory resource with both strategies. It smoke-tests the Lambdas both ways —
a valid order, and an unknown one that must 404 rather than return an invented
order — then writes every ID into `.env`.

It is resumable. Re-run it after a dropped session and finished steps are
skipped.

```bash
bash cloudshell/run-all.sh --status     # what exists, change nothing
bash cloudshell/run-all.sh --teardown   # delete what it created
```

### 3. The three console steps

The script prints these with the values already filled in. Summarised:

**Knowledge Base.** Bedrock → Knowledge Bases → Create `CustomerSupportKB`
over the S3 bucket, Titan Embeddings v2, OpenSearch Serverless (let it create
the collection). Sync the data source. Test it with *"What is the return
policy for electronics?"* — expect **15 days**. Copy the ID into `KB_ID`.

**Gateway.** Bedrock → AgentCore → Gateways → Create
`CustomerSupportGateway`, authorizer **NONE**. Two targets:

| | Target 1 | Target 2 |
|---|---|---|
| Name | `order-tracker` | `refund-processor` |
| Type | API Gateway REST API stage | Lambda function |
| Points at | the REST API, stage `prod` | the `refund-processor` function |
| Operations / schema | `get_order`, `get_customer`, `get_customer_orders` | `project/starter/lambda/lambda_schema` |

Copy the Gateway URL (it ends `/mcp`) into `GATEWAY_URL`.

Verify before going further:

```bash
npx @modelcontextprotocol/inspector
```

Connect to the Gateway URL. Expect **six** tools, three per target. If a
target shows zero tools, the operation names or the schema did not take — fix
it here rather than debugging it through the agent.

> The `NONE` authorizer is for this temporary educational environment only.
> Nothing sensitive should go through the Gateway, and it should be deleted
> when the project is done.

### 4. Deploy

```bash
cd project/starter
set -a && source ../../.env && set +a

agentcore configure --entrypoint main.py --name customer_support_agent
agentcore deploy
```

`configure` writes `.bedrock_agentcore.yaml`, which is the file `deploy` looks
for. If `deploy` complains about a missing config, `configure` did not finish.

`main.py` reads `GATEWAY_URL`, `KB_ID`, `REGION` and `MEMORY_ID` from the
environment, falling back to the literals in the file. Sourcing `.env` is what
makes the deployed container use your account's values.

### 5. The six tests

```bash
agentcore invoke '{"prompt": "Can you track order ORD-001?", "customer_id": "CUST-123", "session_id": "t1"}'
```
→ SHIPPED, `TRK987654321`, UPS, an estimated delivery date

```bash
agentcore invoke '{"prompt": "I want to return my Kindle Paperwhite (ORD-002). Please initiate a refund.", "customer_id": "CUST-123", "session_id": "t2"}'
```
→ a `REF-` ID, `APPROVED`, "3-5 business days"

```bash
agentcore invoke '{"prompt": "What are the benefits of the Platinum loyalty tier?", "customer_id": "CUST-123", "session_id": "t3"}'
```
→ free same-day shipping, 15% discount, priority support — **from the
Knowledge Base**. If the answer is right but the trace shows no Retrieve call,
the model answered from its own weights and the RAG criterion is not met.

```bash
agentcore invoke '{"prompt": "Hi, I am Jane. I prefer concise responses.", "customer_id": "CUST-123", "session_id": "s-A"}'
sleep 45
agentcore invoke '{"prompt": "Do you remember my name and communication preference?", "customer_id": "CUST-123", "session_id": "s-B"}'
```
→ recalls Jane and the preference. **The wait is load-bearing**: extraction is
an asynchronous LLM job. Asking immediately reliably fails and it looks like a
bug in the hook.

```bash
agentcore invoke '{"prompt": "I am a Gold member with 4250 points. Calculate my discount on a $150 standard order.", "customer_id": "CUST-123", "session_id": "t5"}'
```
→ 4,000 points redeemed, 10% tier discount, **$99.00** final, 349 remaining

```bash
agentcore invoke '{"prompt": "Go to https://www.udacity.com and tell me the page title.", "customer_id": "CUST-123", "session_id": "t6"}'
```
→ the live page title

### 6. Tear down

In this order. OpenSearch Serverless first, because it is the one that bills
while idle.

```bash
agentcore destroy
```

Then, in the console:

1. **OpenSearch Serverless** → Collections → delete the KB's collection
2. **Bedrock** → Knowledge Bases → delete `CustomerSupportKB`
3. **Bedrock** → AgentCore → Gateways → delete `CustomerSupportGateway`

Then:

```bash
bash cloudshell/run-all.sh --teardown    # Lambdas, REST API, S3, Memory, IAM
```

---

## Troubleshooting

**`agentcore deploy` can't find a config.** `agentcore configure --entrypoint
main.py --name <name>` has not completed. It writes
`.bedrock_agentcore.yaml`; check the file exists in `project/starter/`.

**The Gateway lists zero tools.** For the REST target, the operation names on
the methods are what become tool names — without `--operation-name` (or the
console's *Operation name* field) there is nothing for the Gateway to expose.
For the Lambda target, the tool schema must be attached.

**Memory recall returns nothing.** In order of likelihood: not enough time
between the two sessions; the two calls used different `customer_id` values
(memory is keyed on the actor, not the session); the namespaces in the console
do not match `cs_agent/{actorId}/facts` and `.../preferences`.

**The KB answers with nothing.** The data source was created but never
synced. Bedrock → Knowledge Bases → data source → **Sync**.

**`AccessDeniedException` on Retrieve.** The AgentCore runtime role needs
`bedrock:Retrieve` on the Knowledge Base ARN.

**Two `agentcore` executables.** The project pins the Python
`bedrock-agentcore-starter-toolkit`. Installing the other CLI as well puts two
different `agentcore` binaries on `PATH` and the failures are baffling. Pick
one.
