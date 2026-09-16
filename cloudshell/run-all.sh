#!/usr/bin/env bash
#
# Deploy the customer support agent's backing infrastructure from AWS CloudShell.
#
#   bash run-all.sh              deploy everything it can, print what remains
#   bash run-all.sh --status     show what already exists, change nothing
#   bash run-all.sh --teardown   delete everything this script created
#
# Honest scope. This automates the parts the AWS CLI does deterministically:
#
#     [auto]  preflight — identity, region, Nova 2 Lite model access
#     [auto]  IAM execution role for both Lambdas
#     [auto]  order-tracker and refund-processor Lambda functions
#     [auto]  REST API with the three GET resources, wired as proxy
#             integrations, deployed to a stage
#     [auto]  S3 bucket, product_catalog.txt uploaded
#     [auto]  AgentCore Memory resource with both strategies
#     [auto]  smoke tests against the deployed Lambdas
#     [auto]  writes .env with every ID the agent needs
#
# Three things stay in the console, because doing them from the CLI means
# hand-building an OpenSearch Serverless collection, an encryption policy, a
# network policy, a data-access policy and a vector index before the Knowledge
# Base will even accept the call. That is a lot of surface area to get wrong in
# a script you cannot re-run safely:
#
#     [manual] Bedrock Knowledge Base over the S3 bucket
#     [manual] AgentCore Gateway + its two targets
#     [manual] agentcore configure / deploy
#
# The script prints exact click-by-click steps for those, with the values
# already filled in.
#
# Resumable: re-running skips anything that already exists. Safe to paste
# again after a CloudShell session drops.

set -uo pipefail

REGION="${AWS_REGION:-us-east-1}"
PREFIX="${PREFIX:-cs-agent}"
ROLE_NAME="${PREFIX}-lambda-role"
ORDER_FN="order-tracker"
REFUND_FN="refund-processor"
API_NAME="${PREFIX}-order-api"
STAGE="prod"
MEMORY_NAME="CustomerSupportMemory"
MODEL_ID="global.amazon.nova-2-lite-v1:0"

STATE_DIR="${HOME}/.${PREFIX}-state"
ENV_FILE="${PWD}/.env"

mkdir -p "$STATE_DIR"

# ── Output helpers ───────────────────────────────────────────────────────────
BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; RED=$'\033[31m'
YELLOW=$'\033[33m'; CYAN=$'\033[36m'; RESET=$'\033[0m'

step()  { printf '\n%s==>%s %s%s%s\n' "$CYAN" "$RESET" "$BOLD" "$*" "$RESET"; }
ok()    { printf '  %s[ ok ]%s %s\n' "$GREEN" "$RESET" "$*"; }
skip()  { printf '  %s[skip]%s %s\n' "$DIM" "$RESET" "$*"; }
warn()  { printf '  %s[warn]%s %s\n' "$YELLOW" "$RESET" "$*"; }
fail()  { printf '  %s[fail]%s %s\n' "$RED" "$RESET" "$*"; }
die()   { fail "$*"; exit 1; }

save()  { printf '%s' "$2" > "$STATE_DIR/$1"; }
load()  { cat "$STATE_DIR/$1" 2>/dev/null || true; }

# ── Locate the repo files ────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LAMBDA_DIR="$REPO_ROOT/project/starter/lambda"
CATALOG="$REPO_ROOT/project/starter/product_catalog.txt"

# ── Preflight ────────────────────────────────────────────────────────────────
preflight() {
  step "Preflight"

  command -v aws >/dev/null || die "aws CLI not found. Run this in AWS CloudShell."
  command -v jq  >/dev/null || die "jq not found."

  local identity account arn
  identity="$(aws sts get-caller-identity --output json 2>/dev/null)" \
    || die "No AWS credentials. In CloudShell this should already work."
  account="$(jq -r .Account <<<"$identity")"
  arn="$(jq -r .Arn <<<"$identity")"
  ok "account $account"
  ok "identity $arn"
  save account "$account"

  case "$arn" in
    *":root") warn "Running as root. Root has no permission boundary and its keys cannot be scoped per-service — see docs/SECURITY.md." ;;
  esac

  ok "region $REGION"

  [[ -f "$LAMBDA_DIR/order_tracker.py"    ]] || die "missing $LAMBDA_DIR/order_tracker.py"
  [[ -f "$LAMBDA_DIR/refund_processor.py" ]] || die "missing $LAMBDA_DIR/refund_processor.py"
  [[ -f "$CATALOG" ]] || die "missing $CATALOG"
  ok "starter files present"

  # Check model access up front: a missing grant should fail in seconds, not
  # forty minutes into the build.
  if aws bedrock get-foundation-model \
       --model-identifier "amazon.nova-2-lite-v1:0" \
       --region "$REGION" >/dev/null 2>&1; then
    ok "Nova 2 Lite visible in $REGION"
  else
    warn "Could not confirm Nova 2 Lite access."
    warn "Enable it: Bedrock console → Model access → Amazon Nova Lite."
  fi

  check_permissions
}

# Fail on the whole list of missing permissions, not on the first one.
#
# Written after running this against an IAM user scoped to an unrelated
# project: without it, the script dies at "could not create <role>", which
# reads like a name clash rather than what it is. Each probe below is a
# read-only call that requires the same permission as the write that follows
# later, so a pass here means the deploy will get that far.
check_permissions() {
  local missing=()

  aws iam list-roles --max-items 1 >/dev/null 2>&1 \
    || missing+=("iam:ListRoles / iam:CreateRole      — the Lambda execution role")
  aws lambda list-functions --max-items 1 --region "$REGION" >/dev/null 2>&1 \
    || missing+=("lambda:ListFunctions / CreateFunction — both Lambda targets")
  aws apigateway get-rest-apis --region "$REGION" >/dev/null 2>&1 \
    || missing+=("apigateway:GET / POST                 — the order-tracker REST API")
  aws s3api list-buckets --region "$REGION" >/dev/null 2>&1 \
    || missing+=("s3:ListAllMyBuckets / CreateBucket    — the Knowledge Base source")
  aws bedrock-agentcore-control list-memories --region "$REGION" >/dev/null 2>&1 \
    || missing+=("bedrock-agentcore:*Memor*             — AgentCore Memory")

  if [[ ${#missing[@]} -eq 0 ]]; then
    ok "all required permissions present"
    return 0
  fi

  fail "This identity cannot deploy the project. Missing:"
  printf '\n'
  local entry
  for entry in "${missing[@]}"; do
    printf '      %s\n' "$entry"
  done

  cat <<EOF

  Nothing has been created — this check runs before the first write.

  The usual cause is credentials for a different project. Use the Udacity
  Cloud Lab credentials (Cloud Resources tab → generate access keys), or an
  IAM principal with IAM, Lambda, API Gateway, S3, Bedrock and
  bedrock-agentcore permissions in $REGION.

    export AWS_ACCESS_KEY_ID=...
    export AWS_SECRET_ACCESS_KEY=...
    export AWS_SESSION_TOKEN=...
    export AWS_REGION=$REGION

  In AWS CloudShell this is already configured and this check passes.

  To work offline instead, with no AWS account at all:
    python -m pytest
    python -m scripts.run_scenarios

EOF
  exit 1
}

# ── IAM ──────────────────────────────────────────────────────────────────────
ensure_role() {
  step "Lambda execution role"

  local existing
  existing="$(aws iam get-role --role-name "$ROLE_NAME" \
                --query 'Role.Arn' --output text 2>/dev/null)"
  if [[ -n "$existing" && "$existing" != "None" ]]; then
    skip "$ROLE_NAME already exists"
    save role_arn "$existing"
    return
  fi

  local trust='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
  local arn
  arn="$(aws iam create-role --role-name "$ROLE_NAME" \
          --assume-role-policy-document "$trust" \
          --query 'Role.Arn' --output text)" || die "could not create $ROLE_NAME"

  aws iam attach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

  ok "created $ROLE_NAME"
  save role_arn "$arn"

  # IAM is eventually consistent; Lambda rejects a role it cannot see yet.
  printf '  waiting for IAM propagation '
  for _ in $(seq 1 15); do printf '.'; sleep 2; done
  printf '\n'
}

# ── Lambda ───────────────────────────────────────────────────────────────────
deploy_lambda() {
  local name="$1" source="$2"
  local zip="/tmp/${name}.zip"

  rm -f "$zip"
  (cd "$(dirname "$source")" && zip -q "$zip" "$(basename "$source")")
  # The handler must be <module>.lambda_handler, so the file keeps its name.
  local handler
  handler="$(basename "$source" .py).lambda_handler"

  if aws lambda get-function --function-name "$name" --region "$REGION" >/dev/null 2>&1; then
    aws lambda update-function-code --function-name "$name" \
      --zip-file "fileb://$zip" --region "$REGION" >/dev/null \
      || { fail "could not update $name"; return 1; }
    aws lambda wait function-updated --function-name "$name" --region "$REGION"
    ok "updated $name"
  else
    aws lambda create-function --function-name "$name" \
      --runtime python3.12 --role "$(load role_arn)" \
      --handler "$handler" --zip-file "fileb://$zip" \
      --timeout 30 --memory-size 256 --region "$REGION" >/dev/null \
      || { fail "could not create $name"; return 1; }
    aws lambda wait function-active --function-name "$name" --region "$REGION"
    ok "created $name"
  fi

  local arn
  arn="$(aws lambda get-function --function-name "$name" --region "$REGION" \
          --query 'Configuration.FunctionArn' --output text)"
  save "${name}_arn" "$arn"
}

deploy_lambdas() {
  step "Lambda functions"
  deploy_lambda "$ORDER_FN"  "$LAMBDA_DIR/order_tracker.py"
  deploy_lambda "$REFUND_FN" "$LAMBDA_DIR/refund_processor.py"
}

smoke_test_lambdas() {
  step "Lambda smoke tests"

  local out
  out="$(aws lambda invoke --function-name "$ORDER_FN" --region "$REGION" \
          --cli-binary-format raw-in-base64-out \
          --payload '{"resource":"/orders/{order_id}","httpMethod":"GET","pathParameters":{"order_id":"ORD-001"}}' \
          /tmp/order-out.json --query StatusCode --output text 2>/dev/null)"

  if [[ "$out" == "200" ]] && jq -e '.body | fromjson | .tracking_number == "TRK987654321"' \
       /tmp/order-out.json >/dev/null 2>&1; then
    ok "order-tracker returns TRK987654321 for ORD-001"
  else
    fail "order-tracker smoke test failed: $(cat /tmp/order-out.json 2>/dev/null)"
  fi

  # A missing order must 404 rather than invent one.
  aws lambda invoke --function-name "$ORDER_FN" --region "$REGION" \
    --cli-binary-format raw-in-base64-out \
    --payload '{"resource":"/orders/{order_id}","httpMethod":"GET","pathParameters":{"order_id":"ORD-999"}}' \
    /tmp/order-404.json >/dev/null 2>&1
  if jq -e '.statusCode == 404' /tmp/order-404.json >/dev/null 2>&1; then
    ok "order-tracker 404s on an unknown order"
  else
    fail "order-tracker did not 404 on ORD-999"
  fi

  # The refund tool name arrives in the client context, base64-encoded.
  local ctx
  ctx="$(printf '{"custom":{"bedrockAgentCoreToolName":"refund-processor___initiate_refund"}}' | base64 | tr -d '\n')"
  aws lambda invoke --function-name "$REFUND_FN" --region "$REGION" \
    --cli-binary-format raw-in-base64-out \
    --client-context "$ctx" \
    --payload '{"order_id":"ORD-002","reason":"smoke test","amount":139.99}' \
    /tmp/refund-out.json >/dev/null 2>&1

  if jq -e '.body | fromjson | .status == "APPROVED"' /tmp/refund-out.json >/dev/null 2>&1; then
    ok "refund-processor approves and returns a refund ID"
  else
    fail "refund-processor smoke test failed: $(cat /tmp/refund-out.json 2>/dev/null)"
  fi
}

# ── API Gateway ──────────────────────────────────────────────────────────────
ensure_rest_api() {
  step "REST API (order-tracker target)"

  local api_id
  api_id="$(load api_id)"
  if [[ -z "$api_id" ]]; then
    api_id="$(aws apigateway get-rest-apis --region "$REGION" \
                --query "items[?name=='${API_NAME}'].id | [0]" --output text 2>/dev/null)"
    [[ "$api_id" == "None" ]] && api_id=""
  fi

  if [[ -n "$api_id" ]]; then
    skip "REST API $API_NAME already exists ($api_id)"
  else
    api_id="$(aws apigateway create-rest-api --name "$API_NAME" \
                --description "Order lookups for the AgentCore customer support agent" \
                --region "$REGION" --query id --output text)" \
      || die "could not create the REST API"
    ok "created REST API $api_id"
  fi
  save api_id "$api_id"

  local root_id
  root_id="$(aws apigateway get-resources --rest-api-id "$api_id" --region "$REGION" \
              --query "items[?path=='/'].id | [0]" --output text)"

  local account
  account="$(load account)"

  # /orders/{order_id}            → get_order
  # /customers/{customer_id}      → get_customer
  # /customers/{customer_id}/orders → get_customer_orders
  local orders_id customers_id
  orders_id="$(ensure_resource "$api_id" "$root_id" "orders")"
  local order_id_res
  order_id_res="$(ensure_resource "$api_id" "$orders_id" "{order_id}")"
  ensure_method "$api_id" "$order_id_res" "get_order" "$ORDER_FN" "$account"

  customers_id="$(ensure_resource "$api_id" "$root_id" "customers")"
  local customer_id_res
  customer_id_res="$(ensure_resource "$api_id" "$customers_id" "{customer_id}")"
  ensure_method "$api_id" "$customer_id_res" "get_customer" "$ORDER_FN" "$account"

  local customer_orders_res
  customer_orders_res="$(ensure_resource "$api_id" "$customer_id_res" "orders")"
  ensure_method "$api_id" "$customer_orders_res" "get_customer_orders" "$ORDER_FN" "$account"

  aws apigateway create-deployment --rest-api-id "$api_id" \
    --stage-name "$STAGE" --region "$REGION" >/dev/null \
    && ok "deployed to stage '$STAGE'" \
    || fail "could not deploy the stage"

  save api_url "https://${api_id}.execute-api.${REGION}.amazonaws.com/${STAGE}"
  ok "$(load api_url)"
}

ensure_resource() {
  local api_id="$1" parent="$2" part="$3"
  local existing
  existing="$(aws apigateway get-resources --rest-api-id "$api_id" --region "$REGION" \
              --query "items[?parentId=='${parent}' && pathPart=='${part}'].id | [0]" \
              --output text 2>/dev/null)"
  if [[ -n "$existing" && "$existing" != "None" ]]; then
    printf '%s' "$existing"
    return
  fi
  aws apigateway create-resource --rest-api-id "$api_id" --parent-id "$parent" \
    --path-part "$part" --region "$REGION" --query id --output text
}

ensure_method() {
  local api_id="$1" resource_id="$2" operation="$3" fn="$4" account="$5"

  if aws apigateway get-method --rest-api-id "$api_id" --resource-id "$resource_id" \
       --http-method GET --region "$REGION" >/dev/null 2>&1; then
    skip "GET $operation already configured"
    return
  fi

  # operationName is what AgentCore Gateway turns into the MCP tool name.
  aws apigateway put-method --rest-api-id "$api_id" --resource-id "$resource_id" \
    --http-method GET --authorization-type NONE --operation-name "$operation" \
    --region "$REGION" >/dev/null || { fail "put-method $operation"; return 1; }

  local fn_arn uri
  fn_arn="$(load "${fn}_arn")"
  uri="arn:aws:apigateway:${REGION}:lambda:path/2015-03-31/functions/${fn_arn}/invocations"

  aws apigateway put-integration --rest-api-id "$api_id" --resource-id "$resource_id" \
    --http-method GET --type AWS_PROXY --integration-http-method POST \
    --uri "$uri" --region "$REGION" >/dev/null \
    || { fail "put-integration $operation"; return 1; }

  aws lambda add-permission --function-name "$fn" \
    --statement-id "apigw-${operation}" --action lambda:InvokeFunction \
    --principal apigateway.amazonaws.com \
    --source-arn "arn:aws:execute-api:${REGION}:${account}:${api_id}/*/GET/*" \
    --region "$REGION" >/dev/null 2>&1

  ok "GET $operation → $fn"
}

test_rest_api() {
  step "REST API smoke test"
  local url
  url="$(load api_url)"
  [[ -z "$url" ]] && { warn "no API URL recorded"; return; }

  local body
  body="$(curl -s --max-time 20 "${url}/orders/ORD-001")"
  if jq -e '.tracking_number == "TRK987654321"' <<<"$body" >/dev/null 2>&1; then
    ok "GET ${url}/orders/ORD-001 → TRK987654321"
  else
    warn "REST API not answering yet (deployments take a moment): $body"
  fi
}

# ── S3 ───────────────────────────────────────────────────────────────────────
ensure_bucket() {
  step "S3 bucket for the Knowledge Base"

  local bucket
  bucket="$(load bucket)"
  if [[ -z "$bucket" ]]; then
    bucket="${PREFIX}-kb-$(load account)-${REGION}"
    save bucket "$bucket"
  fi

  if aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
    skip "s3://$bucket already exists"
  else
    if [[ "$REGION" == "us-east-1" ]]; then
      aws s3api create-bucket --bucket "$bucket" --region "$REGION" >/dev/null
    else
      aws s3api create-bucket --bucket "$bucket" --region "$REGION" \
        --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
    fi
    ok "created s3://$bucket"
  fi

  aws s3 cp "$CATALOG" "s3://${bucket}/product_catalog.txt" --region "$REGION" >/dev/null \
    && ok "uploaded product_catalog.txt" \
    || fail "could not upload the catalog"
}

# ── AgentCore Memory ─────────────────────────────────────────────────────────
ensure_memory() {
  step "AgentCore Memory"

  local memory_id
  memory_id="$(load memory_id)"
  if [[ -n "$memory_id" ]]; then
    skip "memory $memory_id already recorded"
    return
  fi

  local strategies
  strategies='[
    {"semanticMemoryStrategy":{"name":"customer_facts","namespaces":["cs_agent/{actorId}/facts"]}},
    {"userPreferenceMemoryStrategy":{"name":"customer_preferences","namespaces":["cs_agent/{actorId}/preferences"]}}
  ]'

  memory_id="$(aws bedrock-agentcore-control create-memory \
                 --name "$MEMORY_NAME" \
                 --event-expiry-duration 30 \
                 --memory-strategies "$strategies" \
                 --region "$REGION" \
                 --query 'memory.id' --output text 2>/dev/null)"

  if [[ -n "$memory_id" && "$memory_id" != "None" ]]; then
    ok "created memory $memory_id"
    save memory_id "$memory_id"
  else
    warn "Could not create the Memory resource from the CLI."
    warn "Create it in the console: Bedrock → AgentCore → Memory → $MEMORY_NAME"
    warn "  Semantic        customer_facts        cs_agent/{actorId}/facts"
    warn "  User preference customer_preferences  cs_agent/{actorId}/preferences"
  fi
}

# ── .env ─────────────────────────────────────────────────────────────────────
write_env() {
  step "Writing .env"

  cat > "$ENV_FILE" <<EOF
# Written by cloudshell/run-all.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# main.py reads every one of these; anything still blank is a manual step.

REGION=$REGION
AWS_REGION=$REGION
AWS_DEFAULT_REGION=$REGION

# Filled in automatically
ORDER_TRACKER_ARN=$(load "${ORDER_FN}_arn")
REFUND_PROCESSOR_ARN=$(load "${REFUND_FN}_arn")
REST_API_ID=$(load api_id)
REST_API_URL=$(load api_url)
REST_API_STAGE=$STAGE
KB_BUCKET=$(load bucket)
MEMORY_ID=$(load memory_id)

# Fill these in after the three console steps below
GATEWAY_URL=
KB_ID=
EOF

  ok "$ENV_FILE"
}

# ── What is left ─────────────────────────────────────────────────────────────
print_manual_steps() {
  local bucket api_id
  bucket="$(load bucket)"; api_id="$(load api_id)"

  cat <<EOF

$(printf '%s' "$BOLD")────────────────────────────────────────────────────────────────────────
 Three console steps remain
────────────────────────────────────────────────────────────────────────$(printf '%s' "$RESET")

$(printf '%s' "$CYAN")1. Knowledge Base$(printf '%s' "$RESET")
   Bedrock console → Knowledge Bases → Create
     Name             CustomerSupportKB
     Data source      s3://${bucket}
     Embeddings       Amazon Titan Embeddings v2
     Vector store     Amazon OpenSearch Serverless (let it create one)
   Then Sync the data source, and test it with:
     "What is the return policy for electronics?"   → expect "15 days"
   Copy the Knowledge Base ID into KB_ID in .env

$(printf '%s' "$CYAN")2. AgentCore Gateway$(printf '%s' "$RESET")
   Bedrock console → AgentCore → Gateways → Create
     Name             CustomerSupportGateway
     Authorizer       NONE
   Target 1 — API Gateway REST API stage
     Name             order-tracker
     REST API         ${API_NAME} (${api_id})
     Stage            ${STAGE}
     Operations       get_order, get_customer, get_customer_orders
   Target 2 — Lambda function
     Name             refund-processor
     Function         ${REFUND_FN}
     Tool schema      project/starter/lambda/lambda_schema
   Copy the Gateway URL (it ends /mcp) into GATEWAY_URL in .env

   Verify with the MCP Inspector:
     npx @modelcontextprotocol/inspector
   Expect six tools listed, three per target.

$(printf '%s' "$CYAN")3. Deploy the agent$(printf '%s' "$RESET")
   cd project/starter
   set -a && source ../../.env && set +a
   agentcore configure --entrypoint main.py --name customer_support_agent
   agentcore deploy

$(printf '%s' "$BOLD")────────────────────────────────────────────────────────────────────────
 Then run the six tests
────────────────────────────────────────────────────────────────────────$(printf '%s' "$RESET")

  agentcore invoke '{"prompt": "Can you track order ORD-001?", "customer_id": "CUST-123", "session_id": "t1"}'
  agentcore invoke '{"prompt": "I want to return my Kindle Paperwhite (ORD-002). Please initiate a refund.", "customer_id": "CUST-123", "session_id": "t2"}'
  agentcore invoke '{"prompt": "What are the benefits of the Platinum loyalty tier?", "customer_id": "CUST-123", "session_id": "t3"}'
  agentcore invoke '{"prompt": "Hi, I am Jane. I prefer concise responses.", "customer_id": "CUST-123", "session_id": "s-A"}'
  sleep 45   # memory extraction is asynchronous
  agentcore invoke '{"prompt": "Do you remember my name and communication preference?", "customer_id": "CUST-123", "session_id": "s-B"}'
  agentcore invoke '{"prompt": "I am a Gold member with 4250 points. Calculate my discount on a \$150 standard order.", "customer_id": "CUST-123", "session_id": "t5"}'
  agentcore invoke '{"prompt": "Go to https://www.udacity.com and tell me the page title.", "customer_id": "CUST-123", "session_id": "t6"}'

$(printf '%s' "$YELLOW")Tear down when you have your evidence:$(printf '%s' "$RESET")
  agentcore destroy
  bash cloudshell/run-all.sh --teardown
  Then delete, in the console: the Knowledge Base, its OpenSearch Serverless
  collection, and the Gateway. OpenSearch Serverless bills hourly whether or
  not anything queries it — that is the one to delete first.

EOF
}

# ── Status and teardown ──────────────────────────────────────────────────────
show_status() {
  step "Current state"
  for key in account role_arn "${ORDER_FN}_arn" "${REFUND_FN}_arn" api_id api_url bucket memory_id; do
    local value
    value="$(load "$key")"
    printf '  %-24s %s\n' "$key" "${value:-${DIM}(not set)${RESET}}"
  done
}

teardown() {
  step "Teardown"
  printf '  This deletes the Lambdas, the REST API, the S3 bucket and the\n'
  printf '  Memory resource created by this script. Continue? [y/N] '
  read -r reply
  [[ "$reply" == "y" || "$reply" == "Y" ]] || { warn "cancelled"; return; }

  local api_id bucket memory_id
  api_id="$(load api_id)"; bucket="$(load bucket)"; memory_id="$(load memory_id)"

  [[ -n "$api_id" ]] && aws apigateway delete-rest-api --rest-api-id "$api_id" \
    --region "$REGION" 2>/dev/null && ok "deleted REST API $api_id"

  for fn in "$ORDER_FN" "$REFUND_FN"; do
    aws lambda delete-function --function-name "$fn" --region "$REGION" 2>/dev/null \
      && ok "deleted $fn"
  done

  if [[ -n "$bucket" ]]; then
    aws s3 rm "s3://$bucket" --recursive --region "$REGION" >/dev/null 2>&1
    aws s3api delete-bucket --bucket "$bucket" --region "$REGION" 2>/dev/null \
      && ok "deleted s3://$bucket"
  fi

  [[ -n "$memory_id" ]] && aws bedrock-agentcore-control delete-memory \
    --memory-id "$memory_id" --region "$REGION" 2>/dev/null \
    && ok "deleted memory $memory_id"

  aws iam detach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null
  aws iam delete-role --role-name "$ROLE_NAME" 2>/dev/null && ok "deleted $ROLE_NAME"

  rm -rf "$STATE_DIR"
  warn "Still to delete by hand: the Knowledge Base, its OpenSearch Serverless"
  warn "collection, and the AgentCore Gateway."
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  case "${1:-}" in
    --status)   show_status; return 0 ;;
    --teardown) teardown; return 0 ;;
  esac

  printf '%s\n' "${BOLD}Customer Support Agent — AWS infrastructure${RESET}"
  printf '%s\n' "${DIM}region $REGION · prefix $PREFIX · state $STATE_DIR${RESET}"

  preflight
  ensure_role
  deploy_lambdas
  smoke_test_lambdas
  ensure_rest_api
  test_rest_api
  ensure_bucket
  ensure_memory
  write_env
  show_status
  print_manual_steps
}

main "$@"
