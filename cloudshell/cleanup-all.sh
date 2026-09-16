#!/usr/bin/env bash
#
#  Remove every resource these nanodegree projects created.
#  ────────────────────────────────────────────────────────
#
#     bash cleanup-all.sh          list what WOULD be deleted, delete nothing
#     bash cleanup-all.sh --yes    actually delete it
#
#  Dry run is the default on purpose. Read the list, then re-run with --yes.
#
#  ─────────────────────────────────────────────────────────────────────
#  PROTECTED — never touched, in any mode
#
#    S3 bucket   saudispace            (unrelated project, eu-north-1)
#    IAM users   saudispace-uploader
#                covert-channel-substrate
#                covert-channel-operator
#
#  Anything whose name is in the KEEP lists below is skipped and reported as
#  protected. Add to those lists before running if you are unsure — this
#  script cannot undo itself, and an S3 bucket deleted by accident is gone.
#  ─────────────────────────────────────────────────────────────────────
#
#  It covers more than deploy-e2e --teardown does: that one only removes what
#  it created itself, and leaves the ECR repository, the CodeBuild project and
#  the execution roles the AgentCore starter toolkit made, plus everything
#  from project 1.

set -uo pipefail

REGION="${AWS_REGION:-us-east-1}"
APPLY=0
[[ "${1:-}" == "--yes" ]] && APPLY=1

# ── Protected ────────────────────────────────────────────────────────────────
KEEP_BUCKETS=(
  "saudispace"
)
KEEP_USERS=(
  "saudispace-uploader"
  "covert-channel-substrate"
  "covert-channel-operator"
)

# ── Targets ──────────────────────────────────────────────────────────────────
# Named explicitly. No wildcards over "everything in the account" — a prefix
# match that catches one unexpected resource is how accidents happen.
LAMBDAS=(
  "order-tracker"
  "refund-processor"
  "bug-report-tool-stack-create-bug-report"
)
IAM_ROLES=(
  "cs-agent-lambda-role"
  "cs-agent-kb-role"
  "cs-agent-gateway-role"
)
IAM_USERS=(
  "cs-agent-indexer"
  "evidence-capture"
)
CFN_STACKS=(
  "bug-report-tool-stack"
  "bug-report-testing-stack"
)

BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'
RED=$'\033[31m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'; RESET=$'\033[0m'

step() { printf '\n%s━━ %s%s\n' "$CYAN$BOLD" "$*" "$RESET"; }
kill_() { printf '  %s✗%s %s\n' "$RED" "$RESET" "$*"; }
keep() { printf '  %s🔒 KEEP%s %s\n' "$GREEN" "$RESET" "$*"; }
none() { printf '  %s·%s %s\n' "$DIM" "$RESET" "${DIM}$*${RESET}"; }

protected_bucket() {
  local b
  for b in "${KEEP_BUCKETS[@]}"; do [[ "$1" == "$b" ]] && return 0; done
  return 1
}
protected_user() {
  local u
  for u in "${KEEP_USERS[@]}"; do [[ "$1" == "$u" ]] && return 0; done
  return 1
}

# run <description> <command...>
run() {
  local what="$1"; shift
  if [[ "$APPLY" -eq 1 ]]; then
    if "$@" >/dev/null 2>&1; then kill_ "deleted $what"; else none "$what (already gone)"; fi
  else
    kill_ "would delete $what"
  fi
}

command -v aws >/dev/null || { echo "aws CLI not found — run this in CloudShell."; exit 1; }
ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" \
  || { echo "no AWS credentials"; exit 1; }

printf '%sCleanup — account %s, region %s%s\n' "$BOLD" "$ACCOUNT" "$REGION" "$RESET"
if [[ "$APPLY" -eq 1 ]]; then
  printf '%sAPPLY MODE — this will delete resources.%s\n' "$RED$BOLD" "$RESET"
else
  printf '%sDRY RUN — nothing will be deleted. Re-run with --yes to apply.%s\n' \
    "$YELLOW" "$RESET"
fi

# ── 1. AgentCore runtime ─────────────────────────────────────────────────────
step "AgentCore runtimes"
for id in $(aws bedrock-agentcore-control list-agent-runtimes --region "$REGION" \
              --query 'agentRuntimes[].agentRuntimeId' --output text 2>/dev/null); do
  run "agent runtime $id" aws bedrock-agentcore-control delete-agent-runtime \
    --agent-runtime-id "$id" --region "$REGION"
done

step "AgentCore gateways"
for id in $(aws bedrock-agentcore-control list-gateways --region "$REGION" \
              --query 'items[].gatewayId' --output text 2>/dev/null); do
  for t in $(aws bedrock-agentcore-control list-gateway-targets \
               --gateway-identifier "$id" --region "$REGION" \
               --query 'items[].targetId' --output text 2>/dev/null); do
    run "gateway target $t" aws bedrock-agentcore-control delete-gateway-target \
      --gateway-identifier "$id" --target-id "$t" --region "$REGION"
  done
  run "gateway $id" aws bedrock-agentcore-control delete-gateway \
    --gateway-identifier "$id" --region "$REGION"
done

step "AgentCore memories"
for id in $(aws bedrock-agentcore-control list-memories --region "$REGION" \
              --query 'memories[].id' --output text 2>/dev/null); do
  run "memory $id" aws bedrock-agentcore-control delete-memory \
    --memory-id "$id" --region "$REGION"
done

# ── 2. Knowledge Bases and the vector store ──────────────────────────────────
step "Bedrock Knowledge Bases"
for kb in $(aws bedrock-agent list-knowledge-bases --region "$REGION" \
              --query 'knowledgeBaseSummaries[].knowledgeBaseId' --output text 2>/dev/null); do
  run "knowledge base $kb" aws bedrock-agent delete-knowledge-base \
    --knowledge-base-id "$kb" --region "$REGION"
done

step "OpenSearch Serverless  ${YELLOW}(this is the one that bills hourly)${RESET}"
for c in $(aws opensearchserverless list-collections --region "$REGION" \
             --query 'collectionSummaries[].id' --output text 2>/dev/null); do
  run "collection $c" aws opensearchserverless delete-collection --id "$c" --region "$REGION"
done
for p in $(aws opensearchserverless list-security-policies --type encryption \
             --region "$REGION" --query 'securityPolicySummaries[].name' --output text 2>/dev/null); do
  run "encryption policy $p" aws opensearchserverless delete-security-policy \
    --name "$p" --type encryption --region "$REGION"
done
for p in $(aws opensearchserverless list-security-policies --type network \
             --region "$REGION" --query 'securityPolicySummaries[].name' --output text 2>/dev/null); do
  run "network policy $p" aws opensearchserverless delete-security-policy \
    --name "$p" --type network --region "$REGION"
done
for p in $(aws opensearchserverless list-access-policies --type data \
             --region "$REGION" --query 'accessPolicySummaries[].name' --output text 2>/dev/null); do
  run "data access policy $p" aws opensearchserverless delete-access-policy \
    --name "$p" --type data --region "$REGION"
done

# ── 3. Compute ───────────────────────────────────────────────────────────────
step "Lambda functions"
for fn in "${LAMBDAS[@]}"; do
  if aws lambda get-function --function-name "$fn" --region "$REGION" >/dev/null 2>&1; then
    run "lambda $fn" aws lambda delete-function --function-name "$fn" --region "$REGION"
  else
    none "lambda $fn (not present)"
  fi
done

step "API Gateway REST APIs"
for api in $(aws apigateway get-rest-apis --region "$REGION" \
               --query "items[?contains(name,'cs-agent')].id" --output text 2>/dev/null); do
  run "rest api $api" aws apigateway delete-rest-api --rest-api-id "$api" --region "$REGION"
done

step "ECR repositories and CodeBuild projects (made by the AgentCore toolkit)"
for repo in $(aws ecr describe-repositories --region "$REGION" \
                --query "repositories[?contains(repositoryName,'bedrock-agentcore')].repositoryName" \
                --output text 2>/dev/null); do
  run "ecr repo $repo" aws ecr delete-repository --repository-name "$repo" \
    --force --region "$REGION"
done
for proj in $(aws codebuild list-projects --region "$REGION" \
                --query "projects[?contains(@,'bedrock-agentcore')]" --output text 2>/dev/null); do
  run "codebuild project $proj" aws codebuild delete-project --name "$proj" --region "$REGION"
done

# ── 4. Storage ───────────────────────────────────────────────────────────────
step "S3 buckets  ${GREEN}(protected buckets are skipped)${RESET}"
for b in $(aws s3api list-buckets --query 'Buckets[].Name' --output text 2>/dev/null); do
  if protected_bucket "$b"; then
    keep "s3://$b"
    continue
  fi
  case "$b" in
    cs-agent-kb-*|*bug-report*|*bedrock-agentcore*|*support-chatbot*)
      if [[ "$APPLY" -eq 1 ]]; then
        aws s3 rm "s3://$b" --recursive >/dev/null 2>&1
        run "s3://$b" aws s3api delete-bucket --bucket "$b"
      else
        kill_ "would empty and delete s3://$b"
      fi
      ;;
    *)
      keep "s3://$b  ${DIM}(no rule matches it — left alone)${RESET}" ;;
  esac
done

# ── 5. CloudFormation (project 1) ────────────────────────────────────────────
step "CloudFormation stacks"
for stack in "${CFN_STACKS[@]}"; do
  if aws cloudformation describe-stacks --stack-name "$stack" --region "$REGION" \
       >/dev/null 2>&1; then
    run "stack $stack" aws cloudformation delete-stack --stack-name "$stack" --region "$REGION"
  else
    none "stack $stack (not present)"
  fi
done

# ── 6. IAM ───────────────────────────────────────────────────────────────────
step "IAM roles"
for role in "${IAM_ROLES[@]}"; do
  if aws iam get-role --role-name "$role" >/dev/null 2>&1; then
    if [[ "$APPLY" -eq 1 ]]; then
      for p in $(aws iam list-role-policies --role-name "$role" \
                   --query 'PolicyNames[]' --output text 2>/dev/null); do
        aws iam delete-role-policy --role-name "$role" --policy-name "$p" >/dev/null 2>&1
      done
      for a in $(aws iam list-attached-role-policies --role-name "$role" \
                   --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
        aws iam detach-role-policy --role-name "$role" --policy-arn "$a" >/dev/null 2>&1
      done
    fi
    run "role $role" aws iam delete-role --role-name "$role"
  else
    none "role $role (not present)"
  fi
done

for role in $(aws iam list-roles \
                --query "Roles[?starts_with(RoleName,'AmazonBedrockAgentCoreSDK')].RoleName" \
                --output text 2>/dev/null); do
  if [[ "$APPLY" -eq 1 ]]; then
    for p in $(aws iam list-role-policies --role-name "$role" \
                 --query 'PolicyNames[]' --output text 2>/dev/null); do
      aws iam delete-role-policy --role-name "$role" --policy-name "$p" >/dev/null 2>&1
    done
    for a in $(aws iam list-attached-role-policies --role-name "$role" \
                 --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
      aws iam detach-role-policy --role-name "$role" --policy-arn "$a" >/dev/null 2>&1
    done
  fi
  run "role $role" aws iam delete-role --role-name "$role"
done

step "IAM users  ${GREEN}(protected users are skipped)${RESET}"
for user in "${IAM_USERS[@]}"; do
  if protected_user "$user"; then keep "user $user"; continue; fi
  if aws iam get-user --user-name "$user" >/dev/null 2>&1; then
    if [[ "$APPLY" -eq 1 ]]; then
      for k in $(aws iam list-access-keys --user-name "$user" \
                   --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null); do
        aws iam delete-access-key --user-name "$user" --access-key-id "$k" >/dev/null 2>&1
      done
      for p in $(aws iam list-user-policies --user-name "$user" \
                   --query 'PolicyNames[]' --output text 2>/dev/null); do
        aws iam delete-user-policy --user-name "$user" --policy-name "$p" >/dev/null 2>&1
      done
      for a in $(aws iam list-attached-user-policies --user-name "$user" \
                   --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
        aws iam detach-user-policy --user-name "$user" --policy-arn "$a" >/dev/null 2>&1
      done
    fi
    run "user $user" aws iam delete-user --user-name "$user"
  else
    none "user $user (not present)"
  fi
done

printf '\n%sProtected throughout:%s\n' "$GREEN$BOLD" "$RESET"
for b in "${KEEP_BUCKETS[@]}"; do printf '  s3://%s\n' "$b"; done
for u in "${KEEP_USERS[@]}"; do printf '  iam user %s\n' "$u"; done

if [[ "$APPLY" -eq 0 ]]; then
  cat <<EOF

${YELLOW}${BOLD}Nothing was deleted.${RESET}
Read the list above. If it is right:

  bash cleanup-all.sh --yes

EOF
else
  cat <<EOF

${BOLD}Done.${RESET} Check the console for anything left, especially:
  · OpenSearch Serverless collections — the only resource that bills while idle
  · CloudWatch log groups (they cost almost nothing but linger)
  · Any region other than ${REGION}

EOF
fi
