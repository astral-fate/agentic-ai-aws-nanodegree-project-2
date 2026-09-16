"""
Offline stand-in for AgentCore Memory.

The real service does two things this module has to imitate:

  1. stores raw events keyed on ``(memory_id, actor_id, session_id)``
  2. runs *extraction strategies* over those events asynchronously — a
     SEMANTIC strategy mines durable facts, a USER_PREFERENCE strategy mines
     stated preferences — and files each extraction into a namespace

Step 2 is why the project instructions tell you to wait 30 seconds between the
two memory sessions: extraction is an LLM job that runs after the turn.

Here, extraction is a handful of regexes and it runs synchronously. That is the
significant difference, and it cuts a specific way:

  proven    the hook writes every turn through ``create_event``, reads back
            through ``retrieve_memories`` on the right namespaces, tags each
            result with its strategy type, and injects it into the next
            session's prompt — the wiring the rubric asks about
  not proven  that the real extraction strategies mine the same facts from
            free-form conversation. "I am Jane" is easy; "everyone just calls
            me Jane" is a sentence these regexes will miss and an LLM will not.

State lives in a JSON file so two separate CLI invocations — two separate
processes, exactly like two ``agentcore invoke`` calls — share it. That is what
makes the cross-session recall demo real rather than a single process
remembering its own variable.
"""

from __future__ import annotations

import json
import os
import re
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List

_DEFAULT_STATE = (
    Path(__file__).resolve().parent.parent / ".harness-state" / "memory.json"
)

_LOCK = threading.Lock()


def state_path() -> Path:
    """Where memory is persisted. Override with HARNESS_MEMORY_PATH."""
    return Path(os.environ.get("HARNESS_MEMORY_PATH", str(_DEFAULT_STATE)))


# ── Strategy configuration ───────────────────────────────────────────────────
# Mirrors the two strategies the project asks you to create in the console.

STRATEGIES = [
    {
        "strategyId": "customer_facts",
        "name": "customer_facts",
        "type": "SEMANTIC",
        "namespaceTemplates": ["cs_agent/{actorId}/facts"],
    },
    {
        "strategyId": "customer_preferences",
        "name": "customer_preferences",
        "type": "USER_PREFERENCE",
        "namespaceTemplates": ["cs_agent/{actorId}/preferences"],
    },
]


# ── Extraction ───────────────────────────────────────────────────────────────

# The lead-in is matched case-insensitively with a scoped (?i:...) group, but
# the captured name stays case-sensitive. A plain re.I flag would make [A-Z]
# match lowercase too, and "I am trying to return this" would file a customer
# named Trying.
_NAME_PATTERNS = [
    re.compile(r"(?i:\bmy name is)\s+([A-Z][a-zA-Z'\-]+)"),
    re.compile(r"(?i:\bi am)\s+([A-Z][a-zA-Z'\-]+)\b"),
    re.compile(r"(?i:\bi'?m)\s+([A-Z][a-zA-Z'\-]+)\b"),
    re.compile(r"(?i:\bthis is)\s+([A-Z][a-zA-Z'\-]+)\b"),
]

# Words that follow "I am" but are not names.
_NOT_NAMES = {
    "a", "an", "the", "not", "sorry", "trying", "looking", "having", "still",
    "gold", "silver", "platinum", "waiting", "happy", "unhappy", "here",
}

_PREFERENCE_PATTERNS = [
    re.compile(r"\bi prefer ([^.!?\n]+)", re.I),
    re.compile(r"\bi'd prefer ([^.!?\n]+)", re.I),
    re.compile(r"\bi like ([^.!?\n]+)", re.I),
    re.compile(r"\bplease (?:keep|make) (?:it|things|responses) ([^.!?\n]+)", re.I),
    re.compile(r"\bi want ([^.!?\n]*(?:response|answer|reply|update)[^.!?\n]*)", re.I),
]

_TIER_PATTERN = re.compile(r"\bi(?:'m| am) (?:a )?(silver|gold|platinum)\b", re.I)


def extract_facts(text: str) -> List[str]:
    """Extract durable customer facts — what a SEMANTIC strategy would mine."""
    facts = []

    for pattern in _NAME_PATTERNS:
        match = pattern.search(text)
        if match:
            name = match.group(1).strip()
            if name.lower() not in _NOT_NAMES:
                facts.append(f"The customer's name is {name}.")
                break

    tier = _TIER_PATTERN.search(text)
    if tier:
        facts.append(f"The customer is a {tier.group(1).title()} tier member.")

    return facts


def extract_preferences(text: str) -> List[str]:
    """Extract stated preferences — what a USER_PREFERENCE strategy would mine."""
    preferences = []

    for pattern in _PREFERENCE_PATTERNS:
        match = pattern.search(text)
        if match:
            fragment = match.group(1).strip().rstrip(".,!")
            if fragment and len(fragment) < 120:
                preferences.append(
                    f"The customer prefers {fragment} "
                    f"(communication preference)."
                )
                break

    return preferences


# ── Store ────────────────────────────────────────────────────────────────────

def _load() -> Dict:
    path = state_path()
    if not path.exists():
        return {"events": [], "memories": {}}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {"events": [], "memories": {}}


def _save(state: Dict) -> None:
    path = state_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(state, indent=2), encoding="utf-8")


def reset() -> None:
    """Clear all stored memory. Used between evidence runs and by tests."""
    with _LOCK:
        _save({"events": [], "memories": {}})


def create_event(memory_id, actor_id, session_id, messages) -> Dict:
    """
    Record a turn and run the extraction strategies over it.

    ``messages`` is a list of ``(text, role)`` pairs, matching the real
    ``MemoryClient.create_event`` signature.
    """
    with _LOCK:
        state = _load()

        event_id = f"evt-{len(state['events']) + 1:04d}"
        state["events"].append(
            {
                "eventId": event_id,
                "memoryId": memory_id,
                "actorId": actor_id,
                "sessionId": session_id,
                "messages": [{"text": t, "role": r} for t, r in messages],
                "createdAt": datetime.now(timezone.utc).isoformat(),
            }
        )

        # Only the customer's own words are mined. Extracting from the agent's
        # reply would let the agent's paraphrase become the stored "fact".
        customer_text = " ".join(t for t, r in messages if str(r).upper() == "USER")

        extractions = [("SEMANTIC", f) for f in extract_facts(customer_text)]
        extractions += [
            ("USER_PREFERENCE", p) for p in extract_preferences(customer_text)
        ]

        for strategy_type, text in extractions:
            strategy = next(s for s in STRATEGIES if s["type"] == strategy_type)
            namespace = strategy["namespaceTemplates"][0].replace(
                "{actorId}", actor_id
            )
            bucket = state["memories"].setdefault(f"{memory_id}|{namespace}", [])

            # Idempotent: re-stating the same fact must not duplicate it.
            if not any(m["content"]["text"] == text for m in bucket):
                bucket.append(
                    {
                        "memoryRecordId": f"mem-{len(bucket) + 1:04d}",
                        "content": {"text": text},
                        "namespaces": [namespace],
                        "strategyType": strategy_type,
                        "createdAt": datetime.now(timezone.utc).isoformat(),
                    }
                )

        _save(state)
        return {"eventId": event_id, "extracted": len(extractions)}


def _overlap(query: str, text: str) -> int:
    """Score by shared word stems — a crude stand-in for vector similarity."""

    def stems(s: str) -> set:
        out = set()
        for word in re.findall(r"[a-z]+", s.lower()):
            if len(word) < 3:
                continue
            out.add(word)
            out.add(word[:5])  # "prefers"/"preference" both stem to "prefe"
        return out

    return len(stems(query) & stems(text))


def retrieve_memories(memory_id, namespace, query, top_k=5) -> List[Dict]:
    """
    Return memories from one namespace, most relevant first.

    Anything sharing a stem with the query ranks first; remaining slots are
    filled with the most recent memories. The recency fallback matters — a
    customer asking "what do you know about me?" shares no words with "The
    customer's name is Jane", and a purely lexical match would return nothing
    where real semantic retrieval would return everything.
    """
    with _LOCK:
        state = _load()

    bucket = list(state["memories"].get(f"{memory_id}|{namespace}", []))
    if not bucket:
        return []

    scored = [(_overlap(query, m["content"]["text"]), i, m) for i, m in enumerate(bucket)]
    relevant = sorted(
        [s for s in scored if s[0] > 0], key=lambda s: (-s[0], -s[1])
    )
    recent = sorted([s for s in scored if s[0] == 0], key=lambda s: -s[1])

    ordered = [m for _, _, m in relevant] + [m for _, _, m in recent]
    return ordered[:top_k]


def get_memory_strategies(memory_id) -> List[Dict]:
    """Return the configured strategies, as the real memory resource would."""
    return [dict(s) for s in STRATEGIES]


def all_memories() -> Dict[str, List[Dict]]:
    """Every stored memory, by namespace. Used by the evidence writer."""
    with _LOCK:
        return _load()["memories"]


def all_events() -> List[Dict]:
    """Every recorded event. Used by the evidence writer."""
    with _LOCK:
        return _load()["events"]
