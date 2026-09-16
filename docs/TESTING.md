# What the tests prove, and what they do not

The offline suite runs in about six seconds with no AWS account, no
credentials and no network. That is worth being suspicious of, so this
document says exactly where the boundary is.

```
python -m pytest              # 87 tests
python -m scripts.run_scenarios   # the six project scenarios, with transcripts
```

## The pipeline under test

```
scripts/run_scenarios.py  /  tests/
    └─ main.invoke(payload)              ← REAL, the deployed entrypoint
        ├─ MemoryHook.retrieve_...       ← REAL code, faked backing store
        ├─ MCPClient / gateway tools     ← faked transport
        │   └─ order_tracker.lambda_handler    ← REAL, unmodified
        │   └─ refund_processor.lambda_handler ← REAL, unmodified
        ├─ search_knowledge_base         ← REAL code, faked Retrieve API
        │   └─ product_catalog.txt       ← REAL file, term-overlap ranking
        ├─ calculate_loyalty_discount    ← REAL code
        │   └─ generated program         ← REALLY EXECUTED, in a subprocess
        ├─ browser                       ← REAL HTTP fetch when online
        ├─ tool selection                ← FAKED: rules, not Nova 2 Lite
        └─ MemoryHook.save_...           ← REAL code, faked extraction
```

## Proven offline

- **The entrypoint contract.** `app` exists at module level, `invoke` is
  decorated and async, `app.run()` is the main entry, no placeholder `pass` or
  `= None` survives anywhere in `main.py`.
- **Both Lambda handlers.** Their real code runs. `ORD-001` returns
  `TRK987654321`; `ORD-999` returns a 404 instead of an invented order; the
  refund handler strips the `TargetName___` prefix correctly and approves.
- **Gateway wiring.** Six tools are advertised across the two targets, each
  with a schema; the refund schemas are read from the real `lambda_schema`
  file rather than restated, so an edit there shows up immediately. Tool
  handles are session-bound and raise if used outside the `with` block.
- **Refund amounts are looked up, not invented.** The order lookup is asserted
  to run *before* `initiate_refund`, and the $139.99 total is asserted to be
  what reaches it.
- **RAG plumbing.** The Retrieve call is well-formed, chunks are joined with
  `\n---\n`, empty results produce a descriptive message, a missing `KB_ID`
  short-circuits without calling AWS, and a `retrieve` exception is reported
  rather than raised.
- **Memory, thoroughly.** Both the `namespaceTemplates` and legacy
  `namespaces` API shapes; both callbacks registered on the right events;
  retrieval skipping assistant messages and tool results; memories tagged by
  strategy type; the original query preserved after injection; the last
  query/response pair correctly extracted for `create_event`; failures in
  either direction not breaking the turn; and memory **not** leaking between
  two different `customer_id` values.
- **The discount arithmetic, exactly.** Twelve cases including the project's
  own worked example, the 50%-of-order cap, the 500-point floor, the
  sub-minimum case, all three tiers, all three earn rates, an unknown tier,
  and the fallback path. Expected values are derived by hand from the
  catalog's stated rules — not copied from the program's output, which would
  make the test agree with any bug.
- **Cross-session recall.** Two sessions, one customer, information stored in
  the first and recalled in the second — across separate processes, since the
  store is a file.

## Not proven offline

**Whether Nova 2 Lite routes correctly.** This is the big one. Tool selection
in the harness is `harness/scripted_model.py`: a rule-based planner that
mirrors the guidance in `SYSTEM_PROMPT` by hand. A green run means *the wiring
is correct*, never *the model behaves*. Specifically unanswered:

- Does the model reach for `search_knowledge_base` on a policy question, or
  answer from its own weights? The prompt says not to; whether it complies is
  a live measurement.
- Does it look up the order total before calling `initiate_refund`, or pass a
  number it inferred from the product name?
- Does it use the injected `Customer Context:` block naturally, or read it
  back to the customer verbatim?
- Does it call `calculate_loyalty_discount` at all, or do the arithmetic
  itself because the sum looks easy?

**Whether Titan's embeddings retrieve the same chunks.** The offline index
ranks by term overlap. A semantically obvious query with no shared vocabulary
— "how long do I have to send a laptop back?" — may retrieve here and miss in
OpenSearch, or the reverse.

**Whether the real extraction strategies mine the same facts.** Offline
extraction is a handful of regexes and runs synchronously. The real strategies
are LLM jobs that run after the turn, which is why the live procedure waits 30
seconds between memory sessions. "I am Jane" is easy for both. "Everyone just
calls me Jane" is a sentence the regexes will miss and an LLM will not.

**Anything about AWS itself.** IAM, the MCP wire protocol, API Gateway request
validation, Lambda cold starts, OpenSearch Serverless indexing latency,
throttling, and cost.

## How the open questions get answered

`cloudshell/run-all.sh` deploys the infrastructure and prints the six
`agentcore invoke` commands with their expected outputs. Running them against
the deployed agent is what closes the gap, and the transcripts it produces use
the same layout as the offline ones so the two can be diffed.

The offline suite is not a substitute for that. It is what makes that run
worth doing: by the time it happens, every wiring bug is already fixed, and a
failure genuinely means something about the model.

## Screenshot honesty

`scripts/render_screenshots.py` typesets the transcript files that
`run_scenarios.py` wrote. It does not generate content. If a scenario fails,
its screenshot says `[FAIL]` in red.

The browser tool attempts a real HTTP request and labels its result
`live-fetch` or `offline-fixture` in the payload, which appears in the
transcript. A fabricated page title presented as a live page load would be a
falsified record, so the fallback always says what it is.
