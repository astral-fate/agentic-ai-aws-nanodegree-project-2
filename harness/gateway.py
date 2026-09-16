"""
Offline stand-in for the AgentCore Gateway.

This is the most faithful part of the harness, because it does not simulate the
thing under test — it calls it. Both Lambda handlers are imported from
``project/starter/lambda/`` and executed as-is, unmodified, exactly as they run
in AWS. What is faked is only the transport in front of them:

  order-tracker      an API Gateway REST proxy integration. The Gateway turns
                     ``get_order(order_id="ORD-001")`` into an HTTP request;
                     API Gateway turns that into a proxy event with
                     ``resource``, ``httpMethod`` and ``pathParameters``. This
                     module builds that event and reads the proxy response.

  refund-processor   a direct Lambda target. The Gateway passes the tool
                     arguments as the event and the tool name in the client
                     context under ``bedrockAgentCoreToolName``, formatted
                     ``TargetName___toolName``. This module builds that too —
                     including the prefix, so the handler's prefix-stripping
                     runs for real.

So order lookups and refunds in the transcripts are produced by the same
Python that AWS would run. What is not exercised: IAM, the MCP wire protocol,
API Gateway's own request validation, and Lambda cold starts.
"""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
from typing import Any, Callable, Dict, List

LAMBDA_DIR = (
    Path(__file__).resolve().parent.parent / "project" / "starter" / "lambda"
)
SCHEMA_PATH = LAMBDA_DIR / "lambda_schema"


def _load_module(name: str, path: Path):
    """Import a Lambda handler file by path, without a package."""
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise ImportError(f"Cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


order_tracker = _load_module("order_tracker", LAMBDA_DIR / "order_tracker.py")
refund_processor = _load_module("refund_processor", LAMBDA_DIR / "refund_processor.py")


# ── order-tracker target (API Gateway REST proxy) ────────────────────────────
# Maps each Gateway operation name to the REST resource it was created against,
# matching the three GET methods from the setup instructions.

_REST_OPERATIONS = {
    "get_order": {
        "resource": "/orders/{order_id}",
        "params": ["order_id"],
        "description": (
            "Get the full status of one order by its ID, including shipping "
            "status, tracking number, carrier and estimated delivery date."
        ),
    },
    "get_customer_orders": {
        "resource": "/customers/{customer_id}/orders",
        "params": ["customer_id"],
        "description": "List every order belonging to a customer.",
    },
    "get_customer": {
        "resource": "/customers/{customer_id}",
        "params": ["customer_id"],
        "description": (
            "Get a customer profile: name, loyalty points balance and tier."
        ),
    },
}


class GatewayCallLog:
    """Records every tool call the agent makes, for the evidence transcripts."""

    def __init__(self):
        self.calls: List[Dict[str, Any]] = []

    def record(self, target: str, tool: str, args: Dict, result: Any) -> None:
        self.calls.append(
            {"target": target, "tool": tool, "arguments": args, "result": result}
        )

    def reset(self) -> None:
        self.calls.clear()


CALL_LOG = GatewayCallLog()


class GatewayTool:
    """
    One MCP tool exposed by the Gateway.

    Callable like a Python function, and carrying the ``tool_name`` /
    ``tool_spec`` attributes that Strands reads when it builds the tool list.
    """

    def __init__(self, name: str, description: str, schema: Dict, fn: Callable):
        self.tool_name = name
        self.tool_spec = {
            "name": name,
            "description": description,
            "inputSchema": {"json": schema},
        }
        self._fn = fn

    # Strands tools expose __name__ in a few places.
    @property
    def __name__(self) -> str:  # noqa: A003
        return self.tool_name

    def __call__(self, **kwargs):
        return self._fn(**kwargs)

    def __repr__(self) -> str:
        return f"<GatewayTool {self.tool_name}>"


def _call_rest_operation(operation: str, **kwargs) -> str:
    """Invoke order_tracker.lambda_handler through a proxy-shaped event."""
    spec = _REST_OPERATIONS[operation]

    path_parameters = {
        key: str(kwargs.get(key, "")) for key in spec["params"]
    }

    event = {
        "resource": spec["resource"],
        "path": spec["resource"],
        "httpMethod": "GET",
        "pathParameters": path_parameters,
        "queryStringParameters": None,
        "headers": {"Accept": "application/json"},
        "body": None,
        "isBase64Encoded": False,
    }

    response = order_tracker.lambda_handler(event, SimpleNamespace(client_context=None))

    # API Gateway hands the Gateway a proxy response; the Gateway forwards the
    # body to the model. A non-200 becomes an error string the model can read.
    body = response.get("body", "{}")
    status = response.get("statusCode", 200)
    if status != 200:
        try:
            detail = json.loads(body).get("error", body)
        except json.JSONDecodeError:
            detail = body
        return json.dumps({"error": detail, "statusCode": status})

    CALL_LOG.record("order-tracker", operation, path_parameters, body)
    return body


def _call_refund_tool(tool: str, **kwargs) -> str:
    """Invoke refund_processor.lambda_handler as a direct Lambda target."""
    event = {k: v for k, v in kwargs.items() if v is not None}

    # The Gateway sets this; the handler splits on "___" to get the bare name.
    context = SimpleNamespace(
        client_context=SimpleNamespace(
            custom={"bedrockAgentCoreToolName": f"refund-processor___{tool}"}
        )
    )

    response = refund_processor.lambda_handler(event, context)
    body = response.get("body", "{}")

    CALL_LOG.record("refund-processor", tool, event, body)
    return body


def _rest_schema(params: List[str]) -> Dict:
    return {
        "type": "object",
        "properties": {
            p: {"type": "string", "description": f"The {p.replace('_', ' ')}"}
            for p in params
        },
        "required": list(params),
    }


def load_tools() -> List[GatewayTool]:
    """
    Return every tool the Gateway would expose, in listing order.

    Three from the API Gateway target plus three from the Lambda target, whose
    schemas are read from the real ``lambda_schema`` file rather than restated
    here — so a schema edit shows up in the harness immediately.
    """
    tools: List[GatewayTool] = []

    for operation, spec in _REST_OPERATIONS.items():
        tools.append(
            GatewayTool(
                name=f"order-tracker___{operation}",
                description=spec["description"],
                schema=_rest_schema(spec["params"]),
                fn=lambda _op=operation, **kw: _call_rest_operation(_op, **kw),
            )
        )

    refund_schemas = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    for entry in refund_schemas:
        tools.append(
            GatewayTool(
                name=f"refund-processor___{entry['name']}",
                description=entry["description"],
                schema=entry["inputSchema"],
                fn=lambda _t=entry["name"], **kw: _call_refund_tool(_t, **kw),
            )
        )

    return tools
