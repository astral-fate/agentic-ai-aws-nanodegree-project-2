"""
Shared fixtures for the offline suite.

Every test runs against the real ``project/starter/main.py`` with the AgentCore
and Strands SDKs replaced by ``harness/fakes.py``. No AWS account, no network,
no credentials.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from harness import fakes, gateway, memory_store  # noqa: E402


@pytest.fixture(scope="session")
def agent_module():
    """The deliverable, imported once with the stand-ins installed."""
    return fakes.load_agent_module()


def pytest_configure(config):
    config.addinivalue_line(
        "markers",
        "shared_memory: opt out of per-test memory isolation, for tests whose "
        "whole point is that state survives from one invocation to the next",
    )


@pytest.fixture(autouse=True)
def isolated_memory(request, tmp_path, monkeypatch):
    """
    Give every test its own memory file, so tests cannot leak into each other.

    Tests marked ``shared_memory`` opt out: the cross-session scenarios are two
    halves of one story, and wiping the store between them would test nothing.
    """
    if request.node.get_closest_marker("shared_memory"):
        yield
        return

    monkeypatch.setenv("HARNESS_MEMORY_PATH", str(tmp_path / "memory.json"))
    memory_store.reset()
    yield
    memory_store.reset()


@pytest.fixture(autouse=True)
def clean_trace():
    fakes.TRACE.reset()
    gateway.CALL_LOG.reset()
    yield
    fakes.TRACE.reset()
    gateway.CALL_LOG.reset()


@pytest.fixture
def main_source() -> str:
    """The deliverable's source text, for structural assertions."""
    return (ROOT / "project" / "starter" / "main.py").read_text(encoding="utf-8")


@pytest.fixture
def invoke(agent_module):
    """Call the entrypoint synchronously, the way ``agentcore invoke`` does."""
    import asyncio

    def _invoke(prompt: str, customer_id: str = "CUST-123", session_id: str = "test"):
        return asyncio.run(
            agent_module.invoke(
                {"prompt": prompt, "customer_id": customer_id, "session_id": session_id}
            )
        )

    return _invoke
