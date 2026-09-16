# Evidence

Each run directory holds one complete pass over the six project test
scenarios, plus everything needed to check the result rather than take it on
trust.

```
run-NN/
  transcripts/          one .txt per scenario — prompt, tool calls, memory
                        activity, the generated program, the reply, the check
  screenshots/          the same transcripts typeset as PNGs
  run_summary.txt       the pass/fail table
  trace.json            every harness event, machine-readable
  memory_state.json     what AgentCore Memory held at the end of the run
  pytest_output.txt     the full offline suite
  INDEX.md              what each artefact shows
```

## Runs

| Run | Mode | Result | Notes |
|---|---|---|---|
| [`run-01`](run-01/) | offline harness | 7/7 scenarios, 99/99 tests | Lambda handlers and discount arithmetic really execute; tool routing is rule-based |

A live run against deployed AWS infrastructure drops into `run-02/` with the
same layout, so the two can be diffed directly. The procedure is
[`docs/RUNBOOK.md`](../docs/RUNBOOK.md) §B.

## Reproducing run-01

```bash
python -m scripts.run_scenarios      # writes transcripts/, run_summary.txt, trace.json
python -m pytest -v > evidence/run-01/pytest_output.txt
python -m scripts.render_screenshots # typesets the transcripts as PNGs
```

Two things will differ from the committed copy, both legitimately:

- **Timestamps and IDs.** Refund IDs are random by design
  (`refund_processor._new_refund_id`), code-interpreter session IDs are
  per-run, and `ORD-001`'s estimated delivery is computed as *two days from
  now* by the Lambda itself.
- **The browser result.** The tool makes a real HTTP request. With network
  access the transcript reads `live-fetch` and shows whatever title
  udacity.com is currently serving; without it, `offline-fixture` and a note
  saying so. The committed run is `live-fetch`.

Everything else — tracking numbers, order totals, every figure in the discount
breakdown, the memory namespaces — is deterministic and should match exactly.

## How to read the transcripts

The prefix on each line says which subsystem produced it:

| Prefix | Meaning |
|---|---|
| `$ agentcore invoke` | the exact payload the scenario sent |
| `[gateway]` | MCP session opened, tools advertised |
| `[tool]` | one tool call: name, arguments, raw result |
| `[memory]` | namespace queries, what came back, what got injected, what was saved |
| `[kb]` | a Retrieve call and how many chunks it matched |
| `[sandbox]` | the Code Interpreter session and the full generated program |
| `[browser]` | the URL and whether the fetch was live |
| `AGENT REPLY` | what the customer would see |
| `RESULT:` | the reply checked against the project's own "Expected:" line |

## What this evidence does not establish

The transcripts show the wiring is correct. They do not show that Nova 2 Lite
routes correctly, because tool selection here is a rule-based planner rather
than a model. [`docs/TESTING.md`](../docs/TESTING.md) draws that line
precisely; it is worth reading before citing any of this as proof that the
agent behaves.
