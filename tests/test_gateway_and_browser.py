"""
The rubric's MCP row and browser row.

The Gateway tests run the *real* Lambda handler code from
``project/starter/lambda/`` — only the transport is faked — so a regression in
the handlers fails here.
"""

from __future__ import annotations

import json

import pytest

from harness import fakes, gateway


# ── MCP / Gateway ────────────────────────────────────────────────────────────


def test_connects_with_mcp_client_and_streamable_http(main_source):
    assert "MCPClient(" in main_source
    assert "streamable_http_client(GATEWAY_URL)" in main_source


def test_gateway_tools_are_loaded_and_added_to_the_agent(invoke):
    invoke("Can you track order ORD-001?")
    loads = fakes.TRACE.of_kind("gateway_tools_loaded")
    assert len(loads) == 1

    created = fakes.TRACE.of_kind("agent_created")[0]
    for name in loads[0]["tools"]:
        assert name in created["tools"], f"{name} was not added to the agent's tools"


def test_both_targets_are_exposed():
    names = [t.tool_name for t in gateway.load_tools()]
    assert names == [
        "order-tracker___get_order",
        "order-tracker___get_customer_orders",
        "order-tracker___get_customer",
        "refund-processor___initiate_refund",
        "refund-processor___check_refund_status",
        "refund-processor___get_return_label",
    ]


def test_every_tool_has_a_schema_and_a_description():
    for tool in gateway.load_tools():
        assert tool.tool_spec["description"]
        assert tool.tool_spec["inputSchema"]["json"]["type"] == "object"
        assert tool.tool_spec["inputSchema"]["json"]["required"]


def test_refund_schemas_come_from_the_real_schema_file():
    """Not restated in the harness — read from lambda_schema, so edits propagate."""
    declared = json.loads(gateway.SCHEMA_PATH.read_text(encoding="utf-8"))
    tools = {t.tool_name: t for t in gateway.load_tools()}
    for entry in declared:
        tool = tools[f"refund-processor___{entry['name']}"]
        assert tool.tool_spec["inputSchema"]["json"] == entry["inputSchema"]


def test_gateway_session_is_required_for_listing_tools():
    """Tool handles are bound to the session, exactly as against a live Gateway."""
    client = fakes.MCPClient(lambda: {"url": "https://example/mcp"})
    with pytest.raises(RuntimeError, match="session is not active"):
        client.list_tools_sync()


def test_order_lookup_runs_the_real_lambda(invoke):
    reply = invoke("Can you track order ORD-001?")
    assert "SHIPPED" in reply
    assert "TRK987654321" in reply
    assert "UPS" in reply

    call = gateway.CALL_LOG.calls[-1]
    assert call["target"] == "order-tracker"
    assert call["tool"] == "get_order"
    assert json.loads(call["result"])["tracking_number"] == "TRK987654321"


def test_unknown_order_returns_a_404_not_an_invention(invoke):
    reply = invoke("Can you track order ORD-999?")
    assert "ORD-999 not found" in reply
    assert "TRK" not in reply


def test_refund_runs_the_real_lambda_and_is_approved(invoke):
    reply = invoke(
        "I want to return my Kindle Paperwhite (ORD-002). Please initiate a refund."
    )
    assert "APPROVED" in reply
    assert "3-5 business days" in reply

    refund_calls = [c for c in gateway.CALL_LOG.calls if c["target"] == "refund-processor"]
    assert len(refund_calls) == 1
    body = json.loads(refund_calls[0]["result"])
    assert body["refund_id"].startswith("REF-")
    assert body["status"] == "APPROVED"


def test_refund_amount_comes_from_the_order_lookup(invoke):
    """
    The refund amount must be looked up, not invented — so the order tool runs
    first and its total is what reaches ``initiate_refund``.
    """
    invoke("I want to return my Kindle Paperwhite (ORD-002). Please initiate a refund.")

    tools_used = [c["tool"] for c in gateway.CALL_LOG.calls]
    assert tools_used.index("get_order") < tools_used.index("initiate_refund")

    refund_call = next(c for c in gateway.CALL_LOG.calls if c["tool"] == "initiate_refund")
    assert refund_call["arguments"]["amount"] == 139.99


def test_one_turn_uses_both_gateway_targets(invoke):
    """The rubric asks for one API-based and one Lambda-based invocation."""
    invoke("I want to return my Kindle Paperwhite (ORD-002). Please initiate a refund.")
    targets = {c["target"] for c in gateway.CALL_LOG.calls}
    assert targets == {"order-tracker", "refund-processor"}


def test_return_label_tool(invoke):
    reply = invoke("Can I get a return label for ORD-002?")
    assert "returns.amazon.com/label/ORD-002" in reply
    assert "UPS" in reply


def test_customer_profile_tool(invoke):
    reply = invoke("What tier am I on and what is my points balance?")
    assert "Gold" in reply
    assert "4,250" in reply


# ── Browser ──────────────────────────────────────────────────────────────────


def test_browser_is_instantiated_with_the_region(main_source):
    assert "AgentCoreBrowser(region=REGION)" in main_source


def test_browser_is_added_to_the_tools_list(main_source):
    assert "agent_core_browser.browser" in main_source


def test_browser_tool_is_registered_on_the_agent(invoke):
    invoke("Go to https://example.com and tell me the page title.")
    created = fakes.TRACE.of_kind("agent_created")[0]
    assert "browser" in created["tools"]


def test_browser_returns_a_page_title(invoke):
    reply = invoke("Go to https://www.udacity.com and tell me the page title.")
    assert "page title is" in reply

    event = fakes.TRACE.of_kind("browser")[0]
    assert event["url"] == "https://www.udacity.com"
    assert event["title"]
    assert event["source"] in {"live-fetch", "offline-fixture"}


def test_offline_browser_results_are_labelled_as_such(agent_module):
    """A fabricated page title presented as a live fetch would be a false record."""
    browser = fakes.AgentCoreBrowser(region="us-east-1").browser
    payload = json.loads(browser(url="http://127.0.0.1:9/never-resolves"))
    assert payload["source"] == "offline-fixture"
    assert "not a live page load" in payload["note"]
