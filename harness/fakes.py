"""
Offline stand-ins for the AgentCore and Strands SDKs.

``main.py`` imports nine things that only exist inside AWS. This module builds
importable stand-ins for all of them and registers them in ``sys.modules``
*before* ``main.py`` is imported, so the deliverable runs unmodified, on a
laptop, with no credentials and no network.

The point is not to pretend AWS is present. It is to make every line of
``main.py`` execute — the hook registration, the namespace formatting, the
argument marshalling, the response parsing — so that a wiring bug fails here,
in four seconds, instead of six minutes into a deployment.

Fidelity, per component:

  ============================  ==========================================
  component                     how faithful
  ============================  ==========================================
  Gateway tools                 REAL Lambda handler code (harness/gateway.py)
  Code Interpreter              REAL Python execution, in a subprocess
  Knowledge Base                REAL catalog file, term-overlap retrieval
                                instead of Titan embeddings
  Memory                        REAL namespaces and event flow, regex
                                extraction instead of LLM strategies
  Browser                       REAL HTTP fetch when the network allows,
                                clearly-labelled fixture when it does not
  Nova 2 Lite                   NOT a model — a rule-based planner
                                (harness/scripted_model.py)
  ============================  ==========================================

The bottom row is the one that matters. See docs/TESTING.md.
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import types
import uuid
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

from . import gateway, kb_index, memory_store, scripted_model

# ── Trace ────────────────────────────────────────────────────────────────────


class Trace:
    """Everything that happened during one invocation, for the transcripts."""

    def __init__(self):
        self.entries: List[Dict[str, Any]] = []

    def add(self, kind: str, **fields):
        self.entries.append({"kind": kind, **fields})

    def reset(self):
        self.entries.clear()

    def of_kind(self, kind: str) -> List[Dict[str, Any]]:
        return [e for e in self.entries if e["kind"] == kind]


TRACE = Trace()


# ── strands: @tool ───────────────────────────────────────────────────────────


def tool(fn: Callable) -> Callable:
    """
    Stand-in for ``strands.tool``.

    Attaches the name and the docstring-derived description that Strands sends
    to the model as the tool description, then returns the function unchanged
    so it stays directly callable and directly testable.
    """
    fn.tool_name = fn.__name__
    fn.tool_spec = {
        "name": fn.__name__,
        "description": (fn.__doc__ or "").strip(),
        "inputSchema": {"json": {"type": "object", "properties": {}}},
    }
    fn.is_tool = True
    return fn


def _tool_name(obj: Any) -> str:
    return getattr(obj, "tool_name", None) or getattr(obj, "__name__", repr(obj))


# ── strands.hooks ────────────────────────────────────────────────────────────


class HookProvider:
    """Base class for hook providers."""

    def register_hooks(self, registry: "HookRegistry") -> None:
        raise NotImplementedError


class MessageAddedEvent:
    """Fired every time a message is appended to the conversation."""

    def __init__(self, agent):
        self.agent = agent


class AfterInvocationEvent:
    """Fired once the agent has produced its final response."""

    def __init__(self, agent):
        self.agent = agent


class HookRegistry:
    """Maps event classes to the callbacks registered for them."""

    def __init__(self):
        self._callbacks: Dict[type, List[Callable]] = {}

    def add_callback(self, event_type: type, callback: Callable) -> None:
        self._callbacks.setdefault(event_type, []).append(callback)

    def fire(self, event) -> None:
        for callback in self._callbacks.get(type(event), []):
            callback(event)

    def registered(self, event_type: type) -> List[Callable]:
        return list(self._callbacks.get(event_type, []))


# ── strands.models ───────────────────────────────────────────────────────────


class BedrockModel:
    """Records the model ID. Planning is done by harness.scripted_model."""

    def __init__(self, model_id: str = "", **kwargs):
        self.model_id = model_id
        self.config = kwargs

    def __repr__(self) -> str:
        return f"<BedrockModel {self.model_id}>"


# ── strands: Agent ───────────────────────────────────────────────────────────


class AgentResult:
    def __init__(self, message: Dict):
        self.message = message

    @property
    def text(self) -> str:
        return self.message["content"][0]["text"]

    def __str__(self) -> str:
        return self.text


class Agent:
    """
    A deterministic agent loop with the same shape as the Strands one.

    Sequence per invocation, matching Strands's ordering because the memory
    hook depends on it:

      1. append the user message  → fires MessageAddedEvent (memory injects here)
      2. plan tool calls from the *post-injection* message text
      3. for each call: append a toolUse message, run the tool, append the
         toolResult message  → each append fires MessageAddedEvent
      4. append the assistant's reply
      5. fire AfterInvocationEvent (memory persists here)
    """

    def __init__(
        self,
        model=None,
        tools: Optional[List] = None,
        hooks: Optional[List] = None,
        system_prompt: str = "",
        **kwargs,
    ):
        self.model = model
        self.system_prompt = system_prompt
        self.messages: List[Dict] = []
        self.tools: Dict[str, Any] = {_tool_name(t): t for t in (tools or [])}
        self.hooks = HookRegistry()
        self.hook_providers = list(hooks or [])

        for provider in self.hook_providers:
            provider.register_hooks(self.hooks)

        TRACE.add("agent_created", tools=list(self.tools), model=getattr(model, "model_id", None))

    # ── message plumbing ─────────────────────────────────────────────────────
    def _add(self, message: Dict) -> None:
        self.messages.append(message)
        self.hooks.fire(MessageAddedEvent(agent=self))

    # ── tool argument resolution ─────────────────────────────────────────────
    @staticmethod
    def _resolve(args: Dict, prior: List[Dict]) -> Dict:
        """
        Fill arguments the planner deliberately left open.

        ``initiate_refund`` is planned with ``amount=None`` so the value has to
        come from the preceding order lookup rather than from the planner's
        imagination. If no lookup ran, the argument is dropped and the Lambda's
        own default applies.
        """
        resolved = dict(args)

        if resolved.get("amount") is None and "amount" in resolved:
            total = None
            for result in prior:
                if "get_order" in result["tool"]:
                    try:
                        total = json.loads(result["output"]).get("total")
                    except (json.JSONDecodeError, TypeError, AttributeError):
                        total = None
            if total is not None:
                resolved["amount"] = total
            else:
                resolved.pop("amount")

        if resolved.get("loyalty_points") is None or resolved.get("order_total") is None:
            for result in prior:
                if "get_customer" in result["tool"] and "orders" not in result["tool"]:
                    try:
                        profile = json.loads(result["output"])
                    except (json.JSONDecodeError, TypeError):
                        continue
                    if resolved.get("loyalty_points") is None:
                        resolved["loyalty_points"] = profile.get("loyalty_points")
                    if not resolved.get("tier") or resolved.get("tier") == "Silver":
                        resolved["tier"] = profile.get("tier", resolved.get("tier"))

        return {k: v for k, v in resolved.items() if v is not None}

    # ── the loop ─────────────────────────────────────────────────────────────
    async def invoke_async(self, prompt: str) -> AgentResult:
        return self(prompt)

    def __call__(self, prompt: str) -> AgentResult:
        self._add({"role": "user", "content": [{"text": prompt}]})

        # Read back post-hook: the memory hook may have prepended context.
        effective = self.messages[-1]["content"][0]["text"]
        TRACE.add("user_message", raw=prompt, effective=effective)

        calls = scripted_model.plan(effective, self.tools)
        results: List[Dict[str, Any]] = []

        for name, args in calls:
            args = self._resolve(args, results)
            tool_use_id = f"tooluse_{uuid.uuid4().hex[:12]}"

            self._add(
                {
                    "role": "assistant",
                    "content": [
                        {"toolUse": {"toolUseId": tool_use_id, "name": name, "input": args}}
                    ],
                }
            )

            try:
                output = self.tools[name](**args)
                status = "success"
            except Exception as exc:  # a tool failure is data, not a crash
                output = json.dumps({"error": f"{type(exc).__name__}: {exc}"})
                status = "error"

            TRACE.add("tool_call", tool=name, arguments=args, output=output, status=status)
            results.append({"tool": name, "arguments": args, "output": output})

            self._add(
                {
                    "role": "user",
                    "content": [
                        {
                            "toolResult": {
                                "toolUseId": tool_use_id,
                                "content": [{"text": str(output)}],
                                "status": status,
                            }
                        }
                    ],
                }
            )

        text = scripted_model.compose(effective, results)
        self._add({"role": "assistant", "content": [{"text": text}]})

        self.hooks.fire(AfterInvocationEvent(agent=self))
        TRACE.add("assistant_message", text=text)

        return AgentResult({"role": "assistant", "content": [{"text": text}]})


# ── strands.tools.mcp.mcp_client ─────────────────────────────────────────────


def streamable_http_client(url: str, **kwargs):
    """Stand-in for the MCP streamable-HTTP transport factory."""
    return {"transport": "streamable_http", "url": url}


class MCPClient:
    """
    Stand-in for the Strands MCP client.

    Reproduces the one behaviour that actually bites in real use: tool handles
    are bound to the session. Calling ``list_tools_sync`` outside the ``with``
    block raises, exactly as it does against a live Gateway.
    """

    def __init__(self, transport_factory: Callable):
        self.transport_factory = transport_factory
        self.transport = None
        self.entered = False
        self.url = None

    def __enter__(self):
        self.transport = self.transport_factory()
        self.url = (self.transport or {}).get("url")
        self.entered = True
        TRACE.add("gateway_connected", url=self.url)
        return self

    def __exit__(self, exc_type, exc, tb):
        self.entered = False
        TRACE.add("gateway_disconnected", url=self.url)
        return False

    def list_tools_sync(self) -> List[gateway.GatewayTool]:
        if not self.entered:
            raise RuntimeError(
                "MCPClient session is not active — call list_tools_sync() "
                "inside the `with` block."
            )
        tools = gateway.load_tools()
        TRACE.add("gateway_tools_loaded", tools=[t.tool_name for t in tools])
        return tools


# ── bedrock_agentcore.runtime ────────────────────────────────────────────────


class BedrockAgentCoreApp:
    """Stand-in for the AgentCore ASGI app."""

    def __init__(self, **kwargs):
        self.handler: Optional[Callable] = None
        self.config = kwargs

    def entrypoint(self, fn: Callable) -> Callable:
        self.handler = fn
        fn.is_entrypoint = True
        return fn

    def run(self, *args, **kwargs):
        raise RuntimeError(
            "app.run() starts the AgentCore ASGI server and needs the real "
            "runtime. Offline, invoke the entrypoint directly:\n"
            "  python -m scripts.run_scenarios"
        )


# ── bedrock_agentcore.memory ─────────────────────────────────────────────────


class MemoryClient:
    """Stand-in for the AgentCore MemoryClient, backed by harness.memory_store."""

    def __init__(self, region_name: str = "us-east-1", **kwargs):
        self.region_name = region_name

    def get_memory_strategies(self, memory_id: str) -> List[Dict]:
        return memory_store.get_memory_strategies(memory_id)

    def retrieve_memories(self, memory_id, namespace, query, top_k=5, **kwargs):
        found = memory_store.retrieve_memories(memory_id, namespace, query, top_k)
        TRACE.add(
            "memory_retrieve",
            namespace=namespace,
            query=query,
            hits=[m["content"]["text"] for m in found],
        )
        return found

    def create_event(self, memory_id, actor_id, session_id, messages, **kwargs):
        result = memory_store.create_event(memory_id, actor_id, session_id, messages)
        TRACE.add(
            "memory_save",
            actor_id=actor_id,
            session_id=session_id,
            event_id=result["eventId"],
            extracted=result["extracted"],
        )
        return result


# ── bedrock_agentcore.tools.code_interpreter_client ──────────────────────────


class _CodeSession:
    """
    Stand-in for an AgentCore Code Interpreter session.

    The code really is executed — in a separate Python process, with no
    inherited globals, which is the local analogue of ``clearContext=True``.
    That means the arithmetic in the transcripts is genuinely computed by the
    generated program, not asserted by the harness.
    """

    def __init__(self, region: str):
        self.region = region
        self.session_id = f"ci-{uuid.uuid4().hex[:10]}"

    def invoke(self, action: str, payload: Dict) -> Dict:
        if action != "executeCode":
            raise ValueError(f"Unsupported code interpreter action: {action}")

        code = payload.get("code", "")
        language = payload.get("language", "python")
        if language != "python":
            raise ValueError(f"Unsupported language: {language}")

        TRACE.add(
            "code_interpreter",
            session=self.session_id,
            clear_context=payload.get("clearContext"),
            code=code,
        )

        with tempfile.TemporaryDirectory() as tmp:
            script = Path(tmp) / "calc.py"
            script.write_text(code, encoding="utf-8")
            proc = subprocess.run(
                [sys.executable, str(script)],
                capture_output=True,
                text=True,
                timeout=30,
                cwd=tmp,
            )

        is_error = proc.returncode != 0
        output = proc.stdout if not is_error else (proc.stderr or proc.stdout)

        # Shaped like the real executeCode response: a stream of events, each
        # carrying a result with a content list.
        return {
            "stream": [
                {
                    "result": {
                        "sessionId": self.session_id,
                        "isError": is_error,
                        "content": [{"type": "text", "text": output.strip()}],
                        "structuredContent": {
                            "stdout": proc.stdout.strip(),
                            "stderr": proc.stderr.strip(),
                            "exitCode": proc.returncode,
                            "executionTime": None,
                        },
                    }
                }
            ]
        }


@contextmanager
def code_session(region: str):
    session = _CodeSession(region)
    try:
        yield session
    finally:
        TRACE.add("code_session_closed", session=session.session_id)


# ── strands_tools.browser ────────────────────────────────────────────────────

_BROWSER_FIXTURE = {
    "https://www.udacity.com": "Udacity | Learn the Latest Tech Skills; Advance Your Career",
}


class AgentCoreBrowser:
    """
    Stand-in for the AgentCore Browser tool.

    It attempts a real HTTP request. When the network is unavailable it falls
    back to a recorded title and says so in the returned payload — a screenshot
    of a fabricated page title presented as a live fetch would be a falsified
    record, so the fallback is always labelled.
    """

    def __init__(self, region: str = "us-east-1", **kwargs):
        self.region = region
        self.browser = self._make_tool()

    def _make_tool(self):
        def browser(url: str = "", action: str = "navigate", **kwargs) -> str:
            import re as _re
            import urllib.request

            title = None
            live = False
            detail = None

            try:
                request = urllib.request.Request(
                    url,
                    headers={
                        "User-Agent": (
                            "Mozilla/5.0 (compatible; AgentCoreBrowser/1.0; "
                            "+offline-harness)"
                        )
                    },
                )
                with urllib.request.urlopen(request, timeout=12) as response:
                    html = response.read(200_000).decode("utf-8", errors="replace")
                match = _re.search(r"<title[^>]*>(.*?)</title>", html, _re.S | _re.I)
                if match:
                    title = _re.sub(r"\s+", " ", match.group(1)).strip()
                    live = True
            except Exception as exc:
                detail = f"{type(exc).__name__}: {exc}"

            if title is None:
                key = url.rstrip("/")
                title = _BROWSER_FIXTURE.get(key, "(title unavailable)")

            payload = {
                "url": url,
                "action": action,
                "title": title,
                "source": "live-fetch" if live else "offline-fixture",
            }
            if not live:
                payload["note"] = (
                    "Network unavailable in this environment — title served "
                    "from a recorded fixture, not a live page load."
                )
                if detail:
                    payload["error"] = detail

            TRACE.add("browser", **payload)
            return json.dumps(payload)

        browser.tool_name = "browser"
        browser.tool_spec = {
            "name": "browser",
            "description": (
                "Load a live web page and return its title and content. Use "
                "when the customer supplies a URL or asks about something "
                "outside the product catalog."
            ),
            "inputSchema": {
                "json": {
                    "type": "object",
                    "properties": {"url": {"type": "string"}},
                    "required": ["url"],
                }
            },
        }
        return browser


# ── boto3: bedrock-agent-runtime ─────────────────────────────────────────────


class _FakeBedrockAgentRuntime:
    """Stand-in for the bedrock-agent-runtime client's Retrieve API."""

    def __init__(self, region_name: str = "us-east-1"):
        self.region_name = region_name
        self.meta = types.SimpleNamespace(region_name=region_name)

    def retrieve(self, knowledgeBaseId: str, retrievalQuery: Dict, **kwargs):
        query = retrievalQuery.get("text", "")
        results = kb_index.index().search(query, top_k=5)
        TRACE.add(
            "kb_retrieve",
            knowledge_base_id=knowledgeBaseId,
            query=query,
            hits=len(results),
        )
        return {
            "retrievalResults": results,
            "ResponseMetadata": {"HTTPStatusCode": 200},
        }


# ── Installation ─────────────────────────────────────────────────────────────


def _module(name: str, **attrs) -> types.ModuleType:
    mod = types.ModuleType(name)
    mod.__doc__ = f"Offline harness stand-in for {name}."
    for key, value in attrs.items():
        setattr(mod, key, value)
    return mod


_INSTALLED = False


def install() -> None:
    """
    Register every stand-in in ``sys.modules``.

    Must run before ``main.py`` is imported. Idempotent.
    """
    global _INSTALLED
    if _INSTALLED:
        return

    strands = _module("strands", Agent=Agent, tool=tool)
    strands.__path__ = []  # marks it a package so submodules can be registered

    strands_models = _module("strands.models", BedrockModel=BedrockModel)
    strands_hooks = _module(
        "strands.hooks",
        HookProvider=HookProvider,
        HookRegistry=HookRegistry,
        MessageAddedEvent=MessageAddedEvent,
        AfterInvocationEvent=AfterInvocationEvent,
    )

    strands_tools_pkg = _module("strands.tools")
    strands_tools_pkg.__path__ = []
    strands_mcp_pkg = _module("strands.tools.mcp")
    strands_mcp_pkg.__path__ = []
    strands_mcp_client = _module("strands.tools.mcp.mcp_client", MCPClient=MCPClient)

    mcp_pkg = _module("mcp")
    mcp_pkg.__path__ = []
    mcp_client_pkg = _module("mcp.client")
    mcp_client_pkg.__path__ = []
    mcp_http = _module(
        "mcp.client.streamable_http", streamable_http_client=streamable_http_client
    )

    bac = _module("bedrock_agentcore")
    bac.__path__ = []
    bac_runtime = _module(
        "bedrock_agentcore.runtime", BedrockAgentCoreApp=BedrockAgentCoreApp
    )
    bac_memory = _module("bedrock_agentcore.memory", MemoryClient=MemoryClient)
    bac_tools = _module("bedrock_agentcore.tools")
    bac_tools.__path__ = []
    bac_ci = _module(
        "bedrock_agentcore.tools.code_interpreter_client", code_session=code_session
    )

    st = _module("strands_tools")
    st.__path__ = []
    st_browser = _module("strands_tools.browser", AgentCoreBrowser=AgentCoreBrowser)

    sys.modules.update(
        {
            "strands": strands,
            "strands.models": strands_models,
            "strands.hooks": strands_hooks,
            "strands.tools": strands_tools_pkg,
            "strands.tools.mcp": strands_mcp_pkg,
            "strands.tools.mcp.mcp_client": strands_mcp_client,
            "mcp": mcp_pkg,
            "mcp.client": mcp_client_pkg,
            "mcp.client.streamable_http": mcp_http,
            "bedrock_agentcore": bac,
            "bedrock_agentcore.runtime": bac_runtime,
            "bedrock_agentcore.memory": bac_memory,
            "bedrock_agentcore.tools": bac_tools,
            "bedrock_agentcore.tools.code_interpreter_client": bac_ci,
            "strands_tools": st,
            "strands_tools.browser": st_browser,
        }
    )

    # Attach submodules so `from strands.models import X` resolves either way.
    strands.models = strands_models
    strands.hooks = strands_hooks
    strands.tools = strands_tools_pkg
    strands_tools_pkg.mcp = strands_mcp_pkg
    strands_mcp_pkg.mcp_client = strands_mcp_client
    mcp_pkg.client = mcp_client_pkg
    mcp_client_pkg.streamable_http = mcp_http
    bac.runtime = bac_runtime
    bac.memory = bac_memory
    bac.tools = bac_tools
    bac_tools.code_interpreter_client = bac_ci
    st.browser = st_browser

    _patch_boto3()
    _INSTALLED = True


def _patch_boto3() -> None:
    """Route bedrock-agent-runtime clients to the fake; leave the rest alone."""
    import boto3

    if getattr(boto3, "_harness_patched", False):
        return

    real_client = boto3.client

    def patched(service_name: str, *args, **kwargs):
        if service_name == "bedrock-agent-runtime":
            return _FakeBedrockAgentRuntime(
                region_name=kwargs.get("region_name", "us-east-1")
            )
        return real_client(service_name, *args, **kwargs)

    boto3.client = patched
    boto3._harness_patched = True


def load_agent_module():
    """
    Install the stand-ins and import the deliverable.

    Returns the imported ``main`` module, so tests and the scenario runner
    exercise the same file that gets deployed.
    """
    install()

    starter = Path(__file__).resolve().parent.parent / "project" / "starter"
    if str(starter) not in sys.path:
        sys.path.insert(0, str(starter))

    import main  # noqa: E402  (import must follow install())

    return main
