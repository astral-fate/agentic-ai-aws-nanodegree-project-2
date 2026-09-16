# run-01 — offline harness

Produced by `python -m scripts.run_scenarios` on this machine, with no AWS
account and no credentials. Every scenario prompt is verbatim from the
project instructions, and every reply is checked against that scenario's own
"Expected:" line.

**7/7 scenarios passed · 99/99 offline tests passed**

| # | Scenario | Capability | What the transcript shows |
|---|---|---|---|
| [txt](transcripts/01-order-tracking.txt) · [png](screenshots/01-order-tracking.png) | Test 1 — Order Tracking | Gateway · API Gateway target | `order-tracker___get_order` runs the real Lambda; SHIPPED, TRK987654321, UPS |
| [txt](transcripts/02-refund-processing.txt) · [png](screenshots/02-refund-processing.png) | Test 2 — Refund Processing | Gateway · both targets | order lookup feeds the $139.99 amount into `initiate_refund`; APPROVED, 3-5 business days |
| [txt](transcripts/03-knowledge-base-rag.txt) · [png](screenshots/03-knowledge-base-rag.png) | Test 3 — Knowledge Base (RAG) | Bedrock Knowledge Base | Retrieve over the real product_catalog.txt; Platinum benefits quoted, not paraphrased |
| [txt](transcripts/04a-memory-session-a.txt) · [png](screenshots/04a-memory-session-a.png) | Test 4a — Memory, session A | AgentCore Memory | session s-A; the strategies extract a name and a preference into two namespaces |
| [txt](transcripts/04b-memory-session-b.txt) · [png](screenshots/04b-memory-session-b.png) | Test 4b — Memory, session B | AgentCore Memory | session s-B, same customer; both memories retrieved and injected before the model reads the message |
| [txt](transcripts/05-loyalty-discount.txt) · [png](screenshots/05-loyalty-discount.png) | Test 5 — Loyalty Discount | AgentCore Code Interpreter | the generated program in full, really executed; 4,000 points, 10%, $99.00, 349 remaining |
| [txt](transcripts/06-browser-tool.txt) · [png](screenshots/06-browser-tool.png) | Test 6 — Browser Tool | AgentCore Browser | a real HTTP request to udacity.com, labelled `live-fetch` |

Also here:

| File | What it is |
|---|---|
| [`run_summary.txt`](run_summary.txt) · [png](screenshots/00-run-summary.png) | the pass/fail table |
| [`pytest_output.txt`](pytest_output.txt) · [png](screenshots/07-offline-test-suite.png) | the full offline suite, verbose |
| [`trace.json`](trace.json) | every harness event for every scenario, machine-readable |
| [`memory_state.json`](memory_state.json) | what AgentCore Memory held when the run finished |

## Memory at the end of the run

```
cs_agent/CUST-123/facts
    [SEMANTIC] The customer's name is Jane.
    [SEMANTIC] The customer is a Gold tier member.
cs_agent/CUST-123/preferences
    [USER_PREFERENCE] The customer prefers concise responses (communication preference).
```

7 events recorded across the seven invocations — one per turn,
which is what `save_support_interaction` firing on `AfterInvocationEvent`
should produce.

## Scope

The Lambda handlers and the discount arithmetic really execute. Tool
**routing** is rule-based rather than Nova 2 Lite, so this run establishes
that the wiring is correct and not that the model behaves. See
[`docs/TESTING.md`](../../docs/TESTING.md).

