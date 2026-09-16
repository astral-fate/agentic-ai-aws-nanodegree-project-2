# Console screenshots

Captured by `scripts/capture_console.py`, which drives a real Chrome
session against the real AWS console. Pages that did not paint are
reported as BLANK and not listed here.

| File | Shows | Console location |
|---|---|---|
| `03-knowledge-base.png` | Bedrock → Knowledge Bases → CustomerSupportKB, data source synced. | `https://us-east-1.console.aws.amazon.com/bedrock/home?region=us-east-1#/knowledge-bases/QVNFXUYT22` |
| `05-lambda-functions.png` | Lambda → order-tracker and refund-processor. | `https://us-east-1.console.aws.amazon.com/lambda/home?region=us-east-1#/functions` |
| `06-api-gateway-resources.png` | API Gateway → cs-agent-order-api: the three GET methods, each carrying the operation name the Gateway exposes as a tool. | `https://us-east-1.console.aws.amazon.com/apigateway/main/apis/e5xvrt2660/resources?api=e5xvrt2660&region=us-east-1#` |
| `07-opensearch-collection.png` | OpenSearch Serverless → the vector store behind the Knowledge Base. | `https://us-east-1.console.aws.amazon.com/aos/home?region=us-east-1#opensearch/collections` |
| `08-s3-bucket.png` | S3 → the Knowledge Base source bucket with product_catalog.txt. | `https://us-east-1.console.aws.amazon.com/s3/buckets/cs-agent-kb-212626318772?region=us-east-1&tab=objects` |
| `09-lambda-cloudwatch-logs.png` | CloudWatch → the order-tracker log group: real invocations, which is stronger evidence than a console test click. | `https://us-east-1.console.aws.amazon.com/cloudwatch/home?region=us-east-1#logsV2:log-groups/log-group/$252Faws$252Flambda$252Forder-tracker` |
