# run-02 — live AWS

The deployed agent on Amazon Bedrock AgentCore, account `<account-id>`,
`us-east-1`. Produced by `cloudshell/deploy-e2e-v17.sh`, which deploys the
agent and then runs the six project scenarios against it with
`agentcore invoke`.

**5 of 7 passed.** The two failures are real model behaviour, not broken
wiring, and they are the questions `docs/TESTING.md` says the offline
harness cannot answer.

| Scenario | Result | Capability | Notes |
|---|---|---|---|
| [`01-order-tracking`](transcripts-live/01-order-tracking.txt) | ❌ FAIL | Gateway · API target | the agent answered without calling get_order — see the analysis below |
| [`02-refund-processing`](transcripts-live/02-refund-processing.txt) | ❌ FAIL | Gateway · Lambda target | refund approved, but for $0: initiate_refund was called without the order lookup |
| [`03-knowledge-base-rag`](transcripts-live/03-knowledge-base-rag.txt) | ✅ PASS | Bedrock Knowledge Base | Platinum tier benefits retrieved from the synced catalog |
| [`04a-memory-session-a`](transcripts-live/04a-memory-session-a.txt) | ✅ PASS | AgentCore Memory | session s-A stores the name and the preference |
| [`04b-memory-session-b`](transcripts-live/04b-memory-session-b.txt) | ✅ PASS | AgentCore Memory | session s-B, same customer, recalls both — cross-session recall on live AWS |
| [`05-loyalty-discount`](transcripts-live/05-loyalty-discount.txt) | ✅ PASS | Code Interpreter | discount computed in the sandbox |
| [`06-browser-tool`](transcripts-live/06-browser-tool.txt) | ✅ PASS | AgentCore Browser | live page title retrieved |

## The two failures

### Test 1 — the agent answered without looking the order up

Asked to track `ORD-001`, it replied that the order *"is being processed
and is expected to be completed in 2-3 business days"*. The order is
`SHIPPED`, via UPS, tracking `TRK987654321`. No `get_order` call was made;
the status was invented.

### Test 2 — a refund for $0

`initiate_refund` was called without `get_order` first, so no amount was
passed and `refund_processor.py`'s `event.get("amount", 0)` issued the
refund for **$0** instead of $139.99. The reply still said APPROVED and
"3-5 business days", so an earlier, weaker check scored this a pass — the
live check now requires the amount.

Both are the same defect: **Nova 2 Lite answering from its own weights
instead of calling a Gateway tool.** The offline harness cannot surface it,
because its planner always calls the tool — which is exactly the limitation
`docs/TESTING.md` sets out in advance:

> *Does it look up the order total before calling `initiate_refund`, or
> pass a number it inferred from the product name?*

The offline suite has asserted the correct ordering since the first commit
(`test_refund_amount_comes_from_the_order_lookup`). The wiring supports it;
the model does not reliably use it.

## What changed between runs

An earlier run failed test 4b as well, and the cause turned out to be
accumulated state rather than a broken hook: every scenario uses
`customer_id CUST-123`, memory is keyed on the actor, and sixteen runs had
built up 30 records. The injected `Customer Context:` block grew large
enough that the model answered from it — asked about `ORD-001` it described
an `ORD-002` refund from a previous run. Clearing memory before each run
fixed 4b and is worth knowing about: **memory can crowd out tool use.**

## Console screenshots

[`screenshots/`](screenshots/) — six pages captured against the live
console. See that folder's README for what is there and what is not.

