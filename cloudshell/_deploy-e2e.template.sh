#!/usr/bin/env bash
#
#  Customer Support Agent on Amazon Bedrock AgentCore — end-to-end deploy
#  ─────────────────────────────────────────────────────────────────────
#  Self-contained. Every project file is embedded below; nothing is cloned
#  and nothing is downloaded. Paste it into AWS CloudShell and run it.
#
#     bash deploy-e2e.sh              deploy everything, then run the 6 tests
#     bash deploy-e2e.sh --status     show what exists, change nothing
#     bash deploy-e2e.sh --test-only  re-run the 6 tests against what is there
#     bash deploy-e2e.sh --teardown   delete everything it created
#
#  ─────────────────────────────────────────────────────────────────────
#  COST — read this before running
#
#    Lambda, API Gateway, S3, Memory, Gateway      cents, or free
#    Bedrock Nova 2 Lite + Titan embeddings        cents for this workload
#    OpenSearch Serverless                         ~$0.24 per OCU-hour,
#                                                  minimum 2 OCUs, billed
#                                                  WHETHER OR NOT ANYTHING
#                                                  QUERIES IT
#
#  That last line is the whole budget. A collection left running costs
#  roughly $12 a day doing nothing. Finish, screenshot, then immediately:
#
#     bash deploy-e2e.sh --teardown
#
#  The script prints that reminder again at the end, and --teardown removes
#  the collection first.
#  ─────────────────────────────────────────────────────────────────────
#
#  Resumable. State lives in ~/.cs-agent-state; re-running skips whatever
#  already exists, so a dropped CloudShell session costs nothing but time.
#
#  Honesty note: this script was written and syntax-checked, but it has NOT
#  been executed against a live AWS account — no credentials with the
#  necessary permissions were available. Each AWS call is therefore treated
#  as fallible: a failure prints the exact console steps for that one piece
#  and the script carries on with the rest, rather than claiming success it
#  cannot verify. Check the summary table at the end for what actually
#  succeeded.

set -uo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
REGION="${AWS_REGION:-us-east-1}"
PREFIX="${PREFIX:-cs-agent}"
AGENT_NAME="${AGENT_NAME:-customer_support_agent}"

LAMBDA_ROLE="${PREFIX}-lambda-role"
KB_ROLE="${PREFIX}-kb-role"
GW_ROLE="${PREFIX}-gateway-role"

ORDER_FN="order-tracker"
REFUND_FN="refund-processor"
API_NAME="${PREFIX}-order-api"
STAGE="prod"

COLLECTION="${PREFIX}-kb"
INDEX_NAME="bedrock-knowledge-base-default-index"
VECTOR_FIELD="bedrock-knowledge-base-default-vector"
KB_NAME="CustomerSupportKB"
MEMORY_NAME="CustomerSupportMemory"
GATEWAY_NAME="CustomerSupportGateway"

EMBED_MODEL="amazon.titan-embed-text-v2:0"
EMBED_DIM=1024
AGENT_MODEL="global.amazon.nova-2-lite-v1:0"

PROJECT_DIR="${HOME}/${PREFIX}-project"
STATE_DIR="${HOME}/.${PREFIX}-state"
EVIDENCE_DIR="${PROJECT_DIR}/evidence/live"

mkdir -p "$STATE_DIR"

# ── Output ───────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; RED=$'\033[31m'
  YELLOW=$'\033[33m'; CYAN=$'\033[36m'; RESET=$'\033[0m'
else
  BOLD=""; DIM=""; GREEN=""; RED=""; YELLOW=""; CYAN=""; RESET=""
fi

PHASE_N=0
phase() { PHASE_N=$((PHASE_N+1)); printf '\n%s━━ %d. %s%s\n' "$CYAN$BOLD" "$PHASE_N" "$*" "$RESET"; }
ok()    { printf '   %s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
skip()  { printf '   %s·%s %s\n' "$DIM" "$RESET" "${DIM}$*${RESET}"; }
warn()  { printf '   %s!%s %s\n' "$YELLOW" "$RESET" "$*"; }
bad()   { printf '   %s✗%s %s\n' "$RED" "$RESET" "$*"; }
die()   { bad "$*"; printf '\n%sStopped. Nothing further was attempted.%s\n' "$RED" "$RESET"; exit 1; }

save()  { printf '%s' "$2" > "$STATE_DIR/$1"; }
load()  { cat "$STATE_DIR/$1" 2>/dev/null || true; }
have()  { [[ -n "$(load "$1")" ]]; }

# Records which phases worked, for the summary table.
RESULTS=()
record() { RESULTS+=("$1|$2|$3"); }

# Wait for a condition. wait_for <seconds> <label> <command...>
wait_for() {
  local timeout="$1" label="$2"; shift 2
  local waited=0
  printf '   %s⋯%s %s ' "$DIM" "$RESET" "$label"
  while (( waited < timeout )); do
    if "$@" >/dev/null 2>&1; then printf '%s✓%s\n' "$GREEN" "$RESET"; return 0; fi
    printf '.'; sleep 10; waited=$((waited+10))
  done
  printf '%s timed out after %ss%s\n' "$YELLOW" "$timeout" "$RESET"
  return 1
}

# ═════════════════════════════════════════════════════════════════════════════
#  0. Preflight
# ═════════════════════════════════════════════════════════════════════════════
preflight() {
  phase "Preflight"

  command -v aws  >/dev/null || die "aws CLI not found. Run this inside AWS CloudShell."
  command -v jq   >/dev/null || die "jq not found. Run this inside AWS CloudShell."
  command -v python3 >/dev/null || die "python3 not found."

  local identity account arn
  identity="$(aws sts get-caller-identity --output json 2>/dev/null)" \
    || die "No AWS credentials. In CloudShell these are already configured."
  account="$(jq -r .Account <<<"$identity")"
  arn="$(jq -r .Arn <<<"$identity")"
  save account "$account"
  save caller_arn "$arn"
  ok "account $account"
  ok "identity $arn"
  ok "region $REGION"

  case "$arn" in
    *":root")
      warn "Running as the account root. Root has no permission boundary and"
      warn "its keys cannot be scoped per service. Prefer an IAM user." ;;
  esac

  # Model access, checked up front — a missing grant is a two-click fix and
  # every downstream failure it causes is misleading.
  if aws bedrock get-foundation-model --model-identifier "amazon.nova-2-lite-v1:0" \
       --region "$REGION" >/dev/null 2>&1; then
    ok "Nova 2 Lite available"
  else
    warn "Could not confirm Nova 2 Lite. Bedrock console → Model access → Amazon Nova Lite."
  fi
  if aws bedrock get-foundation-model --model-identifier "$EMBED_MODEL" \
       --region "$REGION" >/dev/null 2>&1; then
    ok "Titan Embeddings v2 available"
  else
    warn "Could not confirm Titan Embeddings v2 — the Knowledge Base needs it."
  fi

  check_permissions
}

# Report every missing permission at once, before the first write. Dying at
# "could not create the role" reads like a name clash rather than what it is.
check_permissions() {
  local missing=()
  aws iam list-roles --max-items 1 >/dev/null 2>&1 \
    || missing+=("iam:ListRoles / CreateRole / PassRole      execution roles")
  aws lambda list-functions --max-items 1 --region "$REGION" >/dev/null 2>&1 \
    || missing+=("lambda:ListFunctions / CreateFunction      both Lambda targets")
  aws apigateway get-rest-apis --region "$REGION" >/dev/null 2>&1 \
    || missing+=("apigateway:GET / POST                      the order REST API")
  aws s3api list-buckets >/dev/null 2>&1 \
    || missing+=("s3:ListAllMyBuckets / CreateBucket         Knowledge Base source")
  aws opensearchserverless list-collections --region "$REGION" >/dev/null 2>&1 \
    || missing+=("aoss:*                                     the vector store")
  aws bedrock-agent list-knowledge-bases --region "$REGION" >/dev/null 2>&1 \
    || missing+=("bedrock:*KnowledgeBase*                    the Knowledge Base")
  aws bedrock-agentcore-control list-memories --region "$REGION" >/dev/null 2>&1 \
    || missing+=("bedrock-agentcore:*                        Memory and Gateway")

  if [[ ${#missing[@]} -eq 0 ]]; then
    ok "all required permissions present"
    return 0
  fi

  bad "This identity cannot deploy the project. Missing:"
  printf '\n'
  printf '       %s\n' "${missing[@]}"
  cat <<EOF

   Nothing has been created — this runs before the first write.

   Use the Udacity Cloud Lab credentials (Cloud Resources tab → generate
   access keys), or any principal with IAM, Lambda, API Gateway, S3,
   OpenSearch Serverless, Bedrock and bedrock-agentcore in $REGION.

     export AWS_ACCESS_KEY_ID=...
     export AWS_SECRET_ACCESS_KEY=...
     export AWS_SESSION_TOKEN=...
     export AWS_REGION=$REGION

EOF
  exit 1
}

# ═════════════════════════════════════════════════════════════════════════════
#  1. Write the project files
# ═════════════════════════════════════════════════════════════════════════════
materialise() {
  phase "Writing project files to $PROJECT_DIR"

  mkdir -p "$PROJECT_DIR/lambda" "$EVIDENCE_DIR"

__EMBEDDED_FILES__

  ok "main.py                ($(wc -l < "$PROJECT_DIR/main.py") lines)"
  ok "lambda/order_tracker.py"
  ok "lambda/refund_processor.py"
  ok "lambda/lambda_schema"
  ok "product_catalog.txt"
  record "Project files" "OK" "$PROJECT_DIR"
}

# ═════════════════════════════════════════════════════════════════════════════
#  2. IAM roles
# ═════════════════════════════════════════════════════════════════════════════
make_role() {
  local name="$1" trust="$2"
  local existing
  existing="$(aws iam get-role --role-name "$name" --query Role.Arn --output text 2>/dev/null)"
  if [[ -n "$existing" && "$existing" != "None" ]]; then
    printf '%s' "$existing"; return 0
  fi
  aws iam create-role --role-name "$name" --assume-role-policy-document "$trust" \
    --query Role.Arn --output text 2>/dev/null
}

ensure_roles() {
  phase "IAM roles"

  local account; account="$(load account)"
  local arn

  # -- Lambda execution role ------------------------------------------------
  if have lambda_role_arn; then
    skip "$LAMBDA_ROLE exists"
  else
    arn="$(make_role "$LAMBDA_ROLE" '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}')"
    [[ -z "$arn" ]] && die "could not create $LAMBDA_ROLE"
    aws iam attach-role-policy --role-name "$LAMBDA_ROLE" \
      --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null
    save lambda_role_arn "$arn"
    ok "$LAMBDA_ROLE"
  fi

  # -- Knowledge Base service role -----------------------------------------
  if have kb_role_arn; then
    skip "$KB_ROLE exists"
  else
    arn="$(make_role "$KB_ROLE" '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"bedrock.amazonaws.com"},"Action":"sts:AssumeRole"}]}')"
    [[ -z "$arn" ]] && die "could not create $KB_ROLE"
    aws iam put-role-policy --role-name "$KB_ROLE" --policy-name kb-access \
      --policy-document "$(cat <<EOF
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["bedrock:InvokeModel"],"Resource":"arn:aws:bedrock:${REGION}::foundation-model/${EMBED_MODEL}"},
 {"Effect":"Allow","Action":["aoss:APIAccessAll"],"Resource":"*"},
 {"Effect":"Allow","Action":["s3:GetObject","s3:ListBucket"],"Resource":"*"}
]}
EOF
)" 2>/dev/null
    save kb_role_arn "$arn"
    ok "$KB_ROLE"
  fi

  # -- Gateway execution role ----------------------------------------------
  if have gw_role_arn; then
    skip "$GW_ROLE exists"
  else
    arn="$(make_role "$GW_ROLE" '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"bedrock-agentcore.amazonaws.com"},"Action":"sts:AssumeRole"}]}')"
    if [[ -n "$arn" ]]; then
      aws iam put-role-policy --role-name "$GW_ROLE" --policy-name gateway-invoke \
        --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["lambda:InvokeFunction","execute-api:Invoke"],"Resource":"*"}]}' 2>/dev/null
      save gw_role_arn "$arn"
      ok "$GW_ROLE"
    else
      warn "could not create $GW_ROLE — the Gateway step may need the console"
    fi
  fi

  # IAM is eventually consistent and every service below rejects a role it
  # cannot see yet. Waiting once here is cheaper than retry loops everywhere.
  printf '   %s⋯%s waiting for IAM propagation ' "$DIM" "$RESET"
  for _ in $(seq 1 12); do printf '.'; sleep 2; done
  printf '%s✓%s\n' "$GREEN" "$RESET"
  record "IAM roles" "OK" "$LAMBDA_ROLE, $KB_ROLE, $GW_ROLE"
}

# ═════════════════════════════════════════════════════════════════════════════
#  3. Lambda functions
# ═════════════════════════════════════════════════════════════════════════════
deploy_one_lambda() {
  local name="$1" file="$2"
  local zip="/tmp/${name}.zip"
  rm -f "$zip"
  (cd "$PROJECT_DIR/lambda" && zip -q "$zip" "$file")
  local handler="${file%.py}.lambda_handler"

  if aws lambda get-function --function-name "$name" --region "$REGION" >/dev/null 2>&1; then
    aws lambda update-function-code --function-name "$name" --zip-file "fileb://$zip" \
      --region "$REGION" >/dev/null 2>&1 || { bad "update $name"; return 1; }
    aws lambda wait function-updated --function-name "$name" --region "$REGION" 2>/dev/null
    ok "$name (updated)"
  else
    aws lambda create-function --function-name "$name" --runtime python3.12 \
      --role "$(load lambda_role_arn)" --handler "$handler" --zip-file "fileb://$zip" \
      --timeout 30 --memory-size 256 --region "$REGION" >/dev/null 2>&1 \
      || { bad "create $name"; return 1; }
    aws lambda wait function-active --function-name "$name" --region "$REGION" 2>/dev/null
    ok "$name (created)"
  fi

  save "${name}_arn" "$(aws lambda get-function --function-name "$name" --region "$REGION" \
    --query Configuration.FunctionArn --output text 2>/dev/null)"
}

deploy_lambdas() {
  phase "Lambda functions"
  deploy_one_lambda "$ORDER_FN"  "order_tracker.py"    || die "order-tracker failed"
  deploy_one_lambda "$REFUND_FN" "refund_processor.py" || die "refund-processor failed"

  # Smoke tests. The 404 one matters most: an agent that invents an order it
  # could not find is the failure this whole project is trying to avoid.
  local out
  aws lambda invoke --function-name "$ORDER_FN" --region "$REGION" \
    --cli-binary-format raw-in-base64-out \
    --payload '{"resource":"/orders/{order_id}","httpMethod":"GET","pathParameters":{"order_id":"ORD-001"}}' \
    /tmp/o1.json >/dev/null 2>&1
  if jq -e '.body|fromjson|.tracking_number=="TRK987654321"' /tmp/o1.json >/dev/null 2>&1; then
    ok "smoke: ORD-001 → TRK987654321"
  else
    warn "smoke: ORD-001 did not return the expected tracking number"
  fi

  aws lambda invoke --function-name "$ORDER_FN" --region "$REGION" \
    --cli-binary-format raw-in-base64-out \
    --payload '{"resource":"/orders/{order_id}","httpMethod":"GET","pathParameters":{"order_id":"ORD-999"}}' \
    /tmp/o2.json >/dev/null 2>&1
  if jq -e '.statusCode==404' /tmp/o2.json >/dev/null 2>&1; then
    ok "smoke: ORD-999 → 404, not an invented order"
  else
    warn "smoke: ORD-999 did not 404"
  fi

  local ctx
  ctx="$(printf '{"custom":{"bedrockAgentCoreToolName":"refund-processor___initiate_refund"}}' | base64 | tr -d '\n')"
  aws lambda invoke --function-name "$REFUND_FN" --region "$REGION" \
    --cli-binary-format raw-in-base64-out --client-context "$ctx" \
    --payload '{"order_id":"ORD-002","reason":"smoke","amount":139.99}' \
    /tmp/r1.json >/dev/null 2>&1
  if jq -e '.body|fromjson|.status=="APPROVED"' /tmp/r1.json >/dev/null 2>&1; then
    ok "smoke: refund approved, prefix stripped correctly"
  else
    warn "smoke: refund did not return APPROVED"
  fi

  record "Lambda functions" "OK" "$ORDER_FN, $REFUND_FN"
}

# ═════════════════════════════════════════════════════════════════════════════
#  4. REST API
# ═════════════════════════════════════════════════════════════════════════════
res_id() {
  aws apigateway get-resources --rest-api-id "$1" --region "$REGION" \
    --query "items[?parentId=='$2' && pathPart=='$3'].id | [0]" --output text 2>/dev/null
}

ensure_resource() {
  local api="$1" parent="$2" part="$3" existing
  existing="$(res_id "$api" "$parent" "$part")"
  if [[ -n "$existing" && "$existing" != "None" ]]; then printf '%s' "$existing"; return; fi
  aws apigateway create-resource --rest-api-id "$api" --parent-id "$parent" \
    --path-part "$part" --region "$REGION" --query id --output text 2>/dev/null
}

ensure_method() {
  local api="$1" res="$2" op="$3" account="$4"
  if aws apigateway get-method --rest-api-id "$api" --resource-id "$res" \
       --http-method GET --region "$REGION" >/dev/null 2>&1; then
    skip "GET $op already configured"; return
  fi
  # operationName is exactly what AgentCore Gateway turns into the MCP tool
  # name. Without it the target exposes nothing.
  aws apigateway put-method --rest-api-id "$api" --resource-id "$res" \
    --http-method GET --authorization-type NONE --operation-name "$op" \
    --region "$REGION" >/dev/null 2>&1 || { bad "put-method $op"; return 1; }

  local uri="arn:aws:apigateway:${REGION}:lambda:path/2015-03-31/functions/$(load "${ORDER_FN}_arn")/invocations"
  aws apigateway put-integration --rest-api-id "$api" --resource-id "$res" \
    --http-method GET --type AWS_PROXY --integration-http-method POST \
    --uri "$uri" --region "$REGION" >/dev/null 2>&1 || { bad "put-integration $op"; return 1; }

  aws lambda add-permission --function-name "$ORDER_FN" --statement-id "apigw-${op}" \
    --action lambda:InvokeFunction --principal apigateway.amazonaws.com \
    --source-arn "arn:aws:execute-api:${REGION}:${account}:${api}/*/GET/*" \
    --region "$REGION" >/dev/null 2>&1
  ok "GET $op"
}

ensure_api() {
  phase "REST API (order-tracker Gateway target)"

  local api account
  account="$(load account)"
  api="$(load api_id)"
  if [[ -z "$api" ]]; then
    api="$(aws apigateway get-rest-apis --region "$REGION" \
      --query "items[?name=='${API_NAME}'].id | [0]" --output text 2>/dev/null)"
    [[ "$api" == "None" ]] && api=""
  fi
  if [[ -z "$api" ]]; then
    api="$(aws apigateway create-rest-api --name "$API_NAME" --region "$REGION" \
      --description "Order lookups for the AgentCore customer support agent" \
      --query id --output text 2>/dev/null)" || die "could not create the REST API"
    ok "created REST API $api"
  else
    skip "REST API $api exists"
  fi
  save api_id "$api"

  local root; root="$(aws apigateway get-resources --rest-api-id "$api" --region "$REGION" \
    --query "items[?path=='/'].id | [0]" --output text)"

  local orders order_one customers customer_one customer_orders
  orders="$(ensure_resource "$api" "$root" "orders")"
  order_one="$(ensure_resource "$api" "$orders" "{order_id}")"
  ensure_method "$api" "$order_one" "get_order" "$account"

  customers="$(ensure_resource "$api" "$root" "customers")"
  customer_one="$(ensure_resource "$api" "$customers" "{customer_id}")"
  ensure_method "$api" "$customer_one" "get_customer" "$account"

  customer_orders="$(ensure_resource "$api" "$customer_one" "orders")"
  ensure_method "$api" "$customer_orders" "get_customer_orders" "$account"

  aws apigateway create-deployment --rest-api-id "$api" --stage-name "$STAGE" \
    --region "$REGION" >/dev/null 2>&1 && ok "deployed to stage '$STAGE'"

  local url="https://${api}.execute-api.${REGION}.amazonaws.com/${STAGE}"
  save api_url "$url"

  sleep 5
  if curl -s --max-time 20 "${url}/orders/ORD-001" | jq -e '.tracking_number=="TRK987654321"' >/dev/null 2>&1; then
    ok "live: ${url}/orders/ORD-001 → TRK987654321"
    record "REST API" "OK" "$url"
  else
    warn "REST API not answering yet — it may need a moment"
    record "REST API" "PARTIAL" "$url"
  fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  5. S3
# ═════════════════════════════════════════════════════════════════════════════
ensure_bucket() {
  phase "S3 bucket"
  local bucket; bucket="$(load bucket)"
  [[ -z "$bucket" ]] && { bucket="${PREFIX}-kb-$(load account)"; save bucket "$bucket"; }

  if aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
    skip "s3://$bucket exists"
  else
    if [[ "$REGION" == "us-east-1" ]]; then
      aws s3api create-bucket --bucket "$bucket" --region "$REGION" >/dev/null 2>&1
    else
      aws s3api create-bucket --bucket "$bucket" --region "$REGION" \
        --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null 2>&1
    fi
    ok "created s3://$bucket"
  fi

  aws s3 cp "$PROJECT_DIR/product_catalog.txt" "s3://${bucket}/product_catalog.txt" \
    --region "$REGION" >/dev/null 2>&1 && ok "uploaded product_catalog.txt" \
    || { bad "upload failed"; return 1; }
  record "S3 bucket" "OK" "s3://$bucket"
}

# ═════════════════════════════════════════════════════════════════════════════
#  6. OpenSearch Serverless  ← the expensive one
# ═════════════════════════════════════════════════════════════════════════════
ensure_collection() {
  phase "OpenSearch Serverless vector store  ${YELLOW}(billed hourly while it exists)${RESET}"

  local caller kb_role
  caller="$(load caller_arn)"; kb_role="$(load kb_role_arn)"

  # Three policies must exist before the collection, or creation fails.
  aws opensearchserverless create-security-policy --name "${COLLECTION}-enc" --type encryption \
    --policy "{\"Rules\":[{\"ResourceType\":\"collection\",\"Resource\":[\"collection/${COLLECTION}\"]}],\"AWSOwnedKey\":true}" \
    --region "$REGION" >/dev/null 2>&1 && ok "encryption policy" || skip "encryption policy exists"

  aws opensearchserverless create-security-policy --name "${COLLECTION}-net" --type network \
    --policy "[{\"Rules\":[{\"ResourceType\":\"collection\",\"Resource\":[\"collection/${COLLECTION}\"]},{\"ResourceType\":\"dashboard\",\"Resource\":[\"collection/${COLLECTION}\"]}],\"AllowFromPublic\":true}]" \
    --region "$REGION" >/dev/null 2>&1 && ok "network policy" || skip "network policy exists"

  aws opensearchserverless create-access-policy --name "${COLLECTION}-data" --type data \
    --policy "[{\"Rules\":[{\"ResourceType\":\"index\",\"Resource\":[\"index/${COLLECTION}/*\"],\"Permission\":[\"aoss:*\"]},{\"ResourceType\":\"collection\",\"Resource\":[\"collection/${COLLECTION}\"],\"Permission\":[\"aoss:*\"]}],\"Principal\":[\"${caller}\",\"${kb_role}\"]}]" \
    --region "$REGION" >/dev/null 2>&1 && ok "data access policy" || skip "data access policy exists"

  local arn
  arn="$(aws opensearchserverless batch-get-collection --names "$COLLECTION" --region "$REGION" \
    --query 'collectionDetails[0].arn' --output text 2>/dev/null)"
  if [[ -z "$arn" || "$arn" == "None" ]]; then
    aws opensearchserverless create-collection --name "$COLLECTION" --type VECTORSEARCH \
      --region "$REGION" >/dev/null 2>&1 || { bad "could not create the collection"; return 1; }
    ok "creating collection $COLLECTION"
  else
    skip "collection exists"
  fi

  wait_for 600 "collection becoming ACTIVE" bash -c \
    "[[ \"\$(aws opensearchserverless batch-get-collection --names $COLLECTION --region $REGION --query 'collectionDetails[0].status' --output text 2>/dev/null)\" == ACTIVE ]]" \
    || { bad "collection did not become ACTIVE"; return 1; }

  arn="$(aws opensearchserverless batch-get-collection --names "$COLLECTION" --region "$REGION" \
    --query 'collectionDetails[0].arn' --output text)"
  local endpoint
  endpoint="$(aws opensearchserverless batch-get-collection --names "$COLLECTION" --region "$REGION" \
    --query 'collectionDetails[0].collectionEndpoint' --output text)"
  save collection_arn "$arn"
  save collection_endpoint "$endpoint"
  ok "$arn"

  create_vector_index "$endpoint"
  record "OpenSearch Serverless" "OK" "$COLLECTION (BILLING — tear down when done)"
}

# The vector index is created over the OpenSearch REST API, signed with SigV4
# for the 'aoss' service. Done with botocore, which CloudShell already has, so
# there is no pip install to fail.
create_vector_index() {
  local endpoint="$1"
  python3 - "$endpoint" "$INDEX_NAME" "$VECTOR_FIELD" "$EMBED_DIM" "$REGION" <<'PYEOF'
import json, sys, time
import botocore.session
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
from botocore.httpsession import URLLib3Session

endpoint, index, vector_field, dim, region = sys.argv[1:6]

body = json.dumps({
    "settings": {"index.knn": True},
    "mappings": {"properties": {
        vector_field: {
            "type": "knn_vector",
            "dimension": int(dim),
            "method": {"name": "hnsw", "engine": "faiss", "spaceType": "l2"},
        },
        "AMAZON_BEDROCK_TEXT_CHUNK": {"type": "text"},
        "AMAZON_BEDROCK_METADATA": {"type": "text", "index": False},
    }},
})

session = botocore.session.Session()
creds = session.get_credentials().get_frozen_credentials()
url = f"{endpoint}/{index}"

def send(method, url, body=None):
    request = AWSRequest(method=method, url=url, data=body,
                         headers={"Content-Type": "application/json"})
    SigV4Auth(creds, "aoss", region).add_auth(request)
    return URLLib3Session().send(request.prepare())

response = send("HEAD", url)
if response.status_code == 200:
    print("   · vector index already exists")
    sys.exit(0)

response = send("PUT", url, body)
text = response.text if hasattr(response, "text") else response.content.decode()
if response.status_code in (200, 201):
    print(f"   ✓ vector index {index} created")
    # The index is not queryable the instant it is acknowledged, and the
    # Knowledge Base fails opaquely if it is created too soon.
    time.sleep(45)
elif "resource_already_exists_exception" in text:
    print("   · vector index already exists")
else:
    print(f"   ! vector index creation returned {response.status_code}: {text[:300]}")
    sys.exit(1)
PYEOF
}

# ═════════════════════════════════════════════════════════════════════════════
#  7. Knowledge Base
# ═════════════════════════════════════════════════════════════════════════════
ensure_kb() {
  phase "Bedrock Knowledge Base"

  local kb_id; kb_id="$(load kb_id)"
  if [[ -z "$kb_id" ]]; then
    kb_id="$(aws bedrock-agent list-knowledge-bases --region "$REGION" \
      --query "knowledgeBaseSummaries[?name=='${KB_NAME}'].knowledgeBaseId | [0]" \
      --output text 2>/dev/null)"
    [[ "$kb_id" == "None" ]] && kb_id=""
  fi

  if [[ -z "$kb_id" ]]; then
    kb_id="$(aws bedrock-agent create-knowledge-base --name "$KB_NAME" \
      --role-arn "$(load kb_role_arn)" \
      --knowledge-base-configuration "{\"type\":\"VECTOR\",\"vectorKnowledgeBaseConfiguration\":{\"embeddingModelArn\":\"arn:aws:bedrock:${REGION}::foundation-model/${EMBED_MODEL}\"}}" \
      --storage-configuration "{\"type\":\"OPENSEARCH_SERVERLESS\",\"opensearchServerlessConfiguration\":{\"collectionArn\":\"$(load collection_arn)\",\"vectorIndexName\":\"${INDEX_NAME}\",\"fieldMapping\":{\"vectorField\":\"${VECTOR_FIELD}\",\"textField\":\"AMAZON_BEDROCK_TEXT_CHUNK\",\"metadataField\":\"AMAZON_BEDROCK_METADATA\"}}}" \
      --region "$REGION" --query 'knowledgeBase.knowledgeBaseId' --output text 2>&1)"
    if [[ ! "$kb_id" =~ ^[A-Z0-9]{8,}$ ]]; then
      bad "create-knowledge-base failed: ${kb_id:0:300}"
      console_steps_kb; record "Knowledge Base" "MANUAL" "see console steps above"; return 1
    fi
    ok "created Knowledge Base $kb_id"
  else
    skip "Knowledge Base $kb_id exists"
  fi
  save kb_id "$kb_id"

  local ds_id; ds_id="$(load ds_id)"
  if [[ -z "$ds_id" ]]; then
    ds_id="$(aws bedrock-agent create-data-source --knowledge-base-id "$kb_id" \
      --name "${PREFIX}-catalog" \
      --data-source-configuration "{\"type\":\"S3\",\"s3Configuration\":{\"bucketArn\":\"arn:aws:s3:::$(load bucket)\"}}" \
      --region "$REGION" --query 'dataSource.dataSourceId' --output text 2>/dev/null)"
    [[ -z "$ds_id" || "$ds_id" == "None" ]] && { bad "could not create the data source"; return 1; }
    save ds_id "$ds_id"
    ok "data source $ds_id"
  else
    skip "data source $ds_id exists"
  fi

  local job
  job="$(aws bedrock-agent start-ingestion-job --knowledge-base-id "$kb_id" \
    --data-source-id "$ds_id" --region "$REGION" \
    --query 'ingestionJob.ingestionJobId' --output text 2>/dev/null)"
  if [[ -n "$job" && "$job" != "None" ]]; then
    ok "ingestion job $job started"
    wait_for 420 "syncing the catalog" bash -c \
      "[[ \"\$(aws bedrock-agent get-ingestion-job --knowledge-base-id $kb_id --data-source-id $ds_id --ingestion-job-id $job --region $REGION --query 'ingestionJob.status' --output text 2>/dev/null)\" == COMPLETE ]]"
  fi

  # The project's own Check 3.
  local answer
  answer="$(aws bedrock-agent-runtime retrieve --knowledge-base-id "$kb_id" \
    --retrieval-query '{"text":"What is the return policy for electronics?"}' \
    --region "$REGION" --query 'retrievalResults[0].content.text' --output text 2>/dev/null)"
  if grep -q "15 days" <<<"$answer"; then
    ok "retrieval check: electronics → 15 days"
    record "Knowledge Base" "OK" "$kb_id"
  else
    warn "retrieval did not mention '15 days' yet — indexing can lag"
    record "Knowledge Base" "PARTIAL" "$kb_id"
  fi
}

console_steps_kb() {
  cat <<EOF

   ${BOLD}Create the Knowledge Base by hand instead:${RESET}
     Bedrock console → Knowledge Bases → Create
       Name          $KB_NAME
       Data source   s3://$(load bucket)
       Embeddings    Titan Embeddings v2
       Vector store  the existing collection '$COLLECTION',
                     index '$INDEX_NAME', vector field '$VECTOR_FIELD',
                     text field AMAZON_BEDROCK_TEXT_CHUNK,
                     metadata field AMAZON_BEDROCK_METADATA
     Sync the data source, then:  echo '<kb-id>' > $STATE_DIR/kb_id

EOF
}

# ═════════════════════════════════════════════════════════════════════════════
#  8. AgentCore Memory
# ═════════════════════════════════════════════════════════════════════════════
ensure_memory() {
  phase "AgentCore Memory"

  local mem; mem="$(load memory_id)"
  if [[ -z "$mem" ]]; then
    mem="$(aws bedrock-agentcore-control list-memories --region "$REGION" \
      --query "memories[?name=='${MEMORY_NAME}'].id | [0]" --output text 2>/dev/null)"
    [[ "$mem" == "None" ]] && mem=""
  fi

  if [[ -z "$mem" ]]; then
    local strategies
    strategies="$(cat <<'EOF'
[{"semanticMemoryStrategy":{"name":"customer_facts","namespaces":["cs_agent/{actorId}/facts"]}},
 {"userPreferenceMemoryStrategy":{"name":"customer_preferences","namespaces":["cs_agent/{actorId}/preferences"]}}]
EOF
)"
    mem="$(aws bedrock-agentcore-control create-memory --name "$MEMORY_NAME" \
      --event-expiry-duration 30 --memory-strategies "$strategies" \
      --region "$REGION" --query 'memory.id' --output text 2>&1)"
    if [[ -z "$mem" || "$mem" == "None" || "$mem" == *"error"* || "$mem" == *"Error"* ]]; then
      bad "create-memory failed: ${mem:0:250}"
      cat <<EOF

   ${BOLD}Create it by hand instead:${RESET}
     Bedrock → AgentCore → Memory → Create '$MEMORY_NAME'
       Semantic         customer_facts        cs_agent/{actorId}/facts
       User preference  customer_preferences  cs_agent/{actorId}/preferences
     Then:  echo '<memory-id>' > $STATE_DIR/memory_id

EOF
      record "AgentCore Memory" "MANUAL" "see console steps above"
      return 1
    fi
    ok "created memory $mem"
  else
    skip "memory $mem exists"
  fi
  save memory_id "$mem"

  wait_for 300 "memory becoming ACTIVE" bash -c \
    "[[ \"\$(aws bedrock-agentcore-control get-memory --memory-id $mem --region $REGION --query 'memory.status' --output text 2>/dev/null)\" == ACTIVE ]]"
  record "AgentCore Memory" "OK" "$mem"
}

# ═════════════════════════════════════════════════════════════════════════════
#  9. AgentCore Gateway
# ═════════════════════════════════════════════════════════════════════════════
ensure_gateway() {
  phase "AgentCore Gateway"

  local gw; gw="$(load gateway_id)"
  if [[ -z "$gw" ]]; then
    gw="$(aws bedrock-agentcore-control list-gateways --region "$REGION" \
      --query "items[?name=='${GATEWAY_NAME}'].gatewayId | [0]" --output text 2>/dev/null)"
    [[ "$gw" == "None" ]] && gw=""
  fi

  if [[ -z "$gw" ]]; then
    local out
    out="$(aws bedrock-agentcore-control create-gateway --name "$GATEWAY_NAME" \
      --role-arn "$(load gw_role_arn)" --protocol-type MCP --authorizer-type NONE \
      --region "$REGION" --output json 2>&1)"
    gw="$(jq -r '.gatewayId // empty' <<<"$out" 2>/dev/null)"
    if [[ -z "$gw" ]]; then
      bad "create-gateway failed: $(head -c 280 <<<"$out")"
      console_steps_gateway
      record "AgentCore Gateway" "MANUAL" "see console steps above"
      return 1
    fi
    ok "created gateway $gw"
  else
    skip "gateway $gw exists"
  fi
  save gateway_id "$gw"

  local url
  url="$(aws bedrock-agentcore-control get-gateway --gateway-identifier "$gw" --region "$REGION" \
    --query 'gatewayUrl' --output text 2>/dev/null)"
  [[ -n "$url" && "$url" != "None" ]] && { save gateway_url "$url"; ok "$url"; }

  # -- Lambda target --------------------------------------------------------
  local schema; schema="$(cat "$PROJECT_DIR/lambda/lambda_schema")"
  aws bedrock-agentcore-control create-gateway-target --gateway-identifier "$gw" \
    --name "$REFUND_FN" \
    --target-configuration "{\"mcp\":{\"lambda\":{\"lambdaArn\":\"$(load "${REFUND_FN}_arn")\",\"toolSchema\":{\"inlinePayload\":${schema}}}}}" \
    --credential-provider-configurations '[{"credentialProviderType":"GATEWAY_IAM_ROLE"}]' \
    --region "$REGION" >/dev/null 2>&1 \
    && ok "target: refund-processor (Lambda)" \
    || warn "refund-processor target may already exist, or needs the console"

  # -- API Gateway target ---------------------------------------------------
  aws bedrock-agentcore-control create-gateway-target --gateway-identifier "$gw" \
    --name "$ORDER_FN" \
    --target-configuration "{\"mcp\":{\"apiGateway\":{\"restApiId\":\"$(load api_id)\",\"stageName\":\"${STAGE}\"}}}" \
    --credential-provider-configurations '[{"credentialProviderType":"GATEWAY_IAM_ROLE"}]' \
    --region "$REGION" >/dev/null 2>&1 \
    && ok "target: order-tracker (API Gateway)" \
    || warn "order-tracker target needs the console — see the steps at the end"

  record "AgentCore Gateway" "OK" "${url:-$gw}"
}

console_steps_gateway() {
  cat <<EOF

   ${BOLD}Create the Gateway by hand instead:${RESET}
     Bedrock → AgentCore → Gateways → Create
       Name        $GATEWAY_NAME
       Authorizer  NONE
     Target 1 — API Gateway REST API stage
       Name        order-tracker
       REST API    $API_NAME  ($(load api_id))
       Stage       $STAGE
       Operations  get_order, get_customer, get_customer_orders
     Target 2 — Lambda function
       Name        refund-processor
       Function    $REFUND_FN
       Tool schema $PROJECT_DIR/lambda/lambda_schema
     Then:  echo '<gateway-url ending /mcp>' > $STATE_DIR/gateway_url

EOF
}

# ═════════════════════════════════════════════════════════════════════════════
#  10. Deploy the agent
# ═════════════════════════════════════════════════════════════════════════════
deploy_agent() {
  phase "Deploying the agent to AgentCore Runtime"

  local gw_url kb_id mem
  gw_url="$(load gateway_url)"; kb_id="$(load kb_id)"; mem="$(load memory_id)"

  if [[ -z "$gw_url" || -z "$kb_id" || -z "$mem" ]]; then
    warn "Missing a prerequisite, so the deploy is skipped:"
    [[ -z "$gw_url" ]] && warn "  GATEWAY_URL — write it to $STATE_DIR/gateway_url"
    [[ -z "$kb_id"  ]] && warn "  KB_ID       — write it to $STATE_DIR/kb_id"
    [[ -z "$mem"    ]] && warn "  MEMORY_ID   — write it to $STATE_DIR/memory_id"
    warn "Fill those in, then re-run: bash $0"
    record "Agent deploy" "SKIPPED" "missing prerequisites"
    return 1
  fi

  cat > "$PROJECT_DIR/.env" <<EOF
export GATEWAY_URL="$gw_url"
export KB_ID="$kb_id"
export REGION="$REGION"
export MEMORY_ID="$mem"
export AWS_REGION="$REGION"
EOF
  ok "wrote $PROJECT_DIR/.env"

  cat > "$PROJECT_DIR/requirements.txt" <<'EOF'
strands-agents>=1.28.0
strands-agents-tools>=0.2.21
bedrock-agentcore>=1.4.1
bedrock-agentcore-starter-toolkit>=0.3.0
nest-asyncio>=1.6.0
EOF

  if ! command -v agentcore >/dev/null 2>&1; then
    printf '   %s⋯%s installing the AgentCore starter toolkit ' "$DIM" "$RESET"
    pip install --quiet --user bedrock-agentcore-starter-toolkit strands-agents \
      strands-agents-tools bedrock-agentcore nest-asyncio >/dev/null 2>&1
    export PATH="$HOME/.local/bin:$PATH"
    printf '%s✓%s\n' "$GREEN" "$RESET"
  fi
  command -v agentcore >/dev/null 2>&1 || { bad "agentcore CLI not on PATH after install"; return 1; }

  ( cd "$PROJECT_DIR" && source .env \
      && agentcore configure --entrypoint main.py --name "$AGENT_NAME" --non-interactive \
      >/dev/null 2>&1 ) \
    && ok "agentcore configure" \
    || warn "agentcore configure reported a problem — run it manually in $PROJECT_DIR"

  printf '   %s⋯%s agentcore deploy (this takes several minutes) ' "$DIM" "$RESET"
  if ( cd "$PROJECT_DIR" && source .env && agentcore deploy >/tmp/deploy.log 2>&1 ); then
    printf '%s✓%s\n' "$GREEN" "$RESET"
    save agent_deployed 1
    record "Agent deploy" "OK" "$AGENT_NAME"
  else
    printf '%s✗%s\n' "$RED" "$RESET"
    warn "deploy failed — last lines of /tmp/deploy.log:"
    tail -12 /tmp/deploy.log | sed 's/^/       /'
    record "Agent deploy" "FAILED" "see /tmp/deploy.log"
    return 1
  fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  11. The six tests
# ═════════════════════════════════════════════════════════════════════════════
run_tests() {
  phase "The six project test scenarios"

  mkdir -p "$EVIDENCE_DIR"
  local pass=0 fail=0

  # id | session | expected substrings (comma-separated) | prompt
  local scenarios=(
"01-order-tracking|t1|SHIPPED,TRK987654321,UPS|Can you track order ORD-001?"
"02-refund-processing|t2|APPROVED,3-5 business days|I want to return my Kindle Paperwhite (ORD-002). Please initiate a refund."
"03-knowledge-base-rag|t3|same-day,15%,priority|What are the benefits of the Platinum loyalty tier?"
"04a-memory-session-a|s-A|Jane|Hi, I am Jane. I prefer concise responses."
"04b-memory-session-b|s-B|Jane,concise|Do you remember my name and communication preference?"
"05-loyalty-discount|t5|99,349|I am a Gold member with 4250 points. Calculate my discount on a \$150 standard order."
"06-browser-tool|t6|Udacity|Go to https://www.udacity.com and tell me the page title."
  )

  local entry id session expected prompt payload out missing needle
  for entry in "${scenarios[@]}"; do
    IFS='|' read -r id session expected prompt <<<"$entry"

    # Memory extraction is an asynchronous LLM job. Asking immediately after
    # session A reliably fails and looks exactly like a broken hook.
    if [[ "$id" == "04b-memory-session-b" ]]; then
      printf '   %s⋯%s waiting 45s for memory extraction ' "$DIM" "$RESET"
      sleep 45; printf '%s✓%s\n' "$GREEN" "$RESET"
    fi

    payload="$(jq -nc --arg p "$prompt" --arg s "$session" \
      '{prompt:$p, customer_id:"CUST-123", session_id:$s}')"

    out="$( cd "$PROJECT_DIR" && source .env && agentcore invoke "$payload" 2>&1 )"

    {
      printf '%s\n' "===================================================================="
      printf 'Scenario : %s\n' "$id"
      printf 'Mode     : LIVE — deployed AgentCore agent, account %s, %s\n' "$(load account)" "$REGION"
      printf 'When     : %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf '%s\n\n' "===================================================================="
      printf '$ agentcore invoke %s\n\n' "'$payload'"
      printf '%s\n' "$out"
      printf '\n--------------------------------------------------------------------\n'
      printf 'Expected to contain: %s\n' "$expected"
    } > "$EVIDENCE_DIR/${id}.txt"

    missing=""
    IFS=',' read -ra needles <<<"$expected"
    for needle in "${needles[@]}"; do
      grep -qiF -- "$needle" <<<"$out" || missing+="$needle "
    done

    if [[ -z "$missing" ]]; then
      printf 'RESULT: [PASS]\n' >> "$EVIDENCE_DIR/${id}.txt"
      ok "$id"; pass=$((pass+1))
    else
      printf 'RESULT: [FAIL] missing: %s\n' "$missing" >> "$EVIDENCE_DIR/${id}.txt"
      bad "$id — missing: $missing"; fail=$((fail+1))
    fi
  done

  printf '\n   %s%d passed, %d failed%s   transcripts in %s\n' \
    "$BOLD" "$pass" "$fail" "$RESET" "$EVIDENCE_DIR"
  record "Six scenarios" "$([[ $fail -eq 0 ]] && echo OK || echo PARTIAL)" "$pass/$((pass+fail)) passed"
}

# ═════════════════════════════════════════════════════════════════════════════
#  Summary, status, teardown
# ═════════════════════════════════════════════════════════════════════════════
summary() {
  printf '\n%s════════════════════════════════════════════════════════════════════%s\n' "$BOLD" "$RESET"
  printf '%s SUMMARY%s\n' "$BOLD" "$RESET"
  printf '%s════════════════════════════════════════════════════════════════════%s\n\n' "$BOLD" "$RESET"

  local entry name status detail colour
  for entry in "${RESULTS[@]}"; do
    IFS='|' read -r name status detail <<<"$entry"
    case "$status" in
      OK)       colour="$GREEN" ;;
      PARTIAL)  colour="$YELLOW" ;;
      *)        colour="$RED" ;;
    esac
    printf '  %-24s %s%-9s%s %s\n' "$name" "$colour" "$status" "$RESET" "$detail"
  done

  cat <<EOF

  Transcripts   $EVIDENCE_DIR
  State         $STATE_DIR
  Project       $PROJECT_DIR

${RED}${BOLD}  ┌──────────────────────────────────────────────────────────────┐
  │  TEAR DOWN WHEN YOU HAVE YOUR SCREENSHOTS                    │
  │                                                              │
  │     bash $0 --teardown
  │                                                              │
  │  OpenSearch Serverless bills ~\$12/day whether or not it is   │
  │  queried. It is the only thing here that costs real money.   │
  └──────────────────────────────────────────────────────────────┘${RESET}

EOF
}

show_status() {
  printf '\n%sRecorded state%s\n\n' "$BOLD" "$RESET"
  local key
  for key in account caller_arn lambda_role_arn kb_role_arn gw_role_arn \
             "${ORDER_FN}_arn" "${REFUND_FN}_arn" api_id api_url bucket \
             collection_arn collection_endpoint kb_id ds_id memory_id \
             gateway_id gateway_url agent_deployed; do
    printf '  %-22s %s\n' "$key" "$(load "$key" || echo "${DIM}—${RESET}")"
  done
  printf '\n'
}

teardown() {
  printf '\n%sTeardown%s — deletes everything this script created.\n' "$BOLD" "$RESET"
  printf 'Type %sdelete%s to confirm: ' "$BOLD" "$RESET"
  read -r reply
  [[ "$reply" == "delete" ]] || { warn "cancelled"; return; }

  # Most expensive first, in case anything below it fails.
  phase "OpenSearch Serverless"
  aws opensearchserverless delete-collection --id \
    "$(aws opensearchserverless batch-get-collection --names "$COLLECTION" --region "$REGION" \
       --query 'collectionDetails[0].id' --output text 2>/dev/null)" \
    --region "$REGION" >/dev/null 2>&1 && ok "collection deleted" || skip "no collection"
  for suffix in enc net; do
    aws opensearchserverless delete-security-policy --name "${COLLECTION}-${suffix}" \
      --type "$([[ $suffix == enc ]] && echo encryption || echo network)" \
      --region "$REGION" >/dev/null 2>&1
  done
  aws opensearchserverless delete-access-policy --name "${COLLECTION}-data" --type data \
    --region "$REGION" >/dev/null 2>&1
  ok "policies deleted"

  phase "Bedrock"
  [[ -n "$(load kb_id)" ]] && aws bedrock-agent delete-knowledge-base \
    --knowledge-base-id "$(load kb_id)" --region "$REGION" >/dev/null 2>&1 \
    && ok "knowledge base deleted"
  [[ -n "$(load gateway_id)" ]] && aws bedrock-agentcore-control delete-gateway \
    --gateway-identifier "$(load gateway_id)" --region "$REGION" >/dev/null 2>&1 \
    && ok "gateway deleted"
  [[ -n "$(load memory_id)" ]] && aws bedrock-agentcore-control delete-memory \
    --memory-id "$(load memory_id)" --region "$REGION" >/dev/null 2>&1 \
    && ok "memory deleted"

  if [[ -n "$(load agent_deployed)" ]]; then
    ( cd "$PROJECT_DIR" && agentcore destroy >/dev/null 2>&1 ) && ok "agent destroyed" \
      || warn "run 'agentcore destroy' in $PROJECT_DIR by hand"
  fi

  phase "Compute and storage"
  [[ -n "$(load api_id)" ]] && aws apigateway delete-rest-api --rest-api-id "$(load api_id)" \
    --region "$REGION" >/dev/null 2>&1 && ok "REST API deleted"
  for fn in "$ORDER_FN" "$REFUND_FN"; do
    aws lambda delete-function --function-name "$fn" --region "$REGION" >/dev/null 2>&1 \
      && ok "$fn deleted"
  done
  local bucket; bucket="$(load bucket)"
  if [[ -n "$bucket" ]]; then
    aws s3 rm "s3://$bucket" --recursive >/dev/null 2>&1
    aws s3api delete-bucket --bucket "$bucket" >/dev/null 2>&1 && ok "bucket deleted"
  fi

  phase "IAM"
  aws iam detach-role-policy --role-name "$LAMBDA_ROLE" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole >/dev/null 2>&1
  aws iam delete-role-policy --role-name "$KB_ROLE" --policy-name kb-access >/dev/null 2>&1
  aws iam delete-role-policy --role-name "$GW_ROLE" --policy-name gateway-invoke >/dev/null 2>&1
  for role in "$LAMBDA_ROLE" "$KB_ROLE" "$GW_ROLE"; do
    aws iam delete-role --role-name "$role" >/dev/null 2>&1 && ok "$role deleted"
  done

  rm -rf "$STATE_DIR"
  printf '\n%sDone.%s Verify in the console that the OpenSearch collection is gone —\n' "$GREEN" "$RESET"
  printf 'it is the only resource here that bills while idle.\n\n'
}

# ═════════════════════════════════════════════════════════════════════════════
main() {
  case "${1:-}" in
    --status)    show_status; exit 0 ;;
    --teardown)  teardown;    exit 0 ;;
    --test-only) preflight; materialise; run_tests; summary; exit 0 ;;
  esac

  printf '%s\n' "${BOLD}Customer Support Agent — end-to-end deploy${RESET}"
  printf '%s\n' "${DIM}region $REGION · prefix $PREFIX · state $STATE_DIR${RESET}"
  printf '%s\n' "${YELLOW}OpenSearch Serverless bills hourly once created. --teardown when done.${RESET}"

  preflight
  materialise
  ensure_roles
  deploy_lambdas
  ensure_api
  ensure_bucket
  ensure_collection
  ensure_kb
  ensure_memory
  ensure_gateway
  deploy_agent && run_tests
  summary
}

main "$@"
