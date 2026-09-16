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
