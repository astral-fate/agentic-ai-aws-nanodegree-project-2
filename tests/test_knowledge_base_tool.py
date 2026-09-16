"""
The rubric's RAG row: ``search_knowledge_base``.

Requirements checked here:
  - decorated with @tool and carrying a docstring the model can route on
  - calls the Retrieve API
  - joins retrieved chunks into a single formatted string
  - guard clause when KB_ID is not configured
"""

from __future__ import annotations

import pytest

from harness import fakes


def test_is_a_registered_tool(agent_module):
    tool = agent_module.search_knowledge_base
    assert getattr(tool, "is_tool", False)
    assert tool.tool_name == "search_knowledge_base"


def test_docstring_tells_the_model_when_to_call_it(agent_module):
    doc = agent_module.search_knowledge_base.__doc__ or ""
    assert "Use this for" in doc
    for topic in ("return polic", "warranty", "loyalty"):
        assert topic in doc.lower(), f"docstring should mention {topic}"


def test_calls_the_retrieve_api(agent_module):
    agent_module.search_knowledge_base("return policy for electronics")
    calls = fakes.TRACE.of_kind("kb_retrieve")
    assert len(calls) == 1
    assert calls[0]["knowledge_base_id"] == agent_module.KB_ID
    assert calls[0]["query"] == "return policy for electronics"


def test_joins_chunks_with_the_separator(agent_module, monkeypatch):
    """
    Stubbed rather than driven through retrieval, so this tests main.py's
    joining logic and not the ranking of the offline index.
    """
    monkeypatch.setattr(
        agent_module._bedrock_runtime,
        "retrieve",
        lambda **kwargs: {
            "retrievalResults": [
                {"content": {"text": "chunk one"}},
                {"content": {"text": "chunk two"}},
                {"content": {"text": "chunk three"}},
            ]
        },
    )
    assert agent_module.search_knowledge_base("anything") == (
        "chunk one\n---\nchunk two\n---\nchunk three"
    )


def test_skips_chunks_with_no_text(agent_module, monkeypatch):
    monkeypatch.setattr(
        agent_module._bedrock_runtime,
        "retrieve",
        lambda **kwargs: {
            "retrievalResults": [
                {"content": {"text": "kept"}},
                {"content": {}},
                {},
            ]
        },
    )
    assert agent_module.search_knowledge_base("anything") == "kept"


def test_returns_grounded_catalog_text(agent_module):
    result = agent_module.search_knowledge_base(
        "What are the benefits of the Platinum loyalty tier?"
    )
    assert "Platinum" in result
    assert "same-day shipping" in result
    assert "15% discount" in result


def test_electronics_return_window(agent_module):
    """The project's own Check 3: the 15-day electronics window."""
    result = agent_module.search_knowledge_base(
        "What is the return policy for electronics?"
    )
    assert "15 days" in result


@pytest.mark.parametrize("bad_kb_id", ["", "<kbid>"])
def test_guard_clause_when_kb_is_not_configured(agent_module, monkeypatch, bad_kb_id):
    monkeypatch.setattr(agent_module, "KB_ID", bad_kb_id)
    result = agent_module.search_knowledge_base("anything")
    assert "not configured" in result.lower()
    assert "KB_ID" in result
    assert not fakes.TRACE.of_kind("kb_retrieve"), "must not call AWS when unconfigured"


def test_empty_results_return_a_descriptive_message(agent_module):
    result = agent_module.search_knowledge_base("zzzz qqqq xxxx")
    assert "No information found" in result


def test_retrieve_failure_is_reported_not_raised(agent_module, monkeypatch):
    def boom(**kwargs):
        raise RuntimeError("AccessDeniedException")

    monkeypatch.setattr(agent_module._bedrock_runtime, "retrieve", boom)
    result = agent_module.search_knowledge_base("return policy")
    assert "failed" in result.lower()
    assert "AccessDeniedException" in result
