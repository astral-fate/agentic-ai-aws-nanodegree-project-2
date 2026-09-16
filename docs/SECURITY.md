# Security notes

Nothing here is novel. It is the set of things this particular project makes
easy to get wrong.

## The `NONE` authorizer

The project instructions specify a Gateway with the `NONE` authorizer, because
the starter code connects without a bearer token or SigV4 signing and adding
either would mean writing authentication code that is not what the project is
teaching.

What that actually means: **anyone who learns the Gateway URL can call your
Lambda functions.** The URL is unguessable, which is not the same as secret —
it will end up in shell history, in `.env`, in a screenshot, in a support
thread.

For this project the blast radius is small: the Lambdas return hard-coded
fixture data and the refund handler writes nothing anywhere. That is the only
reason it is acceptable. A Gateway fronting anything real needs a JWT
authorizer or IAM auth, and the agent needs the code to present a credential.

**Delete the Gateway when the project is graded.** It costs nothing at rest,
which is exactly why it gets forgotten.

## Credentials

`.env` is git-ignored and must stay that way. `.env.example` has the shape with
every value blank.

Use the Udacity Cloud Lab's temporary credentials. They are scoped and they
expire, which is the behaviour you want.

If you find yourself running as the account root — the preflight in
`cloudshell/run-all.sh` warns when it sees a `:root` ARN — stop and make an IAM
user. Root has no permission boundary, its access keys cannot be scoped per
service or rotated per service, and there is no way to limit the damage of a
leak after the fact.

**A key that has been pasted into a chat window, a screenshot, a ticket or a
commit is burned.** Not "probably fine" — rotate it. That includes pasting it
to an AI assistant.

## Configuration in `main.py`

The four config values read environment variables first and fall back to
literals:

```python
GATEWAY_URL = os.environ.get("GATEWAY_URL", "https://customersupportgateway-…/mcp")
KB_ID       = os.environ.get("KB_ID", "ABCDEFGHIJ")
```

The committed literals are **placeholders**, not real resources. This shape
keeps account-specific IDs out of the git history while still satisfying the
rubric's requirement that the values be present and fillable in the file. Set
the real ones in `.env` or in the AgentCore runtime environment.

These IDs are not secrets in the way an access key is, but a Knowledge Base ID
plus a Gateway URL plus an unauthenticated Gateway is enough to be worth not
publishing.

## The code interpreter

`calculate_loyalty_discount` builds a Python program as a string and executes
it. That is a code-injection surface, and it is worth being precise about why
it is not one here.

Every value interpolated into the program goes through a type constructor
first:

```python
loyalty_points   = {int(loyalty_points)}
order_total      = {float(order_total)}
tier             = {json.dumps(str(tier).strip().title())}
product_category = {json.dumps(str(product_category).strip().lower())}
```

`int()` and `float()` raise on anything that is not a number, so those two
cannot carry a payload. The two strings go through `json.dumps`, which emits a
properly quoted and escaped literal — a `tier` argument of `"; import os` ends
up as the harmless string `"; Import Os"`, not as code.

The remaining protection is `clearContext=True`, which means each execution
starts from a clean interpreter. Nothing a previous call defined is visible to
the next one.

If this tool ever grows to interpolate free text — a customer's note, a
product description — the type constructors stop being enough and the values
need to be passed as sandbox *inputs* rather than spliced into source.

## Prompt injection

The agent reads three sources of text it does not control: Knowledge Base
chunks, Gateway tool results, and web pages fetched by the browser tool.

Any of them could contain an instruction aimed at the model. The browser tool
is the widest opening, since it loads whatever URL the customer names.

The system prompt tells the model to report tool results faithfully and to
treat the memory context block as background rather than instruction. That is
mitigation, not prevention. Prompt-level defence is not a boundary, and the
reason it is acceptable here is that the agent has no destructive capability
to be steered into: the refund Lambda returns a fixture, and nothing writes to
a real system.

An agent with a Gateway target that actually moved money would need the
authorisation decision outside the model — a policy check on the tool call,
not an instruction in the prompt.

## PII

The project instructions are explicit: no personal information in the AWS
account provided by the course. No real names, emails or phone numbers in
resource names, tags, test prompts or screenshots.

Note that AgentCore Memory is *designed* to persist customer facts. The test
data uses `CUST-123` and "Jane", both fictional, and the memory resource
carries a 30-day event expiry. Anything typed at this agent during testing is
stored — so type fictional things.
