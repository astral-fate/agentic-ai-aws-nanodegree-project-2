"""
Build the self-contained CloudShell deploy script.

    python -m scripts.build_cloudshell_script

Reads `cloudshell/_deploy-e2e.template.sh` and replaces the
`__EMBEDDED_FILES__` marker with quoted heredocs carrying the real contents of
every file the agent needs — `main.py`, both Lambda handlers, the tool schema
and the product catalog. The result, `cloudshell/deploy-e2e-v6.sh`, needs no
clone and no network beyond AWS itself.

Generating it rather than maintaining it by hand is the point: the embedded
copies cannot drift from the repo, because they are re-read on every build and
the build is verified in the test suite.

Heredocs are quoted (`<<'SENTINEL'`) so nothing inside is expanded — `main.py`
is full of `$`, backticks and `{}` that bash would otherwise mangle. Each
sentinel is checked against the file's own content so a collision fails the
build loudly instead of producing a script that silently truncates.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import List, Tuple

ROOT = Path(__file__).resolve().parent.parent
TEMPLATE = ROOT / "cloudshell" / "_deploy-e2e.template.sh"
MARKER = "__EMBEDDED_FILES__"


def version() -> str:
    """Read SCRIPT_VERSION out of the template — it is the single source."""
    match = re.search(
        r'^SCRIPT_VERSION="([^"]+)"', TEMPLATE.read_text(encoding="utf-8"), re.M
    )
    if not match:
        raise SystemExit("FATAL: SCRIPT_VERSION not found in the template")
    return match.group(1)


def output_path() -> Path:
    """
    Versioned filename, e.g. deploy-e2e-v6.sh.

    The version is in the name because the script is uploaded to CloudShell by
    hand as well as curl'd. Two files differing only by content, sitting in the
    same directory, is how a stale copy got run once already.
    """
    return ROOT / "cloudshell" / f"deploy-e2e-{version()}.sh"


OUTPUT = output_path()

# (source path, path inside $PROJECT_DIR, heredoc sentinel)
FILES: List[Tuple[str, str, str]] = [
    ("project/starter/main.py", "main.py", "MAIN_PY_EOF"),
    ("project/starter/lambda/order_tracker.py", "lambda/order_tracker.py", "ORDER_TRACKER_EOF"),
    ("project/starter/lambda/refund_processor.py", "lambda/refund_processor.py", "REFUND_PROCESSOR_EOF"),
    ("project/starter/lambda/lambda_schema", "lambda/lambda_schema", "LAMBDA_SCHEMA_EOF"),
    ("project/starter/product_catalog.txt", "product_catalog.txt", "CATALOG_EOF"),
]

INDENT = "  "


def embed(source: Path, dest: str, sentinel: str) -> str:
    """Render one file as an indented, quoted heredoc."""
    content = source.read_text(encoding="utf-8")

    # A line equal to the sentinel would end the heredoc early and the rest of
    # the file would be interpreted as bash. Fail the build rather than ship it.
    for number, line in enumerate(content.splitlines(), start=1):
        if line.strip() == sentinel:
            raise SystemExit(
                f"FATAL: {source} line {number} collides with heredoc sentinel "
                f"{sentinel!r}. Change the sentinel in FILES."
            )

    if not content.endswith("\n"):
        content += "\n"

    # The heredoc body is written unindented (no <<-), because <<- only strips
    # tabs and main.py is space-indented — stripping would corrupt the Python.
    return (
        f"{INDENT}cat > \"$PROJECT_DIR/{dest}\" <<'{sentinel}'\n"
        f"{content}"
        f"{sentinel}\n"
    )


def build() -> str:
    template = TEMPLATE.read_text(encoding="utf-8")
    if MARKER not in template:
        raise SystemExit(f"FATAL: {MARKER} not found in {TEMPLATE}")

    blocks = []
    for source_rel, dest, sentinel in FILES:
        source = ROOT / source_rel
        if not source.exists():
            raise SystemExit(f"FATAL: missing {source}")
        blocks.append(embed(source, dest, sentinel))

    return template.replace(MARKER, "\n".join(blocks))


def main() -> int:
    script = build()
    OUTPUT.write_text(script, encoding="utf-8", newline="\n")
    # Executable bit, for the platforms that honour it.
    OUTPUT.chmod(0o755)

    lines = script.count("\n")
    size_kb = len(script.encode("utf-8")) / 1024
    print(f"wrote {OUTPUT.relative_to(ROOT).as_posix()}  "
          f"({lines:,} lines, {size_kb:.0f} KB, version {version()})")
    print("embedded:")
    for source_rel, dest, _ in FILES:
        n = (ROOT / source_rel).read_text(encoding="utf-8").count("\n")
        print(f"  {dest:<28} {n:>4} lines   from {source_rel}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
