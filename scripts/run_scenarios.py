"""
Run the six project test scenarios against the offline harness.

    python -m scripts.run_scenarios

Each scenario is the exact prompt from the project instructions, invoked
through ``main.invoke`` — the same entrypoint ``agentcore invoke`` calls. Every
scenario then gets checked against the "Expected:" line from the instructions,
so the run either shows six passes or names what did not match.

Outputs, all under ``evidence/run-NN/``:

  transcripts/NN-name.txt   the full turn: prompt, tool calls, memory
                            activity, the reply, and the checks
  run_summary.txt           the pass/fail table
  trace.json                every harness event, machine-readable

Offline is the default because it needs no AWS account. The live equivalent
is ``cloudshell/run-all.sh``; the two produce the same transcript layout so
they can be compared side by side.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Dict, List

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from harness import fakes, gateway, memory_store  # noqa: E402

# ── Scenario definitions ─────────────────────────────────────────────────────
# Prompts are verbatim from the project instructions' "Verify Your
# Implementation" section. Checks encode the "Expected:" line beside each one.


def _has_all(*needles: str) -> Callable[[str], List[str]]:
    def check(reply: str) -> List[str]:
        low = reply.lower()
        return [n for n in needles if n.lower() not in low]

    return check


SCENARIOS = [
    {
        "id": "01-order-tracking",
        "title": "Test 1 — Order Tracking",
        "capability": "Gateway (API Gateway target)",
        "payload": {
            "prompt": "Can you track order ORD-001?",
            "customer_id": "CUST-123",
            "session_id": "t1",
        },
        "expected": "shipping status, tracking number TRK987654321, carrier UPS, estimated delivery date",
        "check": _has_all("SHIPPED", "TRK987654321", "UPS"),
    },
    {
        "id": "02-refund-processing",
        "title": "Test 2 — Refund Processing",
        "capability": "Gateway (Lambda target)",
        "payload": {
            "prompt": "I want to return my Kindle Paperwhite (ORD-002). Please initiate a refund.",
            "customer_id": "CUST-123",
            "session_id": "t2",
        },
        "expected": 'refund ID, APPROVED status, "3-5 business days" message',
        "check": _has_all("REF-", "APPROVED", "3-5 business days"),
    },
    {
        "id": "03-knowledge-base-rag",
        "title": "Test 3 — Knowledge Base (RAG)",
        "capability": "Bedrock Knowledge Base",
        "payload": {
            "prompt": "What are the benefits of the Platinum loyalty tier?",
            "customer_id": "CUST-123",
            "session_id": "t3",
        },
        "expected": "free same-day shipping, 15% discount, priority support",
        "check": _has_all("same-day shipping", "15% discount", "priority"),
    },
    {
        "id": "04a-memory-session-a",
        "title": "Test 4a — Long-Term Memory, session A (store)",
        "capability": "AgentCore Memory",
        "payload": {
            "prompt": "Hi, I am Jane. I prefer concise responses.",
            "customer_id": "CUST-123",
            "session_id": "s-A",
        },
        "expected": "the agent acknowledges; the memory strategies extract the name and the preference",
        "check": _has_all("Jane"),
        "after": "memory_extraction_wait",
    },
    {
        "id": "04b-memory-session-b",
        "title": "Test 4b — Long-Term Memory, session B (recall)",
        "capability": "AgentCore Memory",
        "payload": {
            "prompt": "Do you remember my name and communication preference?",
            "customer_id": "CUST-123",
            "session_id": "s-B",
        },
        "expected": 'agent recalls "Jane" and the preference for concise responses',
        "check": _has_all("Jane", "concise"),
    },
    {
        "id": "05-loyalty-discount",
        "title": "Test 5 — Loyalty Discount Calculation",
        "capability": "AgentCore Code Interpreter",
        "payload": {
            "prompt": "I am a Gold member with 4250 points. Calculate my discount on a $150 standard order.",
            "customer_id": "CUST-123",
            "session_id": "t5",
        },
        "expected": "points redeemed, tier discount 10%, correct final total, remaining points",
        "check": _has_all("4,000", "10.0%", "$99.00", "349"),
    },
    {
        "id": "06-browser-tool",
        "title": "Test 6 — Browser Tool",
        "capability": "AgentCore Browser",
        "payload": {
            "prompt": "Go to https://www.udacity.com and tell me the page title.",
            "customer_id": "CUST-123",
            "session_id": "t6",
        },
        "expected": "page title retrieved from the live page",
        "check": _has_all("udacity", "page title is"),
    },
]


# ── Rendering ────────────────────────────────────────────────────────────────

BAR = "=" * 84
RULE = "-" * 84


def render_transcript(scenario: Dict, reply: str, events: List[Dict], missing: List[str]) -> str:
    """Build the human-readable transcript for one scenario."""
    out: List[str] = []
    add = out.append

    add(BAR)
    add(scenario["title"])
    add(f"Capability under test : {scenario['capability']}")
    add(f"Mode                  : offline harness (no AWS account)")
    add(f"Timestamp             : {datetime.now(timezone.utc).isoformat(timespec='seconds')}")
    add(BAR)
    add("")
    add("$ agentcore invoke '" + json.dumps(scenario["payload"]) + "'")
    add("")

    tool_calls = [e for e in events if e["kind"] == "tool_call"]
    gateway_loads = [e for e in events if e["kind"] == "gateway_tools_loaded"]
    kb = [e for e in events if e["kind"] == "kb_retrieve"]
    mem_get = [e for e in events if e["kind"] == "memory_retrieve"]
    mem_put = [e for e in events if e["kind"] == "memory_save"]
    code = [e for e in events if e["kind"] == "code_interpreter"]
    browser = [e for e in events if e["kind"] == "browser"]
    user_msg = next((e for e in events if e["kind"] == "user_message"), None)

    if gateway_loads:
        names = gateway_loads[0]["tools"]
        add(f"[gateway] connected, {len(names)} MCP tools loaded:")
        for name in names:
            add(f"            {name}")
        add("")

    if mem_get:
        total_hits = sum(len(e["hits"]) for e in mem_get)
        add(f"[memory]  queried {len(mem_get)} namespace(s), {total_hits} memories returned")
        for event in mem_get:
            for hit in event["hits"]:
                add(f"            {event['namespace']} → {hit}")
        if total_hits and user_msg and user_msg["effective"] != user_msg["raw"]:
            add("")
            add("[memory]  context injected into the user message:")
            for line in user_msg["effective"].splitlines():
                add(f"            {line}")
        add("")

    for call in tool_calls:
        add(f"[tool]    {call['tool']}")
        add(f"            args   {json.dumps(call['arguments'])}")
        preview = str(call["output"])
        if len(preview) > 600:
            preview = preview[:600] + " …"
        add(f"            result {preview}")
        add("")

    if kb:
        for event in kb:
            add(
                f"[kb]      Retrieve on {event['knowledge_base_id']} "
                f"→ {event['hits']} chunk(s)"
            )
            add(f"            query: {event['query']}")
        add("")

    if code:
        for event in code:
            add(
                f"[sandbox] executeCode session={event['session']} "
                f"clearContext={event['clear_context']}"
            )
            add("            ── generated program ──")
            for line in event["code"].strip().splitlines():
                add(f"            {line}")
            add("")

    if browser:
        for event in browser:
            add(f"[browser] {event['url']} → {event['source']}")
            if event.get("note"):
                add(f"            {event['note']}")
        add("")

    if mem_put:
        for event in mem_put:
            add(
                f"[memory]  create_event {event['event_id']} "
                f"actor={event['actor_id']} session={event['session_id']} "
                f"→ {event['extracted']} memory record(s) extracted"
            )
        add("")

    add(RULE)
    add("AGENT REPLY")
    add(RULE)
    add(reply)
    add("")
    add(RULE)
    add(f"Expected: {scenario['expected']}")
    if missing:
        add("RESULT:   [FAIL] missing from the reply: " + ", ".join(missing))
    else:
        add("RESULT:   [PASS] every expected element is present")
    add(RULE)

    return "\n".join(out)


# ── Runner ───────────────────────────────────────────────────────────────────


def run(run_dir: Path, wait_seconds: int = 0) -> int:
    main = fakes.load_agent_module()

    transcripts = run_dir / "transcripts"
    transcripts.mkdir(parents=True, exist_ok=True)

    memory_store.reset()
    all_events: List[Dict] = []
    summary: List[Dict] = []
    failures = 0

    print(BAR)
    print("Customer Support Agent — six project test scenarios (offline harness)")
    print(f"Run directory: {run_dir}")
    print(BAR)
    print()

    for scenario in SCENARIOS:
        fakes.TRACE.reset()
        gateway.CALL_LOG.reset()

        started = time.time()
        reply = asyncio.run(main.invoke(dict(scenario["payload"])))
        elapsed = time.time() - started

        events = list(fakes.TRACE.entries)
        all_events.append({"scenario": scenario["id"], "events": events})

        missing = scenario["check"](reply)
        status = "PASS" if not missing else "FAIL"
        if missing:
            failures += 1

        transcript = render_transcript(scenario, reply, events, missing)
        (transcripts / f"{scenario['id']}.txt").write_text(
            transcript + "\n", encoding="utf-8"
        )

        mark = "[PASS]" if status == "PASS" else "[FAIL]"
        print(f"{mark} {scenario['title']}")
        print(f"    {scenario['capability']}  ·  {elapsed:.2f}s")
        first_line = reply.strip().splitlines()[0] if reply.strip() else "(empty)"
        print(f"    → {first_line[:70]}")
        if missing:
            print(f"    missing: {', '.join(missing)}")
        print()

        summary.append(
            {
                "id": scenario["id"],
                "title": scenario["title"],
                "capability": scenario["capability"],
                "status": status,
                "missing": missing,
                "seconds": round(elapsed, 3),
                "tool_calls": [e["tool"] for e in events if e["kind"] == "tool_call"],
            }
        )

        if scenario.get("after") == "memory_extraction_wait" and wait_seconds:
            print(f"    … waiting {wait_seconds}s for memory extraction")
            time.sleep(wait_seconds)
            print()

    # ── summary ──────────────────────────────────────────────────────────────
    lines = [BAR, "SUMMARY", BAR, ""]
    lines.append(f"{'Scenario':<46} {'Capability':<28} Result")
    lines.append("-" * 84)
    for row in summary:
        mark = "[PASS]" if row["status"] == "PASS" else "[FAIL]"
        lines.append(f"{row['title']:<46} {row['capability']:<28} {mark}")
    lines.append("")
    lines.append(
        f"{len(summary) - failures}/{len(summary)} scenarios passed  ·  "
        f"{datetime.now(timezone.utc).isoformat(timespec='seconds')}"
    )
    lines.append("")
    lines.append("Mode: offline harness. Gateway tools run the real Lambda handler")
    lines.append("code and the discount is computed by really executing the")
    lines.append("generated program. Tool ROUTING is rule-based, not Nova 2 Lite —")
    lines.append("see docs/TESTING.md for what that does and does not prove.")
    lines.append(BAR)

    report = "\n".join(lines)
    (run_dir / "run_summary.txt").write_text(report + "\n", encoding="utf-8")
    (run_dir / "trace.json").write_text(
        json.dumps(all_events, indent=2, default=str), encoding="utf-8"
    )
    (run_dir / "memory_state.json").write_text(
        json.dumps(
            {"memories": memory_store.all_memories(), "events": memory_store.all_events()},
            indent=2,
        ),
        encoding="utf-8",
    )

    print(report)
    return 1 if failures else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--run-dir",
        default=str(ROOT / "evidence" / "run-01"),
        help="where to write transcripts and the summary",
    )
    parser.add_argument(
        "--wait",
        type=int,
        default=0,
        help=(
            "seconds to pause after memory session A. Offline extraction is "
            "synchronous so 0 is correct; live runs need 30+."
        ),
    )
    args = parser.parse_args()

    os.environ.setdefault("HARNESS_MEMORY_PATH", str(ROOT / ".harness-state" / "memory.json"))
    return run(Path(args.run_dir), args.wait)


if __name__ == "__main__":
    raise SystemExit(main())
