# Console screenshots — live AWS

Captured by `scripts/capture_console.py`, which signs a headless Chrome
into the console with `sts:GetFederationToken` and loads each page for
real. A page whose content pane never painted is reported BLANK and is
not committed.

Account 212626318772 · us-east-1 · signed in as the read-only
`evidence-capture` IAM user.

| File | Shows |
|---|---|
| `03-knowledge-base.png` | Bedrock → Knowledge Bases: CustomerSupportKB, Available, 1 data source |
| `05-lambda-functions.png` | Lambda → order-tracker and refund-processor |
| `06-api-gateway-resources.png` | API Gateway → the `cs-agent-order-api` REST API (list view, not its resources) |
| `07-opensearch-collection.png` | OpenSearch Serverless → the vector store |
| `08-s3-bucket.png` | S3 → product_catalog.txt, the Knowledge Base source |
| `09-lambda-cloudwatch-logs.png` | CloudWatch → order-tracker invocations |

## Not captured

The three AgentCore console pages — Runtime, Gateways and Memory — are not
here. Every fragment route tried landed on the AgentCore service overview,
which is product description rather than evidence of these resources, so
it was deleted rather than filed as though it showed something.

Those three capabilities are evidenced instead by the live transcripts in
`../transcripts-live/`, which are stronger: they show the agent actually
using memory, the gateway and the runtime rather than a list page saying
they exist.


## A note on the BLANK detector

It classifies by rendered text length, and two of the pages kept here were
flagged BLANK on a later run: the API Gateway list (896 chars) and the
CloudWatch log group (747 chars). Both render correctly — they are simply
sparse. The threshold was raised to 1200 because the Bedrock console's left
navigation alone clears 1000, which let a genuinely empty content pane through.

So the check errs toward false positives now. That is the right direction —
every image here was looked at before being committed, and a page wrongly
called blank costs a re-run, while a blank page wrongly called evidence is a
falsified record.
