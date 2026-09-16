# Architecture

One agent, five AgentCore primitives, one entrypoint.

```
                         agentcore invoke
                                │
                                ▼
                   ┌────────────────────────┐
                   │  BedrockAgentCoreApp   │   main.py, module level
                   │   @app.entrypoint      │   async invoke(payload)
                   └───────────┬────────────┘
                               │
              payload: prompt · customer_id · session_id
                               │
                   ┌───────────▼────────────┐
                   │   Strands Agent        │
                   │   Nova 2 Lite          │
                   │   hooks=[MemoryHook]   │
                   └───────────┬────────────┘
                               │
     ┌──────────────┬──────────┼───────────────┬────────────────┐
     ▼              ▼          ▼               ▼                ▼
┌─────────┐  ┌────────────┐ ┌──────────┐ ┌───────────┐  ┌─────────────┐
│ Gateway │  │ Knowledge  │ │  Memory  │ │   Code    │  │   Browser   │
│  (MCP)  │  │    Base    │ │          │ │Interpreter│  │             │
└────┬────┘  └─────┬──────┘ └────┬─────┘ └─────┬─────┘  └──────┬──────┘
     │             │             │             │               │
  ┌──┴──┐      Retrieve     2 namespaces   executeCode    live page
  │     │       API         per actor      clearContext    fetch
  ▼     ▼          │             │             │
┌────┐ ┌────┐  ┌───▼────┐   ┌────▼─────┐  ┌────▼─────┐
│API │ │λ   │  │OpenSea-│   │SEMANTIC  │  │ sandbox  │
│GW  │ │dir-│  │rch     │   │USER_PREF │  │ python   │
│prox│ │ect │  │Server- │   └──────────┘  └──────────┘
└─┬──┘ └─┬──┘  │less    │
  │      │     └────┬───┘
  ▼      ▼          ▼
order- refund-  product_
tracker proces- catalog
   λ    sor λ     .txt
```

## The entrypoint

`invoke()` does six things, in this order, and the order matters:

1. **Unpack the payload.** `prompt`, `customer_id`, `session_id`. A missing
   session ID gets a fresh UUID — reusing one default would merge unrelated
   conversations into a single history.
2. **Build the memory hook** for this `(actor, session)` pair. Constructing it
   calls `get_namespaces()`, so the namespace templates are read once per
   invocation rather than once per turn.
3. **Instantiate the browser** with the region.
4. **Assemble the local tools** — knowledge base, discount calculator, browser.
5. **Open the Gateway session** and extend the tool list with whatever the
   Gateway advertises. Everything that touches gateway tools happens inside
   the `with` block; the handles are bound to the session.
6. **Run the agent** and return the first content block's text.

## Why the memory hook is a hook

Memory could have been a tool — `remember_this(fact)` — and the model would
call it when it judged something worth remembering. Two reasons it is not:

- **Recall has to happen before the model thinks, not after.** A tool call is
  a decision the model makes *while* answering. By then it has already decided
  it does not know the customer's name. The `MessageAddedEvent` hook runs
  before the model sees the message at all, so the context is simply there.
- **Saving must not be optional.** A model that forgets to call
  `remember_this` produces an agent that silently stops learning. The
  `AfterInvocationEvent` hook fires on every completed turn regardless.

The cost is that every turn pays for two namespace queries whether or not the
message has anything to do with the customer's history. On a support agent
that is the right trade: the queries are cheap and the failure mode they
prevent — an agent that greets a returning customer as a stranger — is the
one customers notice.

## Two Gateway targets, two integration styles

This is the part of the project that teaches the most, because the same MCP
surface is fed by two genuinely different mechanisms:

| | `order-tracker` | `refund-processor` |
|---|---|---|
| Target type | API Gateway REST API stage | Lambda function |
| Lambda receives | a proxy event: `resource`, `httpMethod`, `pathParameters` | the tool arguments directly, as the event |
| Tool name comes from | the `operationName` on each method | the `lambda_schema` file |
| Handler learns which tool | from the `resource` path | from `client_context.custom["bedrockAgentCoreToolName"]` |
| Response shape | `{statusCode, headers, body}` | `{statusCode, body}` |

The consequence for the agent is *nothing* — both arrive as ordinary MCP tools
with names like `order-tracker___get_order`. That is the point of the Gateway:
the integration style is an infrastructure concern, not an agent concern.

## Why the discount is computed in a sandbox

The rules are not hard — 100 points to the dollar, minimum 500, capped at half
the order, then a tier percentage on what remains. A model can *usually* do
that. "Usually" is the problem: the errors are plausible-looking numbers that
no one catches, on a customer's bill.

Writing the rules into a program and executing it moves the arithmetic out of
the model entirely. Two properties follow:

- **Auditable.** The exact program is in the trace. When a customer disputes a
  total, there is something to read.
- **Deterministic.** The same inputs give the same output every time, which is
  what makes `tests/test_loyalty_discount.py` possible at all.

`clearContext=True` on every call means one customer's variables can never
survive into the next customer's calculation.

The fallback path computes the tier discount only, and labels itself
`"fallback": true`. It deliberately does *not* try to redeem points without
the sandbox — a degraded answer that says so beats a confident wrong one.

## Files

```
project/starter/
  main.py                  ★ the deliverable — all 8 TODO sections
  product_catalog.txt        Knowledge Base source, uploaded to S3
  pyproject.toml             dependency manifest (uv)
  lambda/
    order_tracker.py         deployed as-is, behind API Gateway
    refund_processor.py      deployed as-is, direct Lambda target
    lambda_schema            tool schema for the refund target

harness/                   ★ offline stand-ins — see docs/TESTING.md
  fakes.py                   registers stand-in SDKs in sys.modules
  gateway.py                 MCP tools over the REAL Lambda handlers
  kb_index.py                term-overlap retrieval over the real catalog
  memory_store.py            file-backed memory + regex extraction
  scripted_model.py          rule-based planner and composer

scripts/
  run_scenarios.py         ★ runs the six project tests, writes transcripts
  render_screenshots.py      typesets transcripts as PNGs

tests/                     ★ 99 offline tests, no AWS required
cloudshell/
  deploy-e2e-v11.sh              ★ self-contained: deploy + test, one command
  run-all.sh                   infrastructure only, console for KB + Gateway
evidence/run-01/             transcripts, screenshots, traces
```

★ = written for this project. Everything else is the Udacity starter,
unchanged, so the graded files stay byte-identical to what the course ships.
