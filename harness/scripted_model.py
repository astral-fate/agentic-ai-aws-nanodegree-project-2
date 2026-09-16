"""
Deterministic stand-in for Nova 2 Lite.

This is the honest limit of the offline harness, so it is worth stating plainly
rather than burying: **this is not a language model.** It is a rule-based
planner that reads the customer's message, decides which tools to call, and
composes a reply from the results. The rules mirror the tool-selection guidance
in ``SYSTEM_PROMPT`` — but they mirror it by hand.

What a green offline run therefore means:

  the wiring is correct     tools are registered with the right names and
                            schemas, arguments reach them in the right shape,
                            results come back parseable, memory is written and
                            read on the right namespaces, and the sandbox
                            arithmetic is right

what it does not mean:

  the model behaves         whether Nova 2 Lite actually picks
                            ``search_knowledge_base`` over answering a policy
                            question from its own weights, or remembers to look
                            up the order total before calling
                            ``initiate_refund``, is a question only the
                            deployed agent can answer

Routing accuracy is measured live. See docs/TESTING.md.
"""

from __future__ import annotations

import json
import re
from typing import Any, Dict, List, Optional, Tuple

# ── Argument extraction ──────────────────────────────────────────────────────

_ORDER_ID = re.compile(r"\b(ORD[-\s]?\d{3,})\b", re.I)
_REFUND_ID = re.compile(r"\b(REF[-\s]?[A-Z0-9]{4,})\b", re.I)
_CUSTOMER_ID = re.compile(r"\b(CUST[-\s]?\d{3,})\b", re.I)
_POINTS = re.compile(r"([\d,]+)\s*(?:loyalty\s*)?points", re.I)
_TIER = re.compile(r"\b(silver|gold|platinum)\b", re.I)
_MONEY = re.compile(r"\$\s*([\d,]+(?:\.\d{1,2})?)")
_CATEGORY = re.compile(r"\b(standard|device|fresh)\b", re.I)
_URL = re.compile(r"https?://[^\s\"'<>)\]]+")

_CONTEXT_BLOCK = re.compile(r"^Customer Context:\n(.*?)\n\n", re.S)


def _norm_id(raw: str) -> str:
    return re.sub(r"\s+", "-", raw.strip().upper()).replace("--", "-")


def split_context(message: str) -> Tuple[List[str], str]:
    """
    Separate an injected ``Customer Context:`` block from the customer's words.

    The memory hook prepends context to the user message. Planning must run on
    what the customer actually said — otherwise a remembered "$150 order" would
    steer a question that has nothing to do with it.
    """
    match = _CONTEXT_BLOCK.match(message)
    if not match:
        return [], message

    lines = [
        line.strip().lstrip("- ").strip()
        for line in match.group(1).splitlines()
        if line.strip()
    ]
    return lines, message[match.end():]


# ── Planning ─────────────────────────────────────────────────────────────────

ToolCall = Tuple[str, Dict[str, Any]]


def _find(tools: Dict[str, Any], *suffixes: str) -> Optional[str]:
    """
    Find a registered tool by name, tolerating the Gateway's target prefix.

    Exact and prefix-stripped matches are tried across *every* tool before any
    substring match, because ``get_customer`` is a substring of
    ``get_customer_orders`` — a single pass that accepts substrings returns
    whichever happens to be registered first.
    """
    for suffix in suffixes:
        for name in tools:
            if name == suffix or name.endswith(f"___{suffix}"):
                return name

    for suffix in suffixes:
        for name in tools:
            if suffix in name:
                return name

    return None


def plan(message: str, tools: Dict[str, Any]) -> List[ToolCall]:
    """Decide which tools to call, in order, for one customer message."""
    _, text = split_context(message)
    low = text.lower()
    calls: List[ToolCall] = []

    order_match = _ORDER_ID.search(text)
    order_id = _norm_id(order_match.group(1)) if order_match else None

    customer_match = _CUSTOMER_ID.search(text)
    customer_id = _norm_id(customer_match.group(1)) if customer_match else None

    # ── 1. Browser — an explicit URL wins over everything else ───────────────
    url = _URL.search(text)
    if url:
        browser = _find(tools, "browser")
        if browser:
            return [(browser, {"url": url.group(0).rstrip(".,")})]

    # ── 2. Refunds and returns ───────────────────────────────────────────────
    wants_refund = any(
        k in low for k in ("refund", "return my", "return the", "money back", "send it back")
    )
    wants_label = "return label" in low or "shipping label" in low
    refund_match = _REFUND_ID.search(text)

    if refund_match and ("status" in low or "check" in low):
        tool = _find(tools, "check_refund_status")
        if tool:
            return [(tool, {"refund_id": _norm_id(refund_match.group(1))})]

    if wants_label and order_id:
        tool = _find(tools, "get_return_label")
        if tool:
            return [(tool, {"order_id": order_id})]

    if wants_refund and order_id:
        # Look the order up first. The refund amount has to come from the
        # order record — a refund for a number the model invented is the
        # failure mode this ordering exists to prevent.
        lookup = _find(tools, "get_order")
        refund = _find(tools, "initiate_refund")
        if lookup:
            calls.append((lookup, {"order_id": order_id}))
        if refund:
            calls.append(
                (
                    refund,
                    {
                        "order_id": order_id,
                        "reason": _refund_reason(text),
                        "amount": None,  # filled from the lookup result
                    },
                )
            )
        return calls

    # ── 3. Order and customer lookups ────────────────────────────────────────
    if order_id:
        tool = _find(tools, "get_order")
        if tool:
            return [(tool, {"order_id": order_id})]

    if any(k in low for k in ("my orders", "all my orders", "order history", "orders for")):
        tool = _find(tools, "get_customer_orders")
        if tool:
            return [(tool, {"customer_id": customer_id or "CUST-123"})]

    # ── 4. Loyalty arithmetic ────────────────────────────────────────────────
    asks_calculation = any(
        k in low
        for k in ("calculate", "discount", "how much will", "final price", "final total", "what would i pay")
    )
    if asks_calculation and ("point" in low or "tier" in low or _TIER.search(text)):
        tool = _find(tools, "calculate_loyalty_discount")
        if tool:
            args = _discount_args(text)
            if args.get("loyalty_points") is None or args.get("order_total") is None:
                # Missing numbers — fetch the profile instead of guessing.
                profile = _find(tools, "get_customer")
                if profile and args.get("loyalty_points") is None:
                    calls.append((profile, {"customer_id": customer_id or "CUST-123"}))
            calls.append((tool, args))
            return calls

    # ── 5. Customer profile ──────────────────────────────────────────────────
    if any(
        k in low
        for k in ("my tier", "what tier", "my points", "points balance", "my profile", "my account")
    ):
        tool = _find(tools, "get_customer")
        if tool:
            return [(tool, {"customer_id": customer_id or "CUST-123"})]

    # ── 6. Knowledge base — policy and product questions ─────────────────────
    kb_triggers = (
        "policy", "policies", "warranty", "return window", "how long",
        "benefit", "tier", "loyalty", "specification", "specs", "battery",
        "waterproof", "storage", "price of", "how much is", "what is",
        "what are", "shipping", "deliver", "redeem", "earn", "status mean",
    )
    if any(k in low for k in kb_triggers):
        tool = _find(tools, "search_knowledge_base")
        if tool:
            return [(tool, {"query": text.strip()})]

    # ── 7. Nothing to look up — conversational turn ──────────────────────────
    return []


def _refund_reason(text: str) -> str:
    """Pull a reason out of the message, defaulting to a neutral one."""
    match = re.search(r"\bbecause ([^.!?\n]+)", text, re.I)
    if match:
        return match.group(1).strip()[:200]
    if "defect" in text.lower() or "broken" in text.lower() or "damaged" in text.lower():
        return "Item arrived damaged or defective"
    return "Customer requested return"


def _discount_args(text: str) -> Dict[str, Any]:
    points = _POINTS.search(text)
    tier = _TIER.search(text)
    money = _MONEY.search(text)
    category = _CATEGORY.search(text)

    return {
        "loyalty_points": int(points.group(1).replace(",", "")) if points else None,
        "tier": tier.group(1).title() if tier else "Silver",
        "order_total": float(money.group(1).replace(",", "")) if money else None,
        "product_category": category.group(1).lower() if category else "standard",
    }


# ── Composition ──────────────────────────────────────────────────────────────

def compose(message: str, results: List[Dict[str, Any]]) -> str:
    """Write the customer-facing reply from the tool results."""
    context_lines, text = split_context(message)

    greeting = _greeting(context_lines)
    concise = any("concise" in c.lower() or "short" in c.lower() for c in context_lines)

    if not results:
        return _conversational(text, context_lines, greeting)

    parts = [_render(r) for r in results]
    parts = [p for p in parts if p]
    body = " ".join(parts) if concise else "\n\n".join(parts)

    return f"{greeting}{body}" if greeting else body


def _greeting(context_lines: List[str]) -> str:
    for line in context_lines:
        match = re.search(r"name is ([A-Z][a-zA-Z'\-]+)", line)
        if match:
            return f"Hi {match.group(1)}! "
    return ""


def _conversational(text: str, context_lines: List[str], greeting: str) -> str:
    """A turn with no tool call: acknowledge, and use memory if we have it."""
    low = text.lower()

    if context_lines and any(
        k in low for k in ("remember", "who am i", "what do you know", "my name", "recall")
    ):
        name = None
        preference = None
        for line in context_lines:
            match = re.search(r"name is ([A-Z][a-zA-Z'\-]+)", line)
            if match:
                name = match.group(1)
            if "prefers" in line.lower():
                preference = re.sub(
                    r"^\[.*?\]\s*The customer prefers ", "", line
                ).replace(" (communication preference).", "")

        bits = []
        if name:
            bits.append(f"yes — you're {name}")
        if preference:
            bits.append(f"and you prefer {preference}")
        if bits:
            return (
                "Of course, " + ", ".join(bits) + ". "
                "I'll keep it brief. What can I help you with?"
            )

    # An introduction with no lookup attached: acknowledge what was said, so
    # the customer can see it landed before the memory strategies run.
    introduced = re.search(
        r"(?i:\bmy name is|\bi am|\bi'?m)\s+([A-Z][a-zA-Z'\-]+)\b", text
    )
    stated_preference = re.search(r"(?i:\bi prefer)\s+([^.!?\n]+)", text)

    if introduced or stated_preference:
        bits = []
        if introduced and introduced.group(1).lower() not in {"a", "an", "the", "not"}:
            bits.append(f"nice to meet you, {introduced.group(1)}")
        if stated_preference:
            bits.append(
                f"I've noted that you prefer {stated_preference.group(1).strip().rstrip('.')}"
            )
        if bits:
            return (
                f"{greeting}{'. '.join(b[0].upper() + b[1:] for b in bits)}. "
                "How can I help you today?"
            )

    if any(k in low for k in ("hi", "hello", "hey")):
        return f"{greeting}Hello! How can I help you today?"

    return (
        f"{greeting}I can help with order tracking, returns and refunds, product "
        "and policy questions, and loyalty discounts. What do you need?"
    )


def _render(result: Dict[str, Any]) -> str:
    """Turn one tool result into a sentence or two."""
    tool = result["tool"]
    raw = result["output"]

    data = raw
    if isinstance(raw, str):
        try:
            data = json.loads(raw)
        except (json.JSONDecodeError, TypeError):
            data = raw

    if isinstance(data, dict) and "error" in data:
        return f"I couldn't complete that lookup: {data['error']}."

    if "get_order" in tool:
        return _render_order(data)
    if "get_customer_orders" in tool:
        return _render_order_list(data)
    if "get_customer" in tool:
        return (
            f"You're {data.get('name')}, on the {data.get('tier')} tier with "
            f"{data.get('loyalty_points'):,} loyalty points."
        )
    if "initiate_refund" in tool:
        return (
            f"Your refund is approved. Refund ID {data.get('refund_id')} for "
            f"${float(data.get('amount') or 0):.2f} on order {data.get('order_id')}, "
            f"status {data.get('status')}. {data.get('message')}"
        )
    if "check_refund_status" in tool:
        return (
            f"Refund {data.get('refund_id')} is currently {data.get('status')}, "
            f"with an ETA of {data.get('eta')}."
        )
    if "get_return_label" in tool:
        return (
            f"Here's your prepaid {data.get('carrier')} return label for order "
            f"{data.get('order_id')}: {data.get('label_url')} "
            f"(valid until {data.get('valid_until')})."
        )
    if "calculate_loyalty_discount" in tool:
        return _render_discount(data)
    if "search_knowledge_base" in tool:
        return _render_kb(str(raw))
    if "browser" in tool:
        return _render_browser(data)

    return str(raw)


def _render_order(data: Dict) -> str:
    status = data.get("status")
    items = ", ".join(
        f"{i['qty']}× {i['name']}" for i in data.get("items", [])
    )
    line = (
        f"Order {data.get('order_id')} ({items}, "
        f"${float(data.get('total') or 0):,.2f}) is {status}."
    )

    if data.get("tracking_number"):
        line += (
            f" It's with {data.get('carrier')} under tracking number "
            f"{data.get('tracking_number')}."
        )
    if data.get("estimated_delivery"):
        line += f" Estimated delivery is {data.get('estimated_delivery')}."
    if data.get("delivered_date"):
        line += f" It was delivered on {data.get('delivered_date')}."
    return line


def _render_order_list(data: Dict) -> str:
    orders = data.get("orders", [])
    lines = [f"You have {len(orders)} order(s) on file for {data.get('customer_id')}:"]
    for order in orders:
        lines.append(
            f"  • {order['order_id']} — {order['status']}, "
            f"${float(order['total']):,.2f}"
        )
    return "\n".join(lines)


def _unwrap_code_result(data: Any) -> Any:
    """
    Pull the calculation out of the Code Interpreter envelope.

    ``calculate_loyalty_discount`` returns whatever ``executeCode`` streamed
    back, which wraps the program's stdout in ``content[0].text``. The fallback
    path returns the breakdown directly, so handle both shapes.
    """
    if isinstance(data, dict) and "content" in data and "points_redeemed" not in data:
        for block in data.get("content") or []:
            text = block.get("text") if isinstance(block, dict) else None
            if not text:
                continue
            try:
                return json.loads(text)
            except json.JSONDecodeError:
                return {"raw_output": text, "isError": data.get("isError")}
    return data


def _render_discount(data: Dict) -> str:
    data = _unwrap_code_result(data)

    if not isinstance(data, dict) or data.get("points_redeemed") is None:
        return (
            "The discount calculator did not return a usable breakdown: "
            f"{json.dumps(data)[:400]}"
        )

    note = " (tier discount only — the calculator sandbox was unavailable)" if data.get("fallback") else ""
    def money(key: str) -> str:
        return f"${float(data.get(key) or 0):,.2f}"

    return (
        f"Here's the breakdown on your {money('order_total')} "
        f"{data.get('product_category', 'standard')} order{note}:\n"
        f"  • Points redeemed: {data.get('points_redeemed'):,} "
        f"(worth {money('points_value')})\n"
        f"  • {data.get('tier')} tier discount: {data.get('tier_discount_pct')}% "
        f"= {money('tier_discount')}\n"
        f"  • Final total: {money('final_total')}\n"
        f"  • Total saved: {money('total_savings')}\n"
        f"  • Points earned on this order: {data.get('points_earned')}\n"
        f"  • Remaining points balance: {data.get('remaining_points'):,}"
    )


def _render_kb(raw: str) -> str:
    """
    Quote the retrieved chunks rather than paraphrasing them.

    Everything in the reply comes verbatim from the chunks the Retrieve API
    returned — that is the whole point of grounding, and paraphrasing here
    would hide a retrieval miss behind fluent prose.
    """
    chunks = [c.strip() for c in raw.split("\n---\n") if c.strip()]
    if not chunks:
        return "I couldn't find that in the product catalog."

    rendered = []
    for chunk in chunks[:2]:
        lines = chunk.splitlines()
        heading = next(
            (l.lstrip("# ").strip() for l in lines if l.startswith("#")), "Catalog"
        )
        body = [l.strip() for l in lines if l.strip() and not l.startswith("#")]
        if body:
            rendered.append(f"**{heading}**\n" + "\n".join(body))

    if not rendered:
        return "I couldn't find that in the product catalog."

    return "Here's what the knowledge base has:\n\n" + "\n\n".join(rendered)


def _render_browser(data: Any) -> str:
    if isinstance(data, dict):
        return (
            f"I loaded {data.get('url')} — the page title is "
            f"\"{data.get('title')}\"."
        )
    return str(data)
