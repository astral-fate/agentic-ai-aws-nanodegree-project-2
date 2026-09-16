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
#
#  KEEP_MEMORY=1 skips the memory reset before the scenarios.
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
SCRIPT_VERSION="v17"

REGION="${AWS_REGION:-us-east-1}"
PREFIX="${PREFIX:-cs-agent}"
AGENT_NAME="${AGENT_NAME:-customer_support_agent}"
# Extraction is an asynchronous LLM job. The project instructions say
# "at least 30 seconds"; 45 was not enough in practice.
MEMORY_WAIT="${MEMORY_WAIT:-120}"

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

  cat > "$PROJECT_DIR/main.py" <<'MAIN_PY_EOF'
"""
Customer Support AI Agent — Amazon Bedrock AgentCore + Strands
===============================================================
A multi-capability customer support agent for an e-commerce platform.

Five capabilities, five different AgentCore primitives:

  Gateway (MCP)      order tracking + refund processing, via Lambda targets
  Knowledge Base     grounded answers about products, policies and loyalty tiers
  Memory             customer facts and preferences, recalled across sessions
  Code Interpreter   exact loyalty-discount arithmetic in a sandbox
  Browser            live web pages

Run locally (after filling in the config values below):
  uv run main.py '{"prompt": "Hello", "customer_id": "CUST-123", "session_id": "s1"}'

Deploy to AgentCore:
  agentcore configure --entrypoint main.py --name customer_support_agent
  agentcore deploy

Invoke the deployed agent:
  agentcore invoke '{"prompt": "Hello", "customer_id": "CUST-123", "session_id": "s1"}'
"""

# ── Imports ───────────────────────────────────────────────────────────────────
# These imports are provided. Do not remove them.
from strands import Agent, tool
from bedrock_agentcore.runtime import BedrockAgentCoreApp
from bedrock_agentcore.memory import MemoryClient
from strands.models import BedrockModel
from strands.tools.mcp.mcp_client import MCPClient
from mcp.client.streamable_http import streamable_http_client
import argparse, json
import os, asyncio, boto3
from strands.hooks import (
    HookProvider, AfterInvocationEvent, HookRegistry, MessageAddedEvent,
)
import logging
import sys
import uuid
from typing import Dict
from bedrock_agentcore.tools.code_interpreter_client import code_session
from strands_tools.browser import AgentCoreBrowser


logging.basicConfig(level=logging.WARNING)
logger = logging.getLogger("CSAI_Agent")

# ── TODO 1 — App Initialisation ───────────────────────────────────────────────
# One BedrockAgentCoreApp per deployment. Created at module level so the
# AgentCore runtime can find the ASGI app when the container starts — the
# @app.entrypoint decorator below needs it to exist at import time.
app = BedrockAgentCoreApp()


# Suppress interactive tool-consent prompts (required in headless deployments).
os.environ["BYPASS_TOOL_CONSENT"] = "true"


# ── TODO 2 — Configuration ────────────────────────────────────────────────────
# The four values collected during infrastructure setup (Part 1).
#
# Each one reads an environment variable first and falls back to the literal
# below. That keeps the deployed container and the local CLI reading the same
# code path, and it keeps account-specific IDs out of the source history —
# set them in .env (git-ignored) or in the AgentCore runtime environment.
#
#   GATEWAY_URL  https://<alias>.gateway.bedrock-agentcore.<region>.amazonaws.com/mcp
#   KB_ID        10-character alphanumeric ID from the Knowledge Base console
#   REGION       the AWS region — the course pins us-east-1
#   MEMORY_ID    shown in the AgentCore Memory console

GATEWAY_URL = os.environ.get(
    "GATEWAY_URL",
    "https://customersupportgateway-abc123defg.gateway.bedrock-agentcore.us-east-1.amazonaws.com/mcp",
)
KB_ID = os.environ.get("KB_ID", "ABCDEFGHIJ")
REGION = os.environ.get("REGION", "us-east-1")
MEMORY_ID = os.environ.get("MEMORY_ID", "CustomerSupportMemory-abc123defg")


# ── TODO 3 — Model and Clients ────────────────────────────────────────────────
# Nova 2 Lite is the model the project pins: cheap enough to run the six test
# scenarios repeatedly, and it handles multi-tool routing reliably.

model_id = "global.amazon.nova-2-lite-v1:0"

model = BedrockModel(model_id=model_id)

memory_client = MemoryClient(region_name=REGION)

# The Retrieve API lives on bedrock-agent-runtime, not on the bedrock client.
_bedrock_runtime = boto3.client("bedrock-agent-runtime", region_name=REGION)


# ── TODO 4 — Namespace Helper ─────────────────────────────────────────────────

def get_namespaces(mem_client: MemoryClient, memory_id: str) -> Dict:
    """
    Return a dict mapping strategy type → namespace template string.

    Example:
      { "SEMANTIC":        "cs_agent/{actorId}/facts",
        "USER_PREFERENCE": "cs_agent/{actorId}/preferences" }

    The namespace template is read from ``namespaceTemplates`` when present and
    falls back to the legacy ``namespaces`` field, because the two AgentCore
    Memory API versions disagree on the key name and a resource created in the
    console may report either one.
    """
    strategies = mem_client.get_memory_strategies(memory_id) or []

    namespaces = {}
    for strategy in strategies:
        strategy_type = strategy.get("type")
        templates = strategy.get("namespaceTemplates") or strategy.get("namespaces") or []
        if strategy_type and templates:
            namespaces[strategy_type] = templates[0]

    return namespaces


# ── TODO 5 — Memory Hook ──────────────────────────────────────────────────────

class MemoryHook(HookProvider):
    """
    Long-term memory for the customer support agent.

    Two callbacks bracket every turn:

      MessageAddedEvent     before the model runs — look up what we already
                            know about this customer and prepend it to the
                            message the model is about to read
      AfterInvocationEvent  after the model answers — hand the turn to
                            AgentCore Memory so the extraction strategies can
                            mine it for facts and preferences

    Memory is keyed on ``actor_id`` (the customer), not on ``session_id``, which
    is what makes recall work across two separate sessions.
    """

    def __init__(
        self,
        actor_id: str,
        session_id: str,
        memory_client: MemoryClient,
        memory_id: str,
    ):
        self.actor_id = actor_id
        self.session_id = session_id
        self.memory_id = memory_id
        self.memory_client = memory_client
        self.namespaces = get_namespaces(memory_client, memory_id)

    # ── retrieval ────────────────────────────────────────────────────────────
    def retrieve_customer_context(self, event: MessageAddedEvent):
        """Retrieve relevant memories and prepend them to the user message."""
        messages = event.agent.messages
        if not messages:
            return

        last = messages[-1]

        # Only plain-text user turns. Tool results also arrive as role "user",
        # so without the toolResult guard every tool response would trigger a
        # second retrieval and the context block would be injected repeatedly.
        if last.get("role") != "user":
            return
        content = last.get("content") or []
        if not content or "text" not in content[0]:
            return
        if "toolResult" in content[0]:
            return

        user_query = content[0]["text"]

        try:
            all_context = []

            for strategy_type, namespace_template in self.namespaces.items():
                namespace = namespace_template.replace("{actorId}", self.actor_id)

                memories = self.memory_client.retrieve_memories(
                    memory_id=self.memory_id,
                    namespace=namespace,
                    query=user_query,
                    top_k=5,
                )

                for memory in memories or []:
                    if not isinstance(memory, dict):
                        continue
                    text = (memory.get("content") or {}).get("text", "")
                    if text:
                        # Tagging by strategy type tells the model whether it is
                        # reading a fact ("her name is Jane") or a preference
                        # ("she wants short answers") — they are acted on
                        # differently.
                        all_context.append(f"[{strategy_type.upper()}] {text}")

            if all_context:
                context_block = "\n".join(f"- {c}" for c in all_context)
                content[0]["text"] = (
                    f"Customer Context:\n{context_block}\n\n{user_query}"
                )
                logger.info(
                    "Injected %d memories for actor %s", len(all_context), self.actor_id
                )

        except Exception as exc:
            # A memory lookup failure must not take down the turn — the agent
            # can still answer, just without recall.
            logger.error("Memory retrieval failed: %s", exc)

    # ── persistence ──────────────────────────────────────────────────────────
    def save_support_interaction(self, event: AfterInvocationEvent):
        """Save the completed turn to memory after the agent responds."""
        try:
            messages = event.agent.messages
            if not messages:
                return

            agent_response = None
            customer_query = None

            # Walk backwards: the last assistant message is the answer, and the
            # last plain-text user message before it is the question. Anything
            # in between is tool traffic, which memory should not store.
            for message in reversed(messages):
                content = message.get("content") or []
                if not content or "text" not in content[0]:
                    continue

                if message.get("role") == "assistant" and agent_response is None:
                    agent_response = content[0]["text"]
                elif (
                    message.get("role") == "user"
                    and "toolResult" not in content[0]
                    and customer_query is None
                ):
                    customer_query = content[0]["text"]

                if agent_response and customer_query:
                    break

            if customer_query and agent_response:
                self.memory_client.create_event(
                    memory_id=self.memory_id,
                    actor_id=self.actor_id,
                    session_id=self.session_id,
                    messages=[
                        (customer_query, "USER"),
                        (agent_response, "ASSISTANT"),
                    ],
                )
                logger.info("Saved interaction for actor %s", self.actor_id)

        except Exception as exc:
            logger.error("Memory save failed: %s", exc)

    # ── registration ─────────────────────────────────────────────────────────
    def register_hooks(self, registry: HookRegistry) -> None:  # type: ignore
        """Register both memory callbacks."""
        registry.add_callback(MessageAddedEvent, self.retrieve_customer_context)
        registry.add_callback(AfterInvocationEvent, self.save_support_interaction)


# ── TODO 6 — Knowledge Base Tool ─────────────────────────────────────────────

@tool
def search_knowledge_base(query: str) -> str:
    """
    Search the Amazon product catalog and support knowledge base.
    Use this for product specifications, return policies, warranty
    information, loyalty program details, and order status definitions.

    Args:
        query: The question or topic to search for

    Returns:
        Relevant information retrieved from the knowledge base
    """
    # Guard clause: a missing KB_ID is a configuration problem, and saying so
    # is far more useful to the model (and to whoever is reading the logs) than
    # a boto3 ValidationException.
    if not KB_ID or KB_ID.startswith("<"):
        return (
            "Knowledge base not configured. Set KB_ID to your Bedrock "
            "Knowledge Base ID to enable catalog and policy lookups."
        )

    try:
        resp = _bedrock_runtime.retrieve(
            knowledgeBaseId=KB_ID,
            retrievalQuery={"text": query},
        )
    except Exception as exc:
        logger.error("Knowledge base retrieve failed: %s", exc)
        return f"Knowledge base search failed: {exc}"

    results = resp.get("retrievalResults", [])
    if not results:
        return f"No information found in the knowledge base for: {query}"

    chunks = [r.get("content", {}).get("text", "") for r in results]
    return "\n---\n".join(c for c in chunks if c)


# ── TODO 7 — Loyalty Discount Tool (Code Interpreter) ────────────────────────

@tool
def calculate_loyalty_discount(
    loyalty_points: int,
    tier: str,
    order_total: float,
    product_category: str = "standard",
) -> str:
    """
    Calculate the loyalty discount for a customer order using the
    AgentCore Code Interpreter. Runs exact arithmetic in a secure sandbox.

    Args:
        loyalty_points:   Customer's current points balance
        tier:             Customer tier — Silver, Gold, or Platinum
        order_total:      Order total in USD
        product_category: standard, device, or fresh

    Returns:
        Full discount breakdown and final price
    """
    # The business rules are written into the code string rather than executed
    # here on purpose. Money arithmetic done by a language model is arithmetic
    # you cannot audit; this way the exact program that produced the number is
    # visible in the trace, and the sandbox — not the model — computes it.
    code = f"""
import json, math

loyalty_points   = {int(loyalty_points)}
tier             = {json.dumps(str(tier).strip().title())}
order_total      = {float(order_total)}
product_category = {json.dumps(str(product_category).strip().lower())}

# Points earned per $1 spent, by product category.
earn_rates = {{"standard": 1, "device": 2, "fresh": 5}}

# Tier discount applied to the subtotal AFTER points are redeemed.
tier_rates = {{"Silver": 0.00, "Gold": 0.10, "Platinum": 0.15}}

POINTS_PER_DOLLAR   = 100   # 100 points == $1
MIN_REDEMPTION      = 500   # nothing redeems below 500 points
MAX_POINTS_SHARE    = 0.50  # points may not cover more than half the order

# ── Points redemption ────────────────────────────────────────────────────
# Cap the redeemable value at half the order, then floor to the nearest 500
# because points only redeem in 500-point blocks.
max_points_by_value = int(order_total * MAX_POINTS_SHARE * POINTS_PER_DOLLAR)
usable_points       = min(loyalty_points, max_points_by_value)
points_redeemed     = (usable_points // MIN_REDEMPTION) * MIN_REDEMPTION
if points_redeemed < MIN_REDEMPTION:
    points_redeemed = 0
points_value = round(points_redeemed / POINTS_PER_DOLLAR, 2)

# ── Tier discount ────────────────────────────────────────────────────────
tier_rate     = tier_rates.get(tier, 0.00)
subtotal      = round(order_total - points_value, 2)
tier_discount = round(subtotal * tier_rate, 2)

# ── Totals ───────────────────────────────────────────────────────────────
final_total   = round(subtotal - tier_discount, 2)
total_savings = round(points_value + tier_discount, 2)

# Points are earned on what the customer actually pays.
earn_rate        = earn_rates.get(product_category, 1)
points_earned    = int(math.floor(final_total * earn_rate))
remaining_points = loyalty_points - points_redeemed + points_earned

print(json.dumps({{
    "tier":              tier,
    "product_category":  product_category,
    "order_total":       round(order_total, 2),
    "points_redeemed":   points_redeemed,
    "points_value":      points_value,
    "subtotal":          subtotal,
    "tier_discount_pct": round(tier_rate * 100, 2),
    "tier_discount":     tier_discount,
    "final_total":       final_total,
    "total_savings":     total_savings,
    "points_earned":     points_earned,
    "remaining_points":  remaining_points,
}}, indent=2))
"""

    try:
        with code_session(REGION) as session:
            # clearContext=True gives every calculation a fresh interpreter, so
            # one customer's numbers can never leak into the next one's answer.
            response = session.invoke(
                "executeCode",
                {
                    "code": code,
                    "language": "python",
                    "clearContext": True,
                },
            )

            for event in response["stream"]:
                return json.dumps(event["result"])

        raise RuntimeError("Code interpreter returned no result events")

    except Exception as exc:
        # Fallback: tier discount only, clearly labelled. Returning the same
        # field names keeps the model's answer well-formed even when the
        # sandbox is unavailable — it just cannot redeem points.
        logger.error("Code interpreter unavailable, using fallback: %s", exc)

        tier_rate = {"Silver": 0.00, "Gold": 0.10, "Platinum": 0.15}.get(
            str(tier).strip().title(), 0.00
        )
        tier_discount = round(float(order_total) * tier_rate, 2)
        final_total = round(float(order_total) - tier_discount, 2)

        return json.dumps(
            {
                "tier": str(tier).strip().title(),
                "order_total": round(float(order_total), 2),
                "points_redeemed": 0,
                "points_value": 0.0,
                "tier_discount_pct": round(tier_rate * 100, 2),
                "tier_discount": tier_discount,
                "final_total": final_total,
                "total_savings": tier_discount,
                "points_earned": 0,
                "remaining_points": int(loyalty_points),
                "fallback": True,
                "note": (
                    "Code Interpreter unavailable — tier discount only, "
                    "points were not redeemed."
                ),
            },
            indent=2,
        )


# ── System prompt ─────────────────────────────────────────────────────────────
# Kept next to the tools it talks about, so the two stay in sync.

SYSTEM_PROMPT = """You are a customer support assistant for an e-commerce platform.

You have these tools. Choose deliberately — each one exists for a different
kind of question:

- Gateway order tools (get_order, get_customer_orders, get_customer):
  live order status, tracking numbers, carriers, delivery dates, and customer
  profiles. Use these for anything about a specific order or customer.
- Gateway refund tools (initiate_refund, check_refund_status, get_return_label):
  starting a refund, checking one already in flight, or issuing a return label.
- search_knowledge_base: product specifications, return and refund policy,
  warranty terms, loyalty tier benefits, and order status definitions. Use it
  for any policy or product question. Do not answer these from memory — the
  catalog is the source of truth and it changes.
- calculate_loyalty_discount: any question involving points, tiers or a final
  price. Never do this arithmetic yourself; the sandbox is exact and you are
  not.
- browser: live web pages, when the customer gives you a URL or asks about
  something outside the catalog.

Hard rules. These are not stylistic preferences — breaking one produces a
wrong answer that looks right, which is the worst thing this agent can do.

1. You have NO knowledge of order data. None at all. If the customer mentions
   an order, you MUST call get_order before saying anything about it. Never
   state a status, tracking number, carrier or delivery date that did not come
   back from a tool call in this conversation. "Being processed" and "2-3
   business days" are not safe defaults; they are fabrications.

2. Before calling initiate_refund you MUST call get_order for that order and
   pass its `total` as the refund amount. A refund issued for 0, or with the
   amount omitted, is a defect — not an acceptable answer.

3. Policy, warranty, tier and product questions go to search_knowledge_base.
   Do not answer them from your own knowledge: the catalog is the source of
   truth and it changes.

4. Any question involving points, tiers or a final price goes to
   calculate_loyalty_discount. Never do the arithmetic yourself.

5. If a message begins with "Customer Context:", that is what you already know
   about this customer from earlier sessions. Use it — greet them by name,
   honour a stated preference. Never tell a customer you cannot remember
   things when that block is present.

6. Report tool results faithfully. Quote tracking numbers, refund IDs and
   totals exactly as returned; never round or paraphrase a figure.

7. If a tool fails, say plainly what you could not retrieve. Never substitute
   a plausible-looking value for a missing one.

Be warm and concise. One clear paragraph beats five bullet points.
"""


# ── TODO 8 — Agent Entrypoint ─────────────────────────────────────────────────

@app.entrypoint
async def invoke(payload, context=None):
    """
    Main handler called by AgentCore for every incoming request.

    Expected payload keys:
      prompt      (str, required) — the customer's message
      customer_id (str, optional) — unique customer identifier
      session_id  (str, optional) — session identifier; generated if absent
    """
    user_input = payload.get("prompt", "")
    actor_id = payload.get("customer_id", "default_customer")
    # A missing session ID must not collapse separate conversations into one
    # shared history, so generate a fresh one per request.
    session_id = payload.get("session_id") or f"session-{uuid.uuid4()}"

    if not user_input:
        return "No prompt provided."

    try:
        memory_hook = MemoryHook(
            actor_id=actor_id,
            session_id=session_id,
            memory_client=memory_client,
            memory_id=MEMORY_ID,
        )

        agent_core_browser = AgentCoreBrowser(region=REGION)

        tools = [
            search_knowledge_base,
            calculate_loyalty_discount,
            agent_core_browser.browser,
        ]

        # The Gateway speaks MCP over streamable HTTP. Everything that touches
        # gateway tools has to happen inside the `with` block — the tool
        # handles are bound to the client's session and stop working the
        # moment it closes.
        gateway_client = MCPClient(lambda: streamable_http_client(GATEWAY_URL))

        with gateway_client:
            gateway_tools = gateway_client.list_tools_sync()
            tools.extend(gateway_tools)
            logger.info("Loaded %d gateway tools", len(gateway_tools))

            agent = Agent(
                model=model,
                tools=tools,
                hooks=[memory_hook],
                system_prompt=SYSTEM_PROMPT,
            )

            response = await agent.invoke_async(user_input)

        return response.message["content"][0]["text"]

    except Exception as exc:
        logger.exception("Agent invocation failed")
        return f"I hit an error handling that request: {exc}"


# ── CLI entry point (do not modify) ──────────────────────────────────────────
def main():
    """Run one invocation from the command line for local testing."""
    parser = argparse.ArgumentParser()
    parser.add_argument("payload", type=str)
    args = parser.parse_args()
    response = asyncio.run(invoke(json.loads(args.payload)))
    print(response)


if __name__ == "__main__":
    # With a payload argument, run that single invocation locally; with no
    # arguments, start the ASGI server that the AgentCore runtime calls.
    if len(sys.argv) > 1:
        main()
    else:
        app.run()
MAIN_PY_EOF

  cat > "$PROJECT_DIR/lambda/order_tracker.py" <<'ORDER_TRACKER_EOF'
"""
Order Tracking Lambda
======================
Handles order and customer lookup.
Invoked through the AgentCore Gateway (REST API proxy integration).

Routes exposed:
  GET /orders/{order_id}              — return a single order by ID
  GET /customers/{customer_id}/orders — return all orders for a customer
  GET /customers/{customer_id}        — return customer profile

The data is hard-coded for demonstration purposes.  In a real system these
handlers would query a database such as Amazon DynamoDB.

Deployment: zip this file and upload to an AWS Lambda function, then wire
the function to the AgentCore Gateway as a target using API Gateway proxy
integration.
"""
import json
from datetime import datetime, timedelta


# ── Sample data ───────────────────────────────────────────────────────────────
# Returned as a fresh dict on every call so state is never shared across
# Lambda invocations (relevant when the execution environment is reused).

def _orders():
    """Return the mock order database."""
    return {
        "ORD-001": {
            "order_id":          "ORD-001",
            "customer_id":       "CUST-123",
            "status":            "SHIPPED",
            "items":             [{"name": "Wireless Headphones Pro", "qty": 1, "price": 89.99}],
            "total":             89.99,
            "tracking_number":   "TRK987654321",
            "carrier":           "UPS",
            # Delivery expected in 2 days from the time the Lambda runs.
            "estimated_delivery": (datetime.now() + timedelta(days=2)).strftime("%Y-%m-%d"),
        },
        "ORD-002": {
            "order_id":     "ORD-002",
            "customer_id":  "CUST-123",
            "status":       "DELIVERED",
            "items":        [{"name": "Kindle Paperwhite", "qty": 1, "price": 139.99}],
            "total":        139.99,
            "tracking_number": "TRK123456789",
            "carrier":      "USPS",
            # Delivered 3 days ago.
            "delivered_date": (datetime.now() - timedelta(days=3)).strftime("%Y-%m-%d"),
        },
        "ORD-003": {
            "order_id":     "ORD-003",
            "customer_id":  "CUST-456",
            "status":       "PROCESSING",
            "items": [
                {"name": "Echo Dot 5th Gen", "qty": 2, "price": 49.99},
                {"name": "Smart Plug",        "qty": 1, "price": 24.99},
            ],
            "total":              124.97,
            "estimated_delivery": (datetime.now() + timedelta(days=5)).strftime("%Y-%m-%d"),
        },
    }


def _customers():
    """Return the mock customer database."""
    return {
        "CUST-123": {"name": "Jane Smith",  "loyalty_points": 4250, "tier": "Gold"},
        "CUST-456": {"name": "Bob Johnson", "loyalty_points": 890,  "tier": "Silver"},
    }


# ── Response helper ───────────────────────────────────────────────────────────
def _response(status_code: int, body: dict) -> dict:
    """
    Format a Lambda proxy-integration response.

    API Gateway requires a specific shape: statusCode, headers, and a
    JSON-serialised body string.
    """
    return {
        "statusCode": status_code,
        "headers":    {"Content-Type": "application/json"},
        "body":       json.dumps(body),
    }


# ── Handler ───────────────────────────────────────────────────────────────────
def lambda_handler(event, context):
    """
    Main Lambda entry point.

    The API Gateway REST proxy integration populates these event fields:
      resource       — the path template, e.g. /orders/{order_id}
      httpMethod     — GET, POST, etc.
      pathParameters — dict of path variable values, e.g. {"order_id": "ORD-001"}
    """
    print(f"Event: {json.dumps(event)}")

    # Extract routing fields from the proxy integration event.
    resource = event.get("resource", "")        # e.g. "/orders/{order_id}"
    method   = event.get("httpMethod", "GET")
    params   = event.get("pathParameters") or {}

    print(f"Request: {method} {resource} {params}")

    orders    = _orders()
    customers = _customers()

    # ── GET /orders/{order_id} ────────────────────────────────────────────────
    if resource == "/orders/{order_id}" and method == "GET":
        # Normalise to uppercase so "ord-001" and "ORD-001" both work.
        order_id = params.get("order_id", "").upper()
        order    = orders.get(order_id)
        if not order:
            return _response(404, {"error": f"Order {order_id} not found"})
        return _response(200, order)

    # ── GET /customers/{customer_id}/orders ───────────────────────────────────
    if resource == "/customers/{customer_id}/orders" and method == "GET":
        cid    = params.get("customer_id", "").upper()
        # Filter orders to only those belonging to the requested customer.
        result = [o for o in orders.values() if o["customer_id"] == cid]
        if not result:
            return _response(404, {"error": f"No orders found for {cid}"})
        return _response(200, {"customer_id": cid, "orders": result})

    # ── GET /customers/{customer_id} ──────────────────────────────────────────
    if resource == "/customers/{customer_id}" and method == "GET":
        cid      = params.get("customer_id", "").upper()
        customer = customers.get(cid)
        if not customer:
            return _response(404, {"error": f"Customer {cid} not found"})
        return _response(200, customer)

    # ── Unrecognised route ────────────────────────────────────────────────────
    return _response(400, {"error": "Unrecognised route", "resource": resource})
ORDER_TRACKER_EOF

  cat > "$PROJECT_DIR/lambda/refund_processor.py" <<'REFUND_PROCESSOR_EOF'
"""
Refund Processor Lambda
========================
Handles refund-related operations for the customer support agent.
Invoked directly by the AgentCore Gateway (not through API Gateway).

How tool routing works:
  AgentCore Gateway passes the tool name in the Lambda client context under
  the key "bedrockAgentCoreToolName".  The value has the format:
    "TargetName___toolName"
  This handler strips the prefix and branches on the bare tool name.

Tools handled:
  initiate_refund     — create and approve a new refund
  check_refund_status — look up the status of an existing refund
  get_return_label    — generate a prepaid return shipping label

Tool schema is declared in lambda_schema (JSON file in the same directory).
That schema tells the Gateway which arguments to pass for each tool.
"""
import json
import random
import string
from datetime import datetime


# ── Helpers ───────────────────────────────────────────────────────────────────

def _new_refund_id() -> str:
    """
    Generate a unique refund ID of the form REF-XXXXXXXX.

    Uses random ASCII uppercase letters and digits.  In a real system this
    would be a database-generated ID (e.g. a UUID or auto-increment key).
    """
    return "REF-" + "".join(
        random.choices(string.ascii_uppercase + string.digits, k=8)
    )


# ── Handler ───────────────────────────────────────────────────────────────────

def lambda_handler(event, context):
    """
    Main Lambda entry point.

    Args:
        event   — dict of tool arguments passed by the Gateway
        context — Lambda context object; client_context carries the tool name
    """
    # ── Resolve tool name ─────────────────────────────────────────────────────
    raw_tool = ""
    if context.client_context and context.client_context.custom:
        # The Gateway sets bedrockAgentCoreToolName to "TargetName___toolName".
        raw_tool = context.client_context.custom.get("bedrockAgentCoreToolName", "")

    # Strip the target-name prefix to get just the bare tool name.
    # If the separator is absent, use the raw value as-is.
    tool = raw_tool.split("___", 1)[-1] if "___" in raw_tool else raw_tool

    print(f"Tool called: {tool} | Event: {json.dumps(event)}")

    # ── initiate_refund ───────────────────────────────────────────────────────
    if tool == "initiate_refund":
        return {
            "statusCode": 200,
            "body": json.dumps({
                "refund_id":  _new_refund_id(),
                "order_id":   event.get("order_id"),
                "status":     "APPROVED",
                "amount":     event.get("amount", 0),   # default to 0 if not supplied
                "message":    "Refund approved. Credit appears in 3-5 business days.",
                "created_at": datetime.utcnow().isoformat(),
            }),
        }

    # ── check_refund_status ───────────────────────────────────────────────────
    if tool == "check_refund_status":
        # In a real system, this would look up the refund in a database.
        return {
            "statusCode": 200,
            "body": json.dumps({
                "refund_id": event.get("refund_id"),
                "status":    "PROCESSING",
                "eta":       "2-3 business days",
            }),
        }

    # ── get_return_label ──────────────────────────────────────────────────────
    if tool == "get_return_label":
        order_id = event.get("order_id", "")
        return {
            "statusCode": 200,
            "body": json.dumps({
                "order_id":    order_id,
                # Simulated pre-signed return label URL.
                "label_url":   f"https://returns.amazon.com/label/{order_id}",
                "carrier":     "UPS",
                "valid_until": "2025-12-31",
            }),
        }

    # ── Unknown tool ──────────────────────────────────────────────────────────
    return {
        "statusCode": 400,
        "body": json.dumps({"error": f"Unknown tool: {tool}"}),
    }
REFUND_PROCESSOR_EOF

  cat > "$PROJECT_DIR/lambda/lambda_schema" <<'LAMBDA_SCHEMA_EOF'
[
  {
    "name": "initiate_refund",
    "description": "Initiate a refund for a customer order.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "reason": {
          "type": "string",
          "description": "Reason for refund"
        },
        "amount": {
          "type": "number",
          "description": "Refund amount in USD"
        },
        "order_id": {
          "type": "string",
          "description": "Order ID to refund"
        }
      },
      "required": [
        "order_id",
        "reason"
      ]
    }
  },
  {
    "name": "check_refund_status",
    "description": "Check the status of an existing refund.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "refund_id": {
          "type": "string",
          "description": "Refund ID to check"
        }
      },
      "required": [
        "refund_id"
      ]
    }
  },
  {
    "name": "get_return_label",
    "description": "Generate a prepaid return shipping label for an order.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "order_id": {
          "type": "string",
          "description": "Order ID needing a label"
        }
      },
      "required": [
        "order_id"
      ]
    }
  }
]
LAMBDA_SCHEMA_EOF

  cat > "$PROJECT_DIR/product_catalog.txt" <<'CATALOG_EOF'
# Amazon Product Catalog & Support Reference

## Products

### Wireless Headphones Pro (PROD-001)
Price: $89.99
Battery Life: 30 hours
Connectivity: Bluetooth 5.3, USB-C charging
Features: Active Noise Cancellation, Transparency Mode, Foldable design
Compatibility: iOS, Android, Windows, Mac
Warranty: 1-year limited warranty
Return Policy: 30 days unopened, 15 days opened

### Kindle Paperwhite (PROD-002)
Price: $139.99
Storage: 8GB or 32GB
Display: 6.8 inch 300 PPI glare-free
Battery: Up to 10 weeks
Waterproof: IPX8 rated
Connectivity: Wi-Fi and optional Cellular
Warranty: 1 year
Return Policy: 30 days

### Echo Dot 5th Gen (PROD-003)
Price: $49.99
Speaker: 1.73 inch front-firing speaker
Smart Home: Zigbee, Matter, Thread compatible
Features: Alexa built-in, temperature sensor, motion detection
Warranty: 1 year
Return Policy: 30 days

### Amazon Halo Rise (PROD-004)
Price: $139.99
Function: Sleep tracker with sunrise alarm clock
Type: Non-wearable bedside device
Power: Plugs into wall
Includes: Free 6-month Halo membership
Warranty: 1 year

## Return and Refund Policy

### Return Windows
- Standard items: 30 days from delivery date
- Electronics: 15 days from delivery date
- All items must be in original condition with all accessories included
- Free returns for Prime members

### Refund Timeline
- Credit or Debit Card: 3-5 business days
- Amazon Gift Card: 2-3 hours
- Bank Account via ACH: up to 10 business days

### How to Start a Return
1. Go to Your Orders in your Amazon account
2. Select the item you want to return
3. Choose a reason and preferred return method
4. Print the label or show QR code at the drop-off point

## Loyalty Rewards Program

### Tiers
- Silver: 0 to 999 points
- Gold: 1000 to 4999 points
- Platinum: 5000 or more points

### Earning Points
- Standard items: 1 point per $1 spent
- Amazon devices: 2 points per $1 spent
- Amazon Fresh: 5 points per $1 spent

### Redeeming Points
- 100 points equals $1 discount
- Minimum redemption is 500 points
- Points are valid for 2 years from the date earned

### Tier Benefits
- Gold: Free expedited shipping, 10% discount on accessories
- Platinum: Free same-day shipping, 15% discount, priority customer support

## Order Status Definitions
- PROCESSING: Order confirmed and being prepared for shipment
- SHIPPED: Package handed to the carrier
- OUT FOR DELIVERY: Package is with the local delivery agent today
- DELIVERED: Package confirmed as delivered
- CANCELLED: Order cancelled and refund initiated automatically
CATALOG_EOF

  cat > "$PROJECT_DIR/pyproject.toml" <<'PYPROJECT_EOF'
[project]
name = "csai"
version = "0.1.0"
description = "Add your description here"
readme = "README.md"
requires-python = ">=3.14"
dependencies = [
    "asyncio>=4.0.0",
    "bedrock-agentcore>=1.4.1",
    "bedrock-agentcore-starter-toolkit>=0.3.0",
    "chardet>=6.0.0.post1",
    "nest-asyncio>=1.6.0",
    "playwright>=1.58.0",
    "strands-agents>=1.28.0",
    "strands-agents-tools>=0.2.21",
    "urllib3>=2.6.3",
]
PYPROJECT_EOF


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

# Write the real resource IDs into the deployed copy of main.py.
#
# main.py reads each value from the environment and falls back to a placeholder
# literal. Sourcing .env in CloudShell sets those variables for the *build*,
# not inside the container the agent runs in, so the deployed agent fell back
# to the placeholders and asked AgentCore for
# memory/CustomerSupportMemory-abc123defg — a memory that does not exist.
#
# $PROJECT_DIR/main.py is a generated artifact, rewritten from the embedded
# copy on every run, so substituting real values there changes nothing in the
# repository. It also means the main.py inside the submission zip shows the
# configuration actually used, which is what the rubric asks to see.
configure_main_py() {
  local target="$PROJECT_DIR/main.py"

  python3 - "$target" "$(load gateway_url)" "$(load kb_id)" "$REGION" "$(load memory_id)" <<'PYEOF'
import sys

path, gateway_url, kb_id, region, memory_id = sys.argv[1:6]
source = open(path, encoding="utf-8").read()

placeholders = {
    "https://customersupportgateway-abc123defg.gateway.bedrock-agentcore.us-east-1.amazonaws.com/mcp": gateway_url,
    "ABCDEFGHIJ": kb_id,
    "CustomerSupportMemory-abc123defg": memory_id,
}

missing = []
for placeholder, value in placeholders.items():
    if not value:
        missing.append(placeholder)
        continue
    if placeholder not in source:
        print(f"   ! placeholder not found, not substituted: {placeholder[:40]}")
        continue
    source = source.replace(placeholder, value)

open(path, "w", encoding="utf-8").write(source)

if missing:
    print(f"   ! {len(missing)} value(s) unknown — the agent will use placeholders")
    sys.exit(1)

print(f"   ✓ main.py configured: KB={kb_id}, memory={memory_id}")
PYEOF
}

# Grant the AgentCore runtime role what the agent actually calls.
#
# The starter toolkit creates AmazonBedrockAgentCoreSDKRuntime-* with enough
# permission to start a container and nothing else. The agent then calls
# GetMemory, the Gateway, the Knowledge Base's Retrieve API, the code
# interpreter and the browser, and the first of those failed with
# AccessDeniedException.
grant_runtime_permissions() {
  local role
  role="$(aws iam list-roles \
    --query "Roles[?starts_with(RoleName,'AmazonBedrockAgentCoreSDKRuntime')].RoleName | [0]" \
    --output text 2>/dev/null)"

  if [[ -z "$role" || "$role" == "None" ]]; then
    warn "no AgentCore runtime role found yet — it is created by the first deploy"
    return 0
  fi

  # Scoped to the services this agent uses, not to "*:*". Broad within
  # bedrock-agentcore because memory, gateway, browser and code interpreter
  # are four different resource types under one service prefix.
  aws iam put-role-policy --role-name "$role" --policy-name "${PREFIX}-agent-access" \
    --policy-document '{
      "Version": "2012-10-17",
      "Statement": [
        {"Effect": "Allow",
         "Action": ["bedrock-agentcore:*"],
         "Resource": "*"},
        {"Effect": "Allow",
         "Action": ["bedrock:Retrieve", "bedrock:RetrieveAndGenerate",
                    "bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
         "Resource": "*"}
      ]}' >/dev/null 2>&1 \
    && ok "granted memory, gateway and Bedrock access to $role" \
    || warn "could not update $role — the agent may hit AccessDenied"
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
  configure_main_py || return 1
  grant_runtime_permissions

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
# Clear what earlier runs stored about the test customer.
#
# Every scenario uses customer_id CUST-123, and memory is keyed on the actor,
# so records accumulate across runs. After enough of them the injected
# "Customer Context:" block grows large enough that the model answers from it
# instead of calling a tool: a run asking "track order ORD-001" came back
# describing an ORD-002 refund and a loyalty balance, both recalled from
# previous scenarios rather than looked up.
#
# That is a real property of the agent worth knowing about, but it makes the
# six scenarios measure history rather than behaviour. Each run starts clean.
reset_memory() {
  local mem="$1"
  [[ -z "$mem" ]] && return 0

  local deleted=0 namespace record
  for namespace in "cs_agent/CUST-123/facts" "cs_agent/CUST-123/preferences"; do
    for record in $(aws bedrock-agentcore list-memory-records \
                      --memory-id "$mem" --namespace "$namespace" \
                      --region "$REGION" --max-results 100 \
                      --query 'memoryRecordSummaries[].memoryRecordId' \
                      --output text 2>/dev/null); do
      aws bedrock-agentcore delete-memory-record --memory-id "$mem" \
        --memory-record-id "$record" --region "$REGION" >/dev/null 2>&1 \
        && deleted=$((deleted + 1))
    done
  done

  # Events are what extraction runs over, so leaving them would let the same
  # records reappear. The session IDs are the ones these scenarios use.
  local session event
  for session in t1 t2 t3 s-A s-B t5 t6 probe; do
    for event in $(aws bedrock-agentcore list-events --memory-id "$mem" \
                     --actor-id CUST-123 --session-id "$session" \
                     --region "$REGION" --max-results 100 \
                     --query 'events[].eventId' --output text 2>/dev/null); do
      aws bedrock-agentcore delete-event --memory-id "$mem" \
        --actor-id CUST-123 --session-id "$session" --event-id "$event" \
        --region "$REGION" >/dev/null 2>&1 && deleted=$((deleted + 1))
    done
  done

  if [[ "$deleted" -gt 0 ]]; then
    ok "cleared $deleted memory item(s) from earlier runs"
  else
    skip "no earlier memory to clear"
  fi
}

run_tests() {
  phase "The six project test scenarios"

  [[ -z "${KEEP_MEMORY:-}" ]] && reset_memory "$(load memory_id)"

  mkdir -p "$EVIDENCE_DIR"
  local pass=0 fail=0

  # id | session | expected substrings (comma-separated) | prompt
  local scenarios=(
"01-order-tracking|t1|SHIPPED,TRK987654321,UPS|Can you track order ORD-001?"
"02-refund-processing|t2|APPROVED,3-5 business days,139.99|I want to return my Kindle Paperwhite (ORD-002). Please initiate a refund."
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
    # session A reliably fails and looks exactly like a broken hook. 45s was
    # not enough on a live run — session B was told "this is a new
    # conversation" — so the default is now 120.
    if [[ "$id" == "04b-memory-session-b" ]]; then
      printf '   %s⋯%s waiting %ss for memory extraction ' "$DIM" "$RESET" "$MEMORY_WAIT"
      sleep "$MEMORY_WAIT"; printf '%s✓%s\n' "$GREEN" "$RESET"
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
