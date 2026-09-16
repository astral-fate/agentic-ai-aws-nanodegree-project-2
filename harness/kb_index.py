"""
Offline stand-in for the Bedrock Knowledge Base Retrieve API.

The real Knowledge Base chunks ``product_catalog.txt``, embeds each chunk with
Titan Embeddings v2, and scores queries by cosine similarity in OpenSearch
Serverless. This module chunks the *same file* and scores by term overlap
instead.

What that does and does not buy you is worth being precise about:

  proven    ``search_knowledge_base`` sends a well-formed Retrieve call, reads
            ``retrievalResults`` correctly, joins the chunks with the right
            separator, and returns text the agent can actually ground on
  not proven  that Titan's embeddings rank these chunks the way term overlap
            does. A semantic near-miss ("how long do I have to send back a
            laptop?") may retrieve here and miss in OpenSearch, or vice versa.

Retrieval *quality* is only answerable against the deployed Knowledge Base.
"""

from __future__ import annotations

import math
import re
from collections import Counter
from pathlib import Path
from typing import Dict, List

CATALOG_PATH = (
    Path(__file__).resolve().parent.parent
    / "project"
    / "starter"
    / "product_catalog.txt"
)

# Words too common in this corpus to carry signal.
_STOPWORDS = {
    "a", "an", "and", "are", "as", "at", "be", "by", "can", "do", "does", "for",
    "from", "has", "have", "how", "i", "in", "is", "it", "me", "my", "of", "on",
    "or", "the", "to", "what", "when", "which", "with", "you", "your", "s",
}


def _tokenise(text: str) -> List[str]:
    return [
        t for t in re.findall(r"[a-z0-9]+", text.lower()) if t not in _STOPWORDS
    ]


def _chunk_catalog(raw: str) -> List[str]:
    """
    Split the catalog on its markdown headings.

    The real ingestion pipeline uses fixed-token chunking; splitting on ``###``
    and ``##`` boundaries keeps each product and each policy section whole,
    which is closer to what a reader would call a useful chunk.
    """
    chunks: List[str] = []
    current: List[str] = []

    def flush(lines: List[str]) -> None:
        if not lines:
            return
        # A chunk that is only a heading — "## Loyalty Rewards Program" with
        # its content living in the ### subsections below it — retrieves as a
        # top hit and then has nothing to ground on. Drop those.
        body = [l for l in lines[1:] if l.strip()]
        if body:
            chunks.append("\n".join(lines).strip())

    for line in raw.splitlines():
        if line.startswith("### ") or line.startswith("## "):
            flush(current)
            current = [line]
        else:
            current.append(line)

    flush(current)
    return [c for c in chunks if c]


class CatalogIndex:
    """A tiny TF-IDF index over the product catalog."""

    def __init__(self, catalog_path: Path = CATALOG_PATH):
        self.catalog_path = catalog_path
        raw = catalog_path.read_text(encoding="utf-8")
        self.chunks = _chunk_catalog(raw)
        self._tokens = [_tokenise(c) for c in self.chunks]

        # Inverse document frequency over the chunk set.
        doc_freq: Counter = Counter()
        for toks in self._tokens:
            doc_freq.update(set(toks))

        n = len(self.chunks)
        self._idf: Dict[str, float] = {
            term: math.log((n + 1) / (df + 1)) + 1.0 for term, df in doc_freq.items()
        }

    def search(self, query: str, top_k: int = 5) -> List[Dict]:
        """
        Return Retrieve-API-shaped results, highest score first.

        The shape matches what ``bedrock-agent-runtime.retrieve`` returns, so
        ``search_knowledge_base`` parses these exactly as it parses AWS's.
        """
        q_tokens = _tokenise(query)
        if not q_tokens:
            return []

        q_counts = Counter(q_tokens)
        scored = []

        for idx, toks in enumerate(self._tokens):
            if not toks:
                continue
            counts = Counter(toks)
            score = 0.0
            for term, q_n in q_counts.items():
                if term in counts:
                    tf = counts[term] / len(toks)
                    score += tf * self._idf.get(term, 1.0) * q_n
            if score > 0:
                scored.append((score, idx))

        scored.sort(key=lambda pair: (-pair[0], pair[1]))

        return [
            {
                "content": {"text": self.chunks[idx]},
                "location": {
                    "type": "S3",
                    "s3Location": {
                        "uri": f"s3://customer-support-kb/{self.catalog_path.name}"
                    },
                },
                "score": round(score, 4),
            }
            for score, idx in scored[:top_k]
        ]


_INDEX: CatalogIndex | None = None


def index() -> CatalogIndex:
    """Return the process-wide catalog index, building it on first use."""
    global _INDEX
    if _INDEX is None:
        _INDEX = CatalogIndex()
    return _INDEX
