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
#     bash deploy-e2e.sh --package    zip main.py + transcripts for submission
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

# This file is a TEMPLATE, not the deliverable. The embedded project files are
# substituted in by scripts/build_cloudshell_script.py, which writes
# cloudshell/deploy-e2e.sh. Running the template directly writes no project
# files, and then silently reuses whatever happens to be on disk — so refuse.
if grep -q '^__EMBEDDED''_FILES__$' "${BASH_SOURCE[0]}" 2>/dev/null; then
  cat >&2 <<'REFUSE'
This is the template, not the runnable script.

  Run the generated one instead:

    curl -sSL https://raw.githubusercontent.com/astral-fate/agentic-ai-aws-nanodegree-project-2/main/cloudshell/deploy-e2e.sh -o deploy-e2e.sh
    bash deploy-e2e.sh

REFUSE
  exit 2
fi

# ── Configuration ────────────────────────────────────────────────────────────
# Bumped on every fix. The generated file is named deploy-e2e-<version>.sh and
# the banner prints it, so an uploaded copy can never be confused with an older
# one sitting in the same directory — which has already happened once.
SCRIPT_VERSION="v14"

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
  ok "pyproject.toml"
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

  # stdout redirected too: recent CLI versions print a JSON body on success.
  if aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
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

  local caller kb_role indexer
  caller="$(load caller_arn)"; kb_role="$(load kb_role_arn)"
  indexer="$(ensure_indexer_user)"

  # Three policies must exist before the collection, or creation fails.
  aws opensearchserverless create-security-policy --name "${COLLECTION}-enc" --type encryption \
    --policy "{\"Rules\":[{\"ResourceType\":\"collection\",\"Resource\":[\"collection/${COLLECTION}\"]}],\"AWSOwnedKey\":true}" \
    --region "$REGION" >/dev/null 2>&1 && ok "encryption policy" || skip "encryption policy exists"

  aws opensearchserverless create-security-policy --name "${COLLECTION}-net" --type network \
    --policy "[{\"Rules\":[{\"ResourceType\":\"collection\",\"Resource\":[\"collection/${COLLECTION}\"]},{\"ResourceType\":\"dashboard\",\"Resource\":[\"collection/${COLLECTION}\"]}],\"AllowFromPublic\":true}]" \
    --region "$REGION" >/dev/null 2>&1 && ok "network policy" || skip "network policy exists"

  # Principals: the indexer role (which actually creates the index), the KB
  # service role, and the caller. The caller is included for convenience but
  # is NOT relied on — when the caller is the account root, OpenSearch
  # Serverless does not match it, which is why the indexer role exists.
  local principals
  principals="$(printf '"%s","%s"' "$indexer" "$kb_role")"
  [[ "$caller" != *":root" ]] && principals="${principals},\"${caller}\""

  sync_data_access_policy "$indexer" "$principals" || return 1

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

# Write the data access policy, then prove it took.
#
# The previous version created-or-updated and moved on. When the update failed
# — which it does, silently, if the policy version is stale — the collection
# kept an older policy naming a principal that no longer signs anything, and
# the only symptom was a bare 403 five minutes later at index creation. So
# this reads the policy back and refuses to continue unless the principal that
# will actually sign the request is in it.
sync_data_access_policy() {
  local indexer="$1" principals="$2"
  local name="${COLLECTION}-data" policy out version

  policy="[{\"Rules\":[{\"ResourceType\":\"index\",\"Resource\":[\"index/${COLLECTION}/*\"],\"Permission\":[\"aoss:*\"]},{\"ResourceType\":\"collection\",\"Resource\":[\"collection/${COLLECTION}\"],\"Permission\":[\"aoss:*\"]}],\"Principal\":[${principals}]}]"

  out="$(aws opensearchserverless create-access-policy --name "$name" --type data \
    --policy "$policy" --region "$REGION" 2>&1)"

  if grep -q '"name"' <<<"$out"; then
    ok "data access policy created"
  else
    version="$(aws opensearchserverless get-access-policy --name "$name" --type data \
      --region "$REGION" --query 'accessPolicyDetail.policyVersion' --output text 2>/dev/null)"

    if [[ -z "$version" || "$version" == "None" ]]; then
      bad "could not read the data access policy version: $(head -c 200 <<<"$out")"
      return 1
    fi

    out="$(aws opensearchserverless update-access-policy --name "$name" --type data \
      --policy-version "$version" --policy "$policy" --region "$REGION" 2>&1)"
    if grep -q '"name"' <<<"$out"; then
      ok "data access policy updated (was version $version)"
    elif grep -q "No changes detected" <<<"$out"; then
      # The policy already says exactly what we were about to write. That is
      # the desired state, not an error — treating it as one is what stopped
      # the previous run before it reached the read-back check below.
      ok "data access policy already current"
    else
      bad "could not update the data access policy: $(head -c 240 <<<"$out")"
      return 1
    fi
  fi

  # Read back and confirm the signing principal is really there.
  local current
  current="$(aws opensearchserverless get-access-policy --name "$name" --type data \
    --region "$REGION" --output json 2>/dev/null)"

  if grep -qF "$indexer" <<<"$current"; then
    ok "policy names $indexer"
  else
    bad "the data access policy does not name $indexer — index creation would 403"
    printf '       current principals: %s\n' \
      "$(jq -r '[.accessPolicyDetail.policy[].Principal[]] | join(", ")' <<<"$current" 2>/dev/null)"
    return 1
  fi

  # A policy change is not effective the instant the API returns.
  printf '   %s⋯%s waiting 30s for the policy to take effect ' "$DIM" "$RESET"
  sleep 30
  printf '%s✓%s\n' "$GREEN" "$RESET"
}

# An identity that exists purely to create the vector index.
#
# OpenSearch Serverless matches data-access policies against the *signing*
# principal, and the account root never matches — a root-signed request gets a
# bare 403 with no explanation. CloudShell is very often running as root, so
# the script needs a non-root principal to sign with.
#
# It cannot be a role: AWS does not permit the account root user to call
# sts:AssumeRole at all, so the obvious "mint a role and assume it" approach
# fails for exactly the identity that needs it. It has to be an IAM user with
# its own access key. The key is created just before the index request and
# deleted immediately afterwards by delete_indexer_key, including on failure.
ensure_indexer_user() {
  local name="${PREFIX}-indexer" arn

  arn="$(aws iam get-user --user-name "$name" --query User.Arn --output text 2>/dev/null)"
  if [[ -z "$arn" || "$arn" == "None" ]]; then
    arn="$(aws iam create-user --user-name "$name" --query User.Arn --output text 2>/dev/null)"
    sleep 10
  fi

  # Attached unconditionally, not only on creation. A user left over from an
  # earlier run whose policy call failed would otherwise look fine here and
  # then 403 at the index request, with nothing to distinguish it from a data
  # access policy problem.
  #
  # stdout is redirected, not just stderr: this function's stdout IS the
  # returned ARN, so anything else printed would be concatenated onto it.
  [[ -n "$arn" && "$arn" != "None" ]] && \
    aws iam put-user-policy --user-name "$name" --policy-name aoss-index \
      --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["aoss:APIAccessAll"],"Resource":"*"}]}' \
      >/dev/null 2>&1

  save indexer_user_arn "$arn"
  printf '%s' "$arn"
}

# Remove every access key on the indexer user. Called before minting a new one
# (IAM allows only two) and again once the index exists.
delete_indexer_key() {
  local name="${PREFIX}-indexer" key
  for key in $(aws iam list-access-keys --user-name "$name" \
                 --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null); do
    aws iam delete-access-key --user-name "$name" --access-key-id "$key" >/dev/null 2>&1
  done
}

# The vector index is created over the OpenSearch REST API, signed with SigV4
# for the 'aoss' service, using credentials from the assumed indexer role.
# botocore ships with CloudShell, so there is no pip install to fail.
create_vector_index() {
  local endpoint="$1"
  local keys access secret status

  delete_indexer_key
  keys="$(aws iam create-access-key --user-name "${PREFIX}-indexer" \
    --query AccessKey --output json 2>/dev/null)"

  if [[ -z "$keys" || "$keys" == "None" ]]; then
    bad "could not create an access key for ${PREFIX}-indexer"
    return 1
  fi
  access="$(jq -r .AccessKeyId <<<"$keys")"
  secret="$(jq -r .SecretAccessKey <<<"$keys")"
  ok "minted a temporary key for ${PREFIX}-indexer"

  # A brand-new IAM access key is not accepted immediately — propagation is
  # usually seconds but can run past half a minute, and the symptom is the
  # same 403 as a policy problem.
  printf '   %s⋯%s waiting 45s for the new key to propagate ' "$DIM" "$RESET"
  sleep 45
  printf '%s✓%s\n' "$GREEN" "$RESET"

  # env -u, not AWS_SESSION_TOKEN="". CloudShell exports a session token for
  # the ambient identity; botocore treats an empty-string token as a token and
  # signs with it, so the request carries an empty x-amz-security-token
  # alongside a long-lived key and is rejected. The variable has to be absent.
  env -u AWS_SESSION_TOKEN -u AWS_PROFILE -u AWS_SECURITY_TOKEN \
    AWS_ACCESS_KEY_ID="$access" \
    AWS_SECRET_ACCESS_KEY="$secret" \
  python3 - "$endpoint" "$INDEX_NAME" "$VECTOR_FIELD" "$EMBED_DIM" "$REGION" <<'PYEOF'
import hashlib
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
            # space_type, not spaceType. The index mapping is the OpenSearch
            # API, which is snake_case throughout — it is not an AWS API and
            # does not follow AWS naming. The camelCase spelling is rejected
            # with "mapper_parsing_exception: Invalid parameter: spaceType".
            "method": {"name": "hnsw", "engine": "faiss", "space_type": "l2"},
        },
        "AMAZON_BEDROCK_TEXT_CHUNK": {"type": "text"},
        "AMAZON_BEDROCK_METADATA": {"type": "text", "index": False},
    }},
})

session = botocore.session.Session()
creds = session.get_credentials().get_frozen_credentials()
url = f"{endpoint}/{index}"

# Confirm which identity is actually signing. A 403 from OpenSearch says
# nothing about who it rejected, and the whole point of the indexer user is
# that the ambient (root) credentials must NOT be the ones in play.
try:
    sts = botocore.session.Session().create_client("sts", region_name=region)
    who = sts.get_caller_identity()["Arn"]
    print(f"   · signing as {who}")
    if who.endswith(":root"):
        print("   ! signing as root — OpenSearch Serverless will reject this")
except Exception as exc:  # identity check must never block the attempt
    print(f"   · could not confirm the signing identity: {exc}")

if creds.token:
    print("   ! a session token is present alongside the key; this will 403")

def send(method, url, body=None):
    """
    Sign and send one request to the collection.

    OpenSearch Serverless requires an explicit x-amz-content-sha256 header.
    botocore's plain SigV4Auth computes the payload hash for the canonical
    request but only *emits* that header for the S3 signers, so an aoss
    request signed with it is rejected — with a bare 403 that looks exactly
    like a permissions problem, which is what sent the last three rounds of
    this chasing identities and policies. opensearch-py's own AWSV4SignerAuth
    sets the same header for the aoss service.
    """
    payload = body.encode("utf-8") if isinstance(body, str) else (body or b"")

    request = AWSRequest(
        method=method,
        url=url,
        data=body,
        headers={
            "Content-Type": "application/json",
            "X-Amz-Content-SHA256": hashlib.sha256(payload).hexdigest(),
        },
    )
    SigV4Auth(creds, "aoss", region).add_auth(request)
    return URLLib3Session().send(request.prepare())

def body_of(response):
    return response.text if hasattr(response, "text") else response.content.decode()


if send("HEAD", url).status_code == 200:
    print("   · vector index already exists")
    sys.exit(0)

# A data access policy edit is not effective immediately, and the symptom is a
# bare 403 with no explanation. Retry rather than fail on the first one.
ATTEMPTS = 6
for attempt in range(1, ATTEMPTS + 1):
    response = send("PUT", url, body)
    text = body_of(response)

    if response.status_code in (200, 201):
        print(f"   ✓ vector index {index} created")
        # Acknowledged is not the same as queryable, and the Knowledge Base
        # fails opaquely with "no such index" if it is created too soon.
        time.sleep(45)
        sys.exit(0)

    if "resource_already_exists_exception" in text:
        print("   · vector index already exists")
        sys.exit(0)

    if response.status_code == 403 and attempt < ATTEMPTS:
        print(f"   · 403 from OpenSearch, retrying in 20s "
              f"({attempt}/{ATTEMPTS - 1}) — data access policy propagating")
        time.sleep(20)
        continue

    print(f"   ! vector index creation returned {response.status_code}: {text[:300]}")
    if response.status_code == 403:
        print("     The signing principal is not in the collection's data access")
        print("     policy. Check that the policy names the indexer user.")
    sys.exit(1)
PYEOF
  status=$?

  # Delete the key whether the index succeeded or not: it is a long-lived
  # credential and it has no further use.
  delete_indexer_key
  ok "revoked the temporary indexer key"

  return $status
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

  # The project's own Check 3. Retried because a completed ingestion job does
  # not mean the vectors are searchable yet — the first query after a sync
  # routinely returns nothing for a minute or so.
  local answer attempt
  for attempt in 1 2 3 4 5 6; do
    answer="$(aws bedrock-agent-runtime retrieve --knowledge-base-id "$kb_id" \
      --retrieval-query '{"text":"What is the return policy for electronics?"}' \
      --region "$REGION" --query 'retrievalResults[0].content.text' --output text 2>/dev/null)"
    if grep -q "15 days" <<<"$answer"; then
      ok "retrieval check: electronics → 15 days"
      record "Knowledge Base" "OK" "$kb_id"
      return 0
    fi
    [[ $attempt -lt 6 ]] && {
      printf '   %s·%s retrieval empty, waiting 20s (%d/5)\n' "$DIM" "$RESET" "$attempt"
      sleep 20
    }
  done

  warn "retrieval still not returning the catalog — the agent will answer"
  warn "policy questions without grounding until it does"
  record "Knowledge Base" "PARTIAL" "$kb_id"
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

  # A target that already exists is not an error, so check first rather than
  # reading "already exists" as a failure.
  local existing_targets
  existing_targets="$(aws bedrock-agentcore-control list-gateway-targets \
    --gateway-identifier "$gw" --region "$REGION" \
    --query 'items[].name' --output text 2>/dev/null)"

  # -- Lambda target --------------------------------------------------------
  if grep -qw "$REFUND_FN" <<<"$existing_targets"; then
    skip "target refund-processor exists"
  else
    local schema out
    schema="$(cat "$PROJECT_DIR/lambda/lambda_schema")"
    out="$(aws bedrock-agentcore-control create-gateway-target --gateway-identifier "$gw" \
      --name "$REFUND_FN" \
      --target-configuration "{\"mcp\":{\"lambda\":{\"lambdaArn\":\"$(load "${REFUND_FN}_arn")\",\"toolSchema\":{\"inlinePayload\":${schema}}}}}" \
      --credential-provider-configurations '[{"credentialProviderType":"GATEWAY_IAM_ROLE"}]' \
      --region "$REGION" 2>&1)"
    if grep -q '"targetId"' <<<"$out"; then
      ok "target: refund-processor (Lambda)"
    else
      bad "refund-processor target: $(head -c 220 <<<"$out")"
    fi
  fi

  # -- API Gateway target ---------------------------------------------------
  if grep -qw "$ORDER_FN" <<<"$existing_targets"; then
    skip "target order-tracker exists"
  else
    create_openapi_target "$gw"
  fi

  record "AgentCore Gateway" "OK" "${url:-$gw}"
}

# The console's "API Gateway REST API stage" target is an OpenAPI target
# underneath: API Gateway exports the spec, and each method's operationName
# becomes an operationId, which becomes the MCP tool name. Exporting the spec
# and registering it directly does the same thing from the CLI.
create_openapi_target() {
  local gw="$1"
  local api url spec
  api="$(load api_id)"; url="$(load api_url)"

  if ! aws apigateway get-export --rest-api-id "$api" --stage-name "$STAGE" \
        --export-type oas30 --accepts application/json \
        --region "$REGION" /tmp/openapi.json >/dev/null 2>&1; then
    warn "could not export the OpenAPI spec from API Gateway"
    console_steps_api_target; return 1
  fi

  # The export has no `servers` block, so the Gateway would not know where to
  # send the call. Add it, and confirm the three operationIds survived — they
  # are what become the MCP tool names.
  #
  # The operation list is written to a file by python rather than returned on
  # a stream: a redirect placed after an assignment applies to the assignment,
  # not to the command substitution inside it, so the earlier version sent the
  # list to the terminal and then reported it as missing.
  python3 - "$url" <<'PYEOF'
import json, sys

spec = json.load(open("/tmp/openapi.json"))
spec["servers"] = [{"url": sys.argv[1]}]

ops = [op.get("operationId")
       for path in spec.get("paths", {}).values()
       for op in path.values() if isinstance(op, dict)]

with open("/tmp/openapi-final.json", "w") as fh:
    json.dump(spec, fh)
with open("/tmp/ops.txt", "w") as fh:
    fh.write(",".join(o for o in ops if o))
PYEOF

  local ops; ops="$(cat /tmp/ops.txt 2>/dev/null)"
  if [[ -z "$ops" ]]; then
    warn "the exported spec has no operationIds — the Gateway would expose no tools"
    console_steps_api_target; return 1
  fi
  ok "exported OpenAPI spec, operations: $ops"

  local out bucket
  local api_id; api_id="$(load api_id)"

  # The native apiGateway target — the same thing the console's "API Gateway
  # REST API stage" option creates. The field is `stage`, not `stageName`;
  # that single word was the original failure, and the error message
  # ("IamCredentialProvider is required for openApiSchema targets") sent me
  # down the OpenAPI path instead, because an unknown key made the CLI fall
  # through to a different member of the union.
  out="$(aws bedrock-agentcore-control create-gateway-target --gateway-identifier "$gw" \
    --name "$ORDER_FN" \
    --target-configuration "{\"mcp\":{\"apiGateway\":{\"restApiId\":\"${api_id}\",\"stage\":\"${STAGE}\"}}}" \
    --credential-provider-configurations '[{"credentialProviderType":"GATEWAY_IAM_ROLE"}]' \
    --region "$REGION" 2>&1)"
  if grep -q '"targetId"' <<<"$out"; then
    ok "target: order-tracker (API Gateway stage)"; return 0
  fi
  warn "apiGateway target failed: $(head -c 240 <<<"$out")"

  # OpenAPI is the documented alternative. Its iamCredentialProvider needs
  # `service` and `region` — the signing target, not a role ARN, since the
  # Gateway signs execute-api calls with its own gateway role.
  local creds
  creds="[{\"credentialProviderType\":\"GATEWAY_IAM_ROLE\",\"credentialProvider\":{\"iamCredentialProvider\":{\"service\":\"execute-api\",\"region\":\"${REGION}\"}}}]"

  out="$(aws bedrock-agentcore-control create-gateway-target --gateway-identifier "$gw" \
    --name "${ORDER_FN}-openapi" \
    --target-configuration "{\"mcp\":{\"openApiSchema\":{\"inlinePayload\":$(jq -Rs . < /tmp/openapi-final.json)}}}" \
    --credential-provider-configurations "$creds" \
    --region "$REGION" 2>&1)"
  if grep -q '"targetId"' <<<"$out"; then
    ok "target: order-tracker (OpenAPI, inline)"; return 0
  fi
  warn "inline OpenAPI target failed: $(head -c 240 <<<"$out")"

  # The inline payload has a size limit; S3 is the route above it.
  bucket="$(load bucket)"
  aws s3 cp /tmp/openapi-final.json "s3://${bucket}/openapi.json" --region "$REGION" >/dev/null 2>&1
  out="$(aws bedrock-agentcore-control create-gateway-target --gateway-identifier "$gw" \
    --name "${ORDER_FN}-openapi" \
    --target-configuration "{\"mcp\":{\"openApiSchema\":{\"s3\":{\"uri\":\"s3://${bucket}/openapi.json\",\"bucketOwnerAccountId\":\"$(load account)\"}}}}" \
    --credential-provider-configurations "$creds" \
    --region "$REGION" 2>&1)"
  if grep -q '"targetId"' <<<"$out"; then
    ok "target: order-tracker (OpenAPI, from S3)"; return 0
  fi
  warn "S3 OpenAPI target failed: $(head -c 240 <<<"$out")"

  print_target_schema
  console_steps_api_target
  return 1
}

# Print the CLI's own expected input shape for a gateway target.
#
# These shapes are not something to keep guessing at from error messages —
# the CLI model knows them exactly, so ask it. Printed only on failure, and
# it is the thing to paste when reporting one.
print_target_schema() {
  local skeleton
  skeleton="$(aws bedrock-agentcore-control create-gateway-target \
    --generate-cli-skeleton input --region "$REGION" 2>/dev/null)"
  [[ -z "$skeleton" ]] && return 0

  printf '\n   %sThe CLI expects these shapes:%s\n' "$BOLD" "$RESET"
  printf '     credentialProviderConfigurations:\n'
  jq -c '.credentialProviderConfigurations' <<<"$skeleton" 2>/dev/null | sed 's/^/       /'
  printf '     targetConfiguration:\n'
  jq -c '.targetConfiguration' <<<"$skeleton" 2>/dev/null | sed 's/^/       /'
  printf '\n'
}

console_steps_api_target() {
  cat <<EOF

   ${BOLD}Add the order-tracker target in the console (about a minute):${RESET}
     Bedrock → AgentCore → Gateways → $GATEWAY_NAME → Add target
       Target name  order-tracker
       Target type  API Gateway REST API stage
       REST API     $API_NAME  ($(load api_id))
       Stage        $STAGE
       Operations   get_order, get_customer, get_customer_orders
     Then re-run:  bash \$0

EOF
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
# Install the AgentCore starter toolkit and get its CLI onto PATH.
#
# The previous version piped pip to /dev/null and then reported "not on PATH",
# which is the least useful of the several things that can go wrong here — a
# pip resolution failure, a Python too old for the package, and a script
# directory that is genuinely not on PATH all looked identical. Nothing is
# silenced now, and the script directory is asked of Python rather than
# assumed to be ~/.local/bin.
# Install the AgentCore starter toolkit into a dedicated virtualenv.
#
# Not `pip install --user`: CloudShell's python3 is itself inside a
# virtualenv, where user site-packages are invisible and pip refuses outright
# ("Can not perform a '--user' install"). A venv of our own avoids that, gives
# the CLI a path that is known rather than guessed, and leaves CloudShell's
# own environment untouched.
install_agentcore_cli() {
  local venv="${HOME}/.${PREFIX}-venv"

  if [[ -x "${venv}/bin/agentcore" ]]; then
    export PATH="${venv}/bin:$PATH"
    hash -r 2>/dev/null
    ok "agentcore already installed: ${venv}/bin/agentcore"
    return 0
  fi

  if [[ ! -x "${venv}/bin/pip" ]]; then
    printf '   %s⋯%s creating a virtualenv at %s ' "$DIM" "$RESET" "$venv"
    if python3 -m venv "$venv" >/tmp/venv.log 2>&1; then
      printf '%s✓%s\n' "$GREEN" "$RESET"
    else
      printf '%s✗%s\n' "$RED" "$RESET"
      bad "could not create the virtualenv:"
      tail -10 /tmp/venv.log | sed 's/^/       /'
      return 1
    fi
  fi

  printf '   %s⋯%s installing the AgentCore starter toolkit (a few minutes) ' "$DIM" "$RESET"
  if "${venv}/bin/pip" install --quiet --upgrade pip >/tmp/pip.log 2>&1 && \
     "${venv}/bin/pip" install --quiet \
       bedrock-agentcore-starter-toolkit strands-agents strands-agents-tools \
       bedrock-agentcore nest-asyncio >>/tmp/pip.log 2>&1; then
    printf '%s✓%s\n' "$GREEN" "$RESET"
  else
    printf '%s✗%s\n' "$RED" "$RESET"
    bad "pip install failed:"
    tail -20 /tmp/pip.log | sed 's/^/       /'
    printf '       python3: %s — %s\n' "$(command -v python3)" "$(python3 -V 2>&1)"
    return 1
  fi

  export PATH="${venv}/bin:$PATH"
  hash -r 2>/dev/null

  if command -v agentcore >/dev/null 2>&1; then
    ok "agentcore at $(command -v agentcore)"
    return 0
  fi

  bad "the toolkit installed but its CLI is missing from ${venv}/bin"
  printf '       contents: %s\n' "$(ls "${venv}/bin" 2>/dev/null | tr '\n' ' ')"
  return 1
}

# Build requirements.txt from the starter's own pyproject.toml.
#
# It was hand-written before, and it omitted playwright. main.py imports
# strands_tools.browser, which imports playwright, so the container failed at
# import and the runtime never started — surfacing only as "An error occurred
# when starting the runtime" from InvokeAgentRuntime, several layers away from
# the cause. The authoritative dependency list ships with the project; there
# is no reason to maintain a second copy of it by hand.
write_requirements() {
  local src="$PROJECT_DIR/pyproject.toml"
  [[ -f "$src" ]] || { bad "missing $src"; return 1; }

  python3 - "$src" "$PROJECT_DIR/requirements.txt" <<'PYEOF'
import re
import sys

source, dest = sys.argv[1], sys.argv[2]
text = open(source, encoding="utf-8").read()

try:
    import tomllib
    deps = tomllib.loads(text)["project"]["dependencies"]
except Exception:
    block = re.search(r"dependencies\s*=\s*\[(.*?)\]", text, re.S)
    deps = re.findall(r'"([^"]+)"', block.group(1)) if block else []

# `asyncio` is excluded deliberately. It is a standard-library module; the
# PyPI package of that name is an abandoned 3.4.3 backport, so the declared
# ">=4.0.0" cannot resolve at all, and installing it would shadow the real
# module if it did.
def name_of(spec):
    return re.split(r"[<>=!~\[ ]", spec, maxsplit=1)[0].strip().lower()


kept = [d for d in deps if name_of(d) != "asyncio"]

with open(dest, "w", encoding="utf-8") as fh:
    fh.write("# Generated from pyproject.toml by deploy-e2e — do not hand-edit.\n")
    fh.write("\n".join(kept) + "\n")

print(f"   ✓ requirements.txt: {len(kept)} deps ({', '.join(sorted(kept))})")
PYEOF
}

# Show why the container refused to start.
#
# InvokeAgentRuntime reports "An error occurred when starting the runtime" and
# points at CloudWatch; the actual traceback is there, and fetching it here
# saves a round trip.
tail_runtime_logs() {
  local arn group
  arn="$(grep -oE 'runtime/[A-Za-z0-9_-]+' /tmp/probe.log 2>/dev/null | head -1 | cut -d/ -f2)"
  [[ -z "$arn" ]] && return 0

  group="/aws/bedrock-agentcore/runtimes/${arn}-DEFAULT"
  printf '\n       %sRuntime logs (%s):%s\n' "$BOLD" "$group" "$RESET"
  aws logs tail "$group" --since 15m --region "$REGION" 2>/dev/null \
    | grep -viE '^\s*$' | tail -30 | sed 's/^/       /' \
    || printf '       (no log events yet — the container may still be starting)\n'
}

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

  write_requirements || return 1

  install_agentcore_cli || return 1

  # `agentcore configure` is interactive — it prompts to confirm the detected
  # requirements file. /dev/null gave it EOF and it aborted ("Input is not a
  # terminal"), so feed it newlines instead: `yes ''` accepts the default for
  # that prompt and any other it adds later.
  #
  # Its options are recorded first, so if this still fails the log says what
  # flags exist rather than costing another round trip to find out.
  ( cd "$PROJECT_DIR" && agentcore configure --help ) >/tmp/configure-help.log 2>&1 || true

  rm -f "$PROJECT_DIR/.bedrock_agentcore.yaml"
  ( cd "$PROJECT_DIR" && source .env \
      && yes '' | agentcore configure --entrypoint main.py --name "$AGENT_NAME" \
      >/tmp/configure.log 2>&1 ) || true

  # Judged by the artifact, not the exit code: `yes` is killed by SIGPIPE when
  # the prompt closes, and under `set -o pipefail` that makes a successful
  # pipeline look like a failure.
  if [[ -f "$PROJECT_DIR/.bedrock_agentcore.yaml" ]]; then
    ok "agentcore configure — wrote .bedrock_agentcore.yaml"
  else
    bad "agentcore configure did not produce .bedrock_agentcore.yaml:"
    tail -18 /tmp/configure.log | sed 's/^/       /'
    printf '\n       %sAvailable options:%s\n' "$BOLD" "$RESET"
    grep -E '^\s+(-|--)' /tmp/configure-help.log | head -20 | sed 's/^/       /'
    return 1
  fi

  # The toolkit has renamed this command across versions — older releases
  # expose `launch`, newer ones `deploy`. Read the actual command list rather
  # than assuming either.
  # Matched as whole words anywhere in the help text. The previous version
  # anchored on leading whitespace, which finds nothing when the CLI renders
  # its help in a Rich table — the command names sit behind box-drawing
  # characters, not spaces — and it then reported "no deploy command found"
  # while printing an empty list, which is worse than not checking at all.
  local deploy_cmd=""
  ( cd "$PROJECT_DIR" && agentcore --help ) >/tmp/agentcore-help.log 2>&1 || true

  if grep -qw "deploy" /tmp/agentcore-help.log; then
    deploy_cmd="deploy"
  elif grep -qw "launch" /tmp/agentcore-help.log; then
    deploy_cmd="launch"
  fi

  if [[ -z "$deploy_cmd" ]]; then
    bad "no deploy/launch command found. Full 'agentcore --help':"
    sed 's/^/       /' /tmp/agentcore-help.log | head -60
    record "Agent deploy" "FAILED" "no deploy command found"
    return 1
  fi

  printf '   %s⋯%s agentcore %s (this takes several minutes) ' "$DIM" "$RESET" "$deploy_cmd"

  # The deprecation banner is suppressed so it cannot crowd the real error out
  # of the log tail — which is exactly what happened on the previous run.
  # --auto-update-on-conflict, because this script is meant to be re-run.
  #
  # Without it, a second deploy fails with ConflictException ("Agent already
  # exists"), CreateAgentRuntime never returns an ARN, nothing gets recorded
  # locally, and every subsequent invoke reports "Agent not deployed" — a
  # confusing way to say "the agent is deployed, but this CLI does not know
  # where". The toolkit names the flag in that error; it is used here rather
  # than guessed.
  local update_flag=""
  grep -q -- "--auto-update-on-conflict" /tmp/agentcore-help.log 2>/dev/null \
    && update_flag="--auto-update-on-conflict"
  [[ -z "$update_flag" ]] && \
    ( cd "$PROJECT_DIR" && agentcore "$deploy_cmd" --help ) 2>&1 \
      | grep -q -- "--auto-update-on-conflict" && update_flag="--auto-update-on-conflict"

  # The variable goes on agentcore, not on yes — a prefix assignment applies
  # to the command it precedes, and that is the left side of the pipe.
  ( cd "$PROJECT_DIR" && source .env \
      && yes '' | AGENTCORE_SUPPRESS_RECOMMENDATION=1 \
         agentcore "$deploy_cmd" $update_flag \
      >/tmp/deploy.log 2>&1 ) || true

  # If it conflicted anyway, retry once with the flag the error names.
  if grep -q "ConflictException" /tmp/deploy.log && [[ -z "$update_flag" ]]; then
    warn "agent already exists — retrying with --auto-update-on-conflict"
    ( cd "$PROJECT_DIR" && source .env \
        && yes '' | AGENTCORE_SUPPRESS_RECOMMENDATION=1 \
           agentcore "$deploy_cmd" --auto-update-on-conflict \
        >/tmp/deploy.log 2>&1 ) || true
  fi

  printf '%s·%s\n' "$DIM" "$RESET"

  # Verified by probing the agent, not by grepping the deploy log.
  #
  # The previous version matched /READY/i, which matches inside the word
  # "already" — so a log saying the agent was already configured was read as a
  # successful deployment, and the run reported "Agent deploy OK" while every
  # subsequent invoke returned "Agent not deployed". A false success is worse
  # than a failure: it sent seven test transcripts out looking like the model
  # had misbehaved.
  local probe
  probe="$( cd "$PROJECT_DIR" && source .env \
    && AGENTCORE_SUPPRESS_RECOMMENDATION=1 agentcore invoke \
       '{"prompt":"ping","customer_id":"CUST-000","session_id":"probe"}' 2>&1 )"
  printf '%s' "$probe" > /tmp/probe.log

  # Failure list widened after v13 called this green on a response that read
  # "Invocation failed: ... An error occurred when starting the runtime". The
  # runtime existed and the CLI knew its ARN, so none of the earlier patterns
  # matched — but the container was crash-looping, and seven transcripts went
  # out labelled as test failures.
  if grep -qiE 'not deployed|information unavailable|no such|not found|invocation failed|error occurred|exception|traceback' <<<"$probe"; then
    bad "the agent is not answering after $deploy_cmd:"
    grep -viE '^\s*[│╭╰]' <<<"$probe" | grep -viE '^\s*$' | head -8 | sed 's/^/       /'
    tail_runtime_logs
    printf '\n       %sLast lines of the %s log:%s\n' "$BOLD" "$deploy_cmd" "$RESET"
    tail -20 /tmp/deploy.log | sed 's/^/       /'
    record "Agent deploy" "FAILED" "runtime not starting — see CloudWatch"
    return 1
  fi

  ok "agent is answering invokes"
  save agent_deployed 1
  save deploy_cmd "$deploy_cmd"
  record "Agent deploy" "OK" "$AGENT_NAME"
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

    out="$( cd "$PROJECT_DIR" && source .env && AGENTCORE_SUPPRESS_RECOMMENDATION=1 agentcore invoke "$payload" 2>&1 )"

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

    # An undeployed agent is not a failed scenario, and labelling it one is
    # how seven transcripts ended up looking like model misbehaviour.
    if grep -qiE 'not deployed|information unavailable' <<<"$out"; then
      printf 'RESULT: [ERROR] the agent is not deployed — this is not a test result
'         >> "$EVIDENCE_DIR/${id}.txt"
      bad "$id — agent not deployed; stopping"
      record "Six scenarios" "FAILED" "agent not deployed"
      return 1
    fi

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
# Bundle everything the submission needs into one file.
#
# CloudShell downloads one path at a time, so a single archive beats fetching
# seven transcripts by hand.
package_submission() {
  phase "Packaging the submission"

  local out="${HOME}/cs-agent-submission.zip"
  local staging="/tmp/cs-agent-submission"

  rm -rf "$staging" "$out"
  mkdir -p "$staging/evidence-live"

  cp "$PROJECT_DIR/main.py" "$staging/" 2>/dev/null
  cp -r "$PROJECT_DIR/lambda" "$staging/" 2>/dev/null
  cp "$PROJECT_DIR/product_catalog.txt" "$staging/" 2>/dev/null
  cp "$EVIDENCE_DIR"/*.txt "$staging/evidence-live/" 2>/dev/null

  # The resource IDs, so a reviewer can see what was actually deployed.
  {
    printf 'Deployed resources — account %s, %s\n\n' "$(load account)" "$REGION"
    printf '  REST API        %s\n' "$(load api_url)"
    printf '  Knowledge Base  %s\n' "$(load kb_id)"
    printf '  Memory          %s\n' "$(load memory_id)"
    printf '  Gateway         %s\n' "$(load gateway_url)"
    printf '  Collection      %s\n' "$(load collection_arn)"
    printf '  S3 bucket       %s\n' "$(load bucket)"
    printf '\nGenerated %s by deploy-e2e %s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SCRIPT_VERSION"
  } > "$staging/DEPLOYED_RESOURCES.txt"

  ( cd "$staging" && zip -qr "$out" . )

  local n
  n="$(ls "$EVIDENCE_DIR"/*.txt 2>/dev/null | wc -l)"
  if [[ "$n" -eq 0 ]]; then
    warn "no test transcripts yet — the agent has not been deployed and run"
    warn "this archive has main.py and the Lambdas, but nothing to submit as"
    warn "test output. Get phase 11 green, then re-run with --package."
  fi
  ok "$out ($(du -h "$out" | cut -f1))"
  printf '\n   %sDownload it:%s CloudShell → Actions → Download file → paste:\n' "$BOLD" "$RESET"
  printf '     %s\n\n' "$out"
  printf '   Transcripts included: %s\n' \
    "$(ls "$EVIDENCE_DIR"/*.txt 2>/dev/null | wc -l)"
}

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
  for key in account caller_arn lambda_role_arn kb_role_arn gw_role_arn indexer_user_arn \
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
  delete_indexer_key
  aws iam delete-user-policy --user-name "${PREFIX}-indexer" --policy-name aoss-index >/dev/null 2>&1
  aws iam delete-user --user-name "${PREFIX}-indexer" >/dev/null 2>&1 \
    && ok "${PREFIX}-indexer user deleted"
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
    --test-only) preflight; materialise; install_agentcore_cli && run_tests; summary; exit 0 ;;
    --package)   package_submission; exit 0 ;;
  esac

  printf '%s\n' "${BOLD}Customer Support Agent — end-to-end deploy ${SCRIPT_VERSION}${RESET}"
  printf '%s\n' "${DIM}running: $0${RESET}"
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
  package_submission
  summary
}

main "$@"
