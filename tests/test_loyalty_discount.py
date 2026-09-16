"""
The rubric's Code Interpreter row: ``calculate_loyalty_discount``.

The arithmetic tests matter more than they look. The whole reason this tool
exists is that a language model doing money arithmetic in its head gets it
wrong in ways nobody notices — so the expected values below are worked out by
hand from the catalog's stated rules, not copied from the program's output.
"""

from __future__ import annotations

import json

import pytest

from harness import fakes


def _result(agent_module, **kwargs):
    """Call the tool and unwrap the Code Interpreter envelope."""
    raw = json.loads(agent_module.calculate_loyalty_discount(**kwargs))
    if "content" in raw:
        return json.loads(raw["content"][0]["text"])
    return raw


def test_is_a_registered_tool(agent_module):
    tool = agent_module.calculate_loyalty_discount
    assert getattr(tool, "is_tool", False)
    assert tool.tool_name == "calculate_loyalty_discount"


def test_code_string_encodes_the_business_rules(main_source):
    for rule in (
        '"standard": 1',
        '"device": 2',
        '"fresh": 5',
        '"Silver": 0.00',
        '"Gold": 0.10',
        '"Platinum": 0.15',
        "POINTS_PER_DOLLAR",
        "MIN_REDEMPTION",
    ):
        assert rule in main_source, f"business rule missing from the code string: {rule}"


def test_executes_with_clear_context(agent_module):
    agent_module.calculate_loyalty_discount(4250, "Gold", 150.0, "standard")
    runs = fakes.TRACE.of_kind("code_interpreter")
    assert len(runs) == 1
    assert runs[0]["clear_context"] is True


def test_invokes_execute_code_in_python(main_source):
    assert 'session.invoke(' in main_source
    assert '"executeCode"' in main_source
    assert '"language": "python"' in main_source
    assert '"clearContext": True' in main_source


def test_returns_all_four_required_fields(agent_module):
    result = _result(
        agent_module,
        loyalty_points=4250,
        tier="Gold",
        order_total=150.0,
        product_category="standard",
    )
    for field in ("points_redeemed", "tier_discount_pct", "final_total", "remaining_points"):
        assert field in result, f"rubric requires the {field} field"


def test_the_projects_own_worked_example(agent_module):
    """
    Test 5 from the project instructions: Gold, 4250 points, $150 standard.

    By hand, from the catalog rules:
      points may cover at most 50% of $150       → $75 → 7500 points
      the customer has 4250, floored to 500s     → 4000 points → $40.00
      subtotal after points                      → $110.00
      Gold tier discount, 10% of the subtotal    → $11.00
      final total                                → $99.00
      points earned, 1/$ on what they pay        → 99
      remaining balance, 4250 − 4000 + 99        → 349
    """
    result = _result(
        agent_module,
        loyalty_points=4250,
        tier="Gold",
        order_total=150.0,
        product_category="standard",
    )

    assert result["points_redeemed"] == 4000
    assert result["points_value"] == 40.00
    assert result["subtotal"] == 110.00
    assert result["tier_discount_pct"] == 10.0
    assert result["tier_discount"] == 11.00
    assert result["final_total"] == 99.00
    assert result["total_savings"] == 51.00
    assert result["points_earned"] == 99
    assert result["remaining_points"] == 349


def test_points_are_capped_at_half_the_order(agent_module):
    """20,000 points is $200, but a $100 order caps redemption at $50."""
    result = _result(
        agent_module,
        loyalty_points=20000,
        tier="Silver",
        order_total=100.0,
        product_category="standard",
    )
    assert result["points_redeemed"] == 5000
    assert result["points_value"] == 50.00
    assert result["final_total"] == 50.00


def test_below_the_minimum_nothing_is_redeemed(agent_module):
    result = _result(
        agent_module,
        loyalty_points=499,
        tier="Silver",
        order_total=100.0,
        product_category="standard",
    )
    assert result["points_redeemed"] == 0
    assert result["points_value"] == 0.00
    assert result["final_total"] == 100.00


def test_points_floor_to_500_blocks(agent_module):
    result = _result(
        agent_module,
        loyalty_points=1499,
        tier="Silver",
        order_total=100.0,
        product_category="standard",
    )
    assert result["points_redeemed"] == 1000


@pytest.mark.parametrize(
    "tier,expected_pct",
    [("Silver", 0.0), ("Gold", 10.0), ("Platinum", 15.0), ("gold", 10.0)],
)
def test_tier_rates(agent_module, tier, expected_pct):
    result = _result(
        agent_module,
        loyalty_points=0,
        tier=tier,
        order_total=200.0,
        product_category="standard",
    )
    assert result["tier_discount_pct"] == expected_pct


@pytest.mark.parametrize(
    "category,expected_earned",
    [("standard", 100), ("device", 200), ("fresh", 500)],
)
def test_earn_rates_by_category(agent_module, category, expected_earned):
    result = _result(
        agent_module,
        loyalty_points=0,
        tier="Silver",
        order_total=100.0,
        product_category=category,
    )
    assert result["final_total"] == 100.00
    assert result["points_earned"] == expected_earned


def test_unknown_tier_earns_no_discount(agent_module):
    result = _result(
        agent_module,
        loyalty_points=0,
        tier="Bronze",
        order_total=100.0,
        product_category="standard",
    )
    assert result["tier_discount_pct"] == 0.0
    assert result["final_total"] == 100.00


def test_fallback_when_the_sandbox_is_unavailable(agent_module, monkeypatch):
    """The rubric requires a tier-only fallback path."""

    def broken(region):
        raise RuntimeError("code interpreter unavailable")

    monkeypatch.setattr(agent_module, "code_session", broken)

    result = json.loads(
        agent_module.calculate_loyalty_discount(4250, "Gold", 150.0, "standard")
    )

    assert result["fallback"] is True
    assert result["points_redeemed"] == 0
    assert result["tier_discount_pct"] == 10.0
    assert result["tier_discount"] == 15.00  # 10% of the full $150, no points
    assert result["final_total"] == 135.00
    assert result["remaining_points"] == 4250
    assert "unavailable" in result["note"].lower()


def test_fallback_keeps_the_required_fields(agent_module, monkeypatch):
    monkeypatch.setattr(
        agent_module, "code_session", lambda region: (_ for _ in ()).throw(RuntimeError())
    )
    result = json.loads(agent_module.calculate_loyalty_discount(100, "Silver", 50.0))
    for field in ("points_redeemed", "tier_discount_pct", "final_total", "remaining_points"):
        assert field in result
