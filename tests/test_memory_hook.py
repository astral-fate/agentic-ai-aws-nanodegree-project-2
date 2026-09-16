"""
The rubric's memory row: namespaces, the hook, retrieval, persistence, recall.

The cross-session requirement gets its own test at the bottom: two sessions,
same customer, information stored in the first and retrieved in the second.
"""

from __future__ import annotations

from harness import fakes, memory_store


# ── get_namespaces ───────────────────────────────────────────────────────────


def test_returns_strategy_type_to_namespace_mapping(agent_module):
    namespaces = agent_module.get_namespaces(
        agent_module.memory_client, agent_module.MEMORY_ID
    )
    assert namespaces == {
        "SEMANTIC": "cs_agent/{actorId}/facts",
        "USER_PREFERENCE": "cs_agent/{actorId}/preferences",
    }


def test_reads_the_legacy_namespaces_field(agent_module):
    """The two API versions disagree on the key name; both must work."""

    class LegacyClient:
        def get_memory_strategies(self, memory_id):
            return [{"type": "SEMANTIC", "namespaces": ["legacy/{actorId}/facts"]}]

    result = agent_module.get_namespaces(LegacyClient(), "mem-1")
    assert result == {"SEMANTIC": "legacy/{actorId}/facts"}


def test_prefers_namespace_templates_over_legacy(agent_module):
    class BothClient:
        def get_memory_strategies(self, memory_id):
            return [
                {
                    "type": "SEMANTIC",
                    "namespaceTemplates": ["new/{actorId}/facts"],
                    "namespaces": ["old/{actorId}/facts"],
                }
            ]

    assert agent_module.get_namespaces(BothClient(), "mem-1") == {
        "SEMANTIC": "new/{actorId}/facts"
    }


def test_strategy_without_namespaces_is_skipped(agent_module):
    class PartialClient:
        def get_memory_strategies(self, memory_id):
            return [
                {"type": "SEMANTIC", "namespaceTemplates": []},
                {"type": "USER_PREFERENCE", "namespaceTemplates": ["p/{actorId}"]},
            ]

    assert agent_module.get_namespaces(PartialClient(), "mem-1") == {
        "USER_PREFERENCE": "p/{actorId}"
    }


# ── the hook ─────────────────────────────────────────────────────────────────


def _hook(agent_module, actor="CUST-123", session="s1"):
    return agent_module.MemoryHook(
        actor_id=actor,
        session_id=session,
        memory_client=agent_module.memory_client,
        memory_id=agent_module.MEMORY_ID,
    )


def test_hook_extends_hook_provider(agent_module):
    assert issubclass(agent_module.MemoryHook, fakes.HookProvider)


def test_hook_stores_its_four_attributes(agent_module):
    hook = _hook(agent_module)
    assert hook.actor_id == "CUST-123"
    assert hook.session_id == "s1"
    assert hook.memory_id == agent_module.MEMORY_ID
    assert hook.memory_client is agent_module.memory_client
    assert set(hook.namespaces) == {"SEMANTIC", "USER_PREFERENCE"}


def test_register_hooks_wires_both_callbacks(agent_module):
    hook = _hook(agent_module)
    registry = fakes.HookRegistry()
    hook.register_hooks(registry)

    added = registry.registered(fakes.MessageAddedEvent)
    after = registry.registered(fakes.AfterInvocationEvent)

    assert [c.__name__ for c in added] == ["retrieve_customer_context"]
    assert [c.__name__ for c in after] == ["save_support_interaction"]


class _FakeAgent:
    def __init__(self, messages):
        self.messages = messages


def test_retrieval_queries_every_namespace(agent_module):
    memory_store.create_event(
        agent_module.MEMORY_ID,
        "CUST-123",
        "s0",
        [("Hi, I am Jane. I prefer concise responses.", "USER"), ("Noted.", "ASSISTANT")],
    )

    hook = _hook(agent_module)
    messages = [{"role": "user", "content": [{"text": "What is my name?"}]}]
    hook.retrieve_customer_context(fakes.MessageAddedEvent(_FakeAgent(messages)))

    queried = {e["namespace"] for e in fakes.TRACE.of_kind("memory_retrieve")}
    assert queried == {"cs_agent/CUST-123/facts", "cs_agent/CUST-123/preferences"}


def test_retrieval_tags_memories_by_strategy_type(agent_module):
    memory_store.create_event(
        agent_module.MEMORY_ID,
        "CUST-123",
        "s0",
        [("Hi, I am Jane. I prefer concise responses.", "USER"), ("Noted.", "ASSISTANT")],
    )

    hook = _hook(agent_module)
    messages = [{"role": "user", "content": [{"text": "What is my name?"}]}]
    hook.retrieve_customer_context(fakes.MessageAddedEvent(_FakeAgent(messages)))

    text = messages[0]["content"][0]["text"]
    assert text.startswith("Customer Context:\n")
    assert "[SEMANTIC]" in text
    assert "[USER_PREFERENCE]" in text
    assert text.endswith("What is my name?"), "original query must be preserved"


def test_retrieval_is_a_no_op_with_no_stored_memories(agent_module):
    hook = _hook(agent_module)
    messages = [{"role": "user", "content": [{"text": "Track ORD-001"}]}]
    hook.retrieve_customer_context(fakes.MessageAddedEvent(_FakeAgent(messages)))
    assert messages[0]["content"][0]["text"] == "Track ORD-001"


def test_retrieval_skips_assistant_messages(agent_module):
    hook = _hook(agent_module)
    messages = [{"role": "assistant", "content": [{"text": "Hello"}]}]
    hook.retrieve_customer_context(fakes.MessageAddedEvent(_FakeAgent(messages)))
    assert not fakes.TRACE.of_kind("memory_retrieve")


def test_retrieval_skips_tool_results(agent_module):
    """
    Tool results arrive with role "user". Without the toolResult guard, every
    tool response would trigger another retrieval and the context block would
    be injected repeatedly into the same turn.
    """
    hook = _hook(agent_module)
    messages = [
        {
            "role": "user",
            "content": [{"text": '{"order_id": "ORD-001"}', "toolResult": {"status": "ok"}}],
        }
    ]
    hook.retrieve_customer_context(fakes.MessageAddedEvent(_FakeAgent(messages)))
    assert not fakes.TRACE.of_kind("memory_retrieve")


def test_retrieval_failure_does_not_break_the_turn(agent_module, monkeypatch):
    hook = _hook(agent_module)

    def boom(**kwargs):
        raise RuntimeError("ThrottlingException")

    monkeypatch.setattr(hook.memory_client, "retrieve_memories", boom)
    messages = [{"role": "user", "content": [{"text": "hello"}]}]
    hook.retrieve_customer_context(fakes.MessageAddedEvent(_FakeAgent(messages)))
    assert messages[0]["content"][0]["text"] == "hello"


def test_save_extracts_the_last_query_and_response(agent_module):
    hook = _hook(agent_module)
    messages = [
        {"role": "user", "content": [{"text": "Track ORD-001"}]},
        {"role": "assistant", "content": [{"toolUse": {"name": "get_order"}}]},
        {"role": "user", "content": [{"toolResult": {"status": "success"}}]},
        {"role": "assistant", "content": [{"text": "It shipped via UPS."}]},
    ]
    hook.save_support_interaction(fakes.AfterInvocationEvent(_FakeAgent(messages)))

    saved = fakes.TRACE.of_kind("memory_save")
    assert len(saved) == 1

    events = memory_store.all_events()
    assert events[-1]["messages"] == [
        {"text": "Track ORD-001", "role": "USER"},
        {"text": "It shipped via UPS.", "role": "ASSISTANT"},
    ]


def test_save_is_a_no_op_without_a_complete_pair(agent_module):
    hook = _hook(agent_module)
    messages = [{"role": "user", "content": [{"text": "Hello?"}]}]
    hook.save_support_interaction(fakes.AfterInvocationEvent(_FakeAgent(messages)))
    assert not fakes.TRACE.of_kind("memory_save")


def test_save_failure_does_not_break_the_turn(agent_module, monkeypatch):
    hook = _hook(agent_module)

    def boom(**kwargs):
        raise RuntimeError("ServiceQuotaExceeded")

    monkeypatch.setattr(hook.memory_client, "create_event", boom)
    messages = [
        {"role": "user", "content": [{"text": "hi"}]},
        {"role": "assistant", "content": [{"text": "hello"}]},
    ]
    hook.save_support_interaction(fakes.AfterInvocationEvent(_FakeAgent(messages)))


# ── the rubric's cross-session requirement ───────────────────────────────────


def test_cross_session_recall(invoke):
    """
    Two sessions, one customer. Session A states a name and a preference;
    session B — a different session_id, so no shared conversation history —
    must recall both.
    """
    first = invoke("Hi, I am Jane. I prefer concise responses.", session_id="s-A")
    assert "Jane" in first

    second = invoke(
        "Do you remember my name and communication preference?", session_id="s-B"
    )
    assert "Jane" in second
    assert "concise" in second.lower()


def test_memory_does_not_leak_between_customers(invoke):
    invoke("Hi, I am Jane. I prefer concise responses.", customer_id="CUST-123", session_id="a")
    reply = invoke(
        "Do you remember my name?", customer_id="CUST-456", session_id="b"
    )
    assert "Jane" not in reply, "memory is keyed on actor_id and must not cross over"
