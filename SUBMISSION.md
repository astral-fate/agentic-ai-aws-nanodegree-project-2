# Submission — rubric mapping

Every rubric line, with the code that satisfies it and the evidence that shows
it working. Line numbers are into
[`project/starter/main.py`](project/starter/main.py).

**Read this first:** the transcripts in `evidence/run-01/` come from the
**offline harness**, not from a deployed agent. What that does and does not
establish is set out precisely in [`docs/TESTING.md`](docs/TESTING.md), and
summarised at the bottom of this page. The live procedure that closes the gap
is in [`docs/RUNBOOK.md`](docs/RUNBOOK.md) §B.

---

## Agent Deployment & Tool Integration

### Deploy an AI agent to a cloud runtime

| Requirement | Where | Evidence |
|---|---|---|
| `BedrockAgentCoreApp` instance at module level | [`main.py:53`](project/starter/main.py#L53) | `test_app_is_created_at_module_level`, `test_exactly_one_app_instance` |
| async `invoke` with `@app.entrypoint` | [`main.py:485-486`](project/starter/main.py#L485) | `test_invoke_is_the_registered_entrypoint`, `test_entrypoint_is_async` |
| `app.run()` as the main entry point | [`main.py:563`](project/starter/main.py#L563) | `test_app_run_is_the_main_entry_point` |
| Agent responds to `agentcore invoke` without errors | all six transcripts | [`evidence/run-01/run_summary.txt`](evidence/run-01/run_summary.txt) — 7/7 |

`main.py:557-563` runs `app.run()` with no arguments and the single-invocation
CLI path with a payload argument, so the same file serves the runtime and
local testing.

### Integrate external tools using the Model Context Protocol

| Requirement | Where | Evidence |
|---|---|---|
| Connects to the Gateway with `MCPClient` | [`main.py:524`](project/starter/main.py#L524) | `test_connects_with_mcp_client_and_streamable_http` |
| Loads Gateway tools and adds them to the agent's tool list | [`main.py:526-527`](project/starter/main.py#L526) | `test_gateway_tools_are_loaded_and_added_to_the_agent` |
| At least two distinct Gateway tools invoked — one API target, one Lambda target | — | [Test 2](evidence/run-01/transcripts/02-refund-processing.txt) calls `order-tracker___get_order` **and** `refund-processor___initiate_refund` in one turn; `test_one_turn_uses_both_gateway_targets` |
| Each invocation returns a well-formed response | — | Test 1 → `TRK987654321`; Test 2 → a `REF-` ID with `APPROVED` |

Both Lambda handlers run their **real, unmodified code** in these transcripts
— only the transport is faked. `harness/gateway.py` imports them from
`project/starter/lambda/` and builds the API Gateway proxy event and the
Lambda client context that each expects.

---

## Agent Intelligence

### Retrieval Augmented Generation with a knowledge base

| Requirement | Where | Evidence |
|---|---|---|
| `search_knowledge_base` with `@tool` | [`main.py:270-271`](project/starter/main.py#L270) | `test_is_a_registered_tool` |
| Calls the Retrieve API | [`main.py:293-296`](project/starter/main.py#L293) | `test_calls_the_retrieve_api` |
| Joins chunks into one formatted string | [`main.py:306`](project/starter/main.py#L306) | `test_joins_chunks_with_the_separator` |
| Guard clause when `KB_ID` is unset | [`main.py:286-291`](project/starter/main.py#L286) | `test_guard_clause_when_kb_is_not_configured` (both `""` and `"<kbid>"`) |
| Docstring describes when to call it | [`main.py:272-282`](project/starter/main.py#L272) | `test_docstring_tells_the_model_when_to_call_it` |

[Test 3](evidence/run-01/transcripts/03-knowledge-base-rag.txt) retrieves the
Platinum tier benefits from the real `product_catalog.txt` and quotes them
rather than paraphrasing.

### Cross-session agent memory with retrieval and persistence

| Requirement | Where | Evidence |
|---|---|---|
| `get_namespaces` reading `namespaceTemplates` **or** legacy `namespaces` | [`main.py:98-122`](project/starter/main.py#L98) | `test_reads_the_legacy_namespaces_field`, `test_prefers_namespace_templates_over_legacy` |
| `MemoryHook(HookProvider)` with `register_hooks` | [`main.py:125`](project/starter/main.py#L125), [`:262`](project/starter/main.py#L262) | `test_hook_extends_hook_provider`, `test_register_hooks_wires_both_callbacks` |
| `retrieve_customer_context` queries all namespaces, tags by strategy type, prepends to the message | [`main.py:156-214`](project/starter/main.py#L156) | `test_retrieval_queries_every_namespace`, `test_retrieval_tags_memories_by_strategy_type` |
| `save_support_interaction` extracts the last query/response and calls `create_event()` | [`main.py:216-260`](project/starter/main.py#L216) | `test_save_extracts_the_last_query_and_response` |
| Test log shows cross-session recall | — | [Test 4a](evidence/run-01/transcripts/04a-memory-session-a.txt) → [Test 4b](evidence/run-01/transcripts/04b-memory-session-b.txt) |

Sessions `s-A` and `s-B` share `customer_id=CUST-123` and nothing else. The 4b
transcript shows the two namespaces queried, both memories returned, and the
`Customer Context:` block injected into the prompt before the model reads it.

### Sandboxed code interpreter

| Requirement | Where | Evidence |
|---|---|---|
| `calculate_loyalty_discount` with `@tool` | [`main.py:311-312`](project/starter/main.py#L311) | `test_is_a_registered_tool` |
| Self-contained code string with points, tier and earn rules | [`main.py:335-390`](project/starter/main.py#L335) | `test_code_string_encodes_the_business_rules` |
| `code_session(REGION).invoke("executeCode", …)` with `clearContext=True` | [`main.py:394-404`](project/starter/main.py#L394) | `test_executes_with_clear_context`, `test_invokes_execute_code_in_python` |
| Fallback computing tier-only discount | [`main.py:411-441`](project/starter/main.py#L411) | `test_fallback_when_the_sandbox_is_unavailable` |
| Returns `points_redeemed`, `tier_discount_pct`, `final_total`, `remaining_points` | [`main.py:377-389`](project/starter/main.py#L377) | `test_returns_all_four_required_fields` (and again for the fallback) |

[Test 5](evidence/run-01/transcripts/05-loyalty-discount.txt) shows the
generated program in full and the result it computed: 4,000 points redeemed,
10% Gold discount, **$99.00** final, 349 points remaining. Those values are
independently derived by hand in `test_the_projects_own_worked_example`.

### Web browsing

| Requirement | Where | Evidence |
|---|---|---|
| `AgentCoreBrowser` instantiated with the region | [`main.py:512`](project/starter/main.py#L512) | `test_browser_is_instantiated_with_the_region` |
| Added to the agent's tools list | [`main.py:514-518`](project/starter/main.py#L514) | `test_browser_is_added_to_the_tools_list`, `test_browser_tool_is_registered_on_the_agent` |
| Test output shows content retrieved from a live page | — | [Test 6](evidence/run-01/transcripts/06-browser-tool.txt) |

The harness browser performs a **real HTTP request** and labels its result
`live-fetch` or `offline-fixture` in the transcript. The committed run shows
`live-fetch`.

---

## Code Quality & Reflection

| Requirement | Where |
|---|---|
| 200–400 word reflection | [`REFLECTION.md`](REFLECTION.md) — 391 words |
| Names a specific tool/integration and explains an implementation choice | memory as a `HookProvider` rather than a `remember_this` tool, and why the timing matters |
| A concrete challenge and how it was resolved | `get_customer` matching `get_customer_orders` by substring; fixed by exact-and-prefix matching across all tools before any substring fallback |
| A production consideration with a specific example | OpenSearch Serverless billing by OCU-hour while idle, and what that implies for teardown order and alarm choice |

### Submission checklist

- [x] `main.py` complete — no `pass` or `None` placeholders (`test_no_todo_or_placeholder_code_remains` asserts this mechanically)
- [x] Test 1 — Order Tracking · [transcript](evidence/run-01/transcripts/01-order-tracking.txt) · [screenshot](evidence/run-01/screenshots/01-order-tracking.png)
- [x] Test 2 — Refund Processing · [transcript](evidence/run-01/transcripts/02-refund-processing.txt) · [screenshot](evidence/run-01/screenshots/02-refund-processing.png)
- [x] Test 3 — Knowledge Base · [transcript](evidence/run-01/transcripts/03-knowledge-base-rag.txt) · [screenshot](evidence/run-01/screenshots/03-knowledge-base-rag.png)
- [x] Test 4 — Memory, both sessions · [4a](evidence/run-01/transcripts/04a-memory-session-a.txt) · [4b](evidence/run-01/transcripts/04b-memory-session-b.txt)
- [x] Test 5 — Loyalty Discount · [transcript](evidence/run-01/transcripts/05-loyalty-discount.txt) · [screenshot](evidence/run-01/screenshots/05-loyalty-discount.png)
- [x] Test 6 — Browser Tool · [transcript](evidence/run-01/transcripts/06-browser-tool.txt) · [screenshot](evidence/run-01/screenshots/06-browser-tool.png)
- [x] Written reflection · [`REFLECTION.md`](REFLECTION.md)

---

## What is not yet demonstrated

Stated plainly, because a rubric row marked complete on the wrong evidence is
worse than one marked incomplete.

The transcripts show **the wiring is correct**. They do not show **that Nova
2 Lite routes correctly**, because tool selection in the harness is a
rule-based planner (`harness/scripted_model.py`) rather than a model. The
rubric rows that depend on model behaviour rather than code structure —
specifically, whether the agent *chooses* `search_knowledge_base` for a policy
question instead of answering from its own weights — are established by the
live run in [`docs/RUNBOOK.md`](docs/RUNBOOK.md) §B, not by what is committed
here.

Also not exercised offline: IAM, the MCP wire protocol, API Gateway request
validation, Titan embedding retrieval quality, and the asynchronous LLM
extraction strategies behind AgentCore Memory.

`cloudshell/run-all.sh` deploys the infrastructure and prints the six
`agentcore invoke` commands with their expected outputs. Its transcripts use
the same layout as the offline ones, so a live run drops into
`evidence/run-02/` and can be diffed against this one.
