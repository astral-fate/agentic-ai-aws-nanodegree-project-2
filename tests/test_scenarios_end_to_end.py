"""
The six project test scenarios, as tests.

``scripts/run_scenarios.py`` runs the same six for the evidence transcripts;
this file runs them in CI so a regression fails the build rather than quietly
producing a worse transcript. The scenario definitions are imported from the
runner so the two can never drift apart.
"""

from __future__ import annotations

import asyncio

import pytest

from scripts.run_scenarios import SCENARIOS


@pytest.mark.shared_memory
@pytest.mark.parametrize(
    "scenario", SCENARIOS, ids=[s["id"] for s in SCENARIOS]
)
def test_scenario(agent_module, scenario, shared_memory):
    reply = asyncio.run(agent_module.invoke(dict(scenario["payload"])))
    missing = scenario["check"](reply)
    assert not missing, (
        f"{scenario['title']} — expected {scenario['expected']}; "
        f"missing from the reply: {missing}\n\nReply was:\n{reply}"
    )


@pytest.fixture(scope="module")
def shared_memory(tmp_path_factory):
    """
    One memory file across the whole module.

    The memory scenarios are two halves of one story: 4a stores, 4b recalls.
    The per-test isolation fixture would wipe the store between them, so this
    module opts into a shared file and the scenarios run in declaration order.
    """
    import os

    from harness import memory_store

    path = tmp_path_factory.mktemp("scenarios") / "memory.json"
    previous = os.environ.get("HARNESS_MEMORY_PATH")
    os.environ["HARNESS_MEMORY_PATH"] = str(path)
    memory_store.reset()
    yield path
    if previous is None:
        os.environ.pop("HARNESS_MEMORY_PATH", None)
    else:
        os.environ["HARNESS_MEMORY_PATH"] = previous


def test_all_six_capabilities_are_covered():
    """Every AgentCore primitive the project asks for has a scenario."""
    capabilities = {s["capability"] for s in SCENARIOS}
    assert capabilities == {
        "Gateway (API Gateway target)",
        "Gateway (Lambda target)",
        "Bedrock Knowledge Base",
        "AgentCore Memory",
        "AgentCore Code Interpreter",
        "AgentCore Browser",
    }


def test_scenario_prompts_match_the_project_instructions():
    """Guards against quietly softening a prompt to make a test pass."""
    expected = {
        "01-order-tracking": "Can you track order ORD-001?",
        "02-refund-processing": (
            "I want to return my Kindle Paperwhite (ORD-002). Please initiate a refund."
        ),
        "03-knowledge-base-rag": "What are the benefits of the Platinum loyalty tier?",
        "04a-memory-session-a": "Hi, I am Jane. I prefer concise responses.",
        "04b-memory-session-b": "Do you remember my name and communication preference?",
        "05-loyalty-discount": (
            "I am a Gold member with 4250 points. Calculate my discount on a "
            "$150 standard order."
        ),
        "06-browser-tool": "Go to https://www.udacity.com and tell me the page title.",
    }
    actual = {s["id"]: s["payload"]["prompt"] for s in SCENARIOS}
    assert actual == expected
