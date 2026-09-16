# Reflection

**A design decision: memory as a hook, not a tool.**
The obvious way to give an agent memory is a `remember_this(fact)` tool and
let the model decide when to call it. I implemented `MemoryHook` as a
`HookProvider` instead, registered on `MessageAddedEvent` and
`AfterInvocationEvent`. The reason is timing. A tool call is a decision the
model makes *while* answering — by then it has already concluded it does not
know the customer's name. The `MessageAddedEvent` hook runs before the model
sees the message at all, so the context is simply present in the prompt. The
same argument applies in reverse for saving: a model that forgets to call
`remember_this` produces an agent that silently stops learning, whereas the
`AfterInvocationEvent` hook fires on every completed turn. The cost is two
namespace queries per turn regardless of relevance. For a support agent that
is the right trade — the queries are cheap, and the failure they prevent,
greeting a returning customer as a stranger, is the one customers notice.

**A challenge: a tool name that was a prefix of another.**
My tool lookup resolved names by substring, so `get_customer` matched
`order-tracker___get_customer_orders` — whichever was registered first won.
"What tier am I on?" returned an order list. Nothing errored; the agent simply
answered a question nobody asked, which is why it took a written test to catch
rather than a stack trace. The fix was to match exact and prefix-stripped
names across every registered tool *before* falling back to substring
matching. The Gateway flattens two very different integration styles into one
`TargetName___toolName` namespace, and collisions there are silent.

**A production consideration: cost, specifically OpenSearch Serverless.**
Bedrock invocations are metered per token and scale with traffic, which is
intuitive. The OpenSearch Serverless collection behind the Knowledge Base is
not — it bills by OCU-hour whether or not a single query arrives. A project
left running over a weekend spends more on an idle vector store than on every
model call it ever made. Concretely, that shaped the teardown order in the
runbook: OpenSearch collection first, then the Knowledge Base, then everything
else. In production the same fact argues for one shared collection across
agents rather than one per Knowledge Base, and for an alarm on OCU hours
rather than on invocation count — the bill that surprises you is the one for
capacity nothing is using.

*(391 words)*
