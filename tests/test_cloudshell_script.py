"""
Guards on the self-contained CloudShell script.

`cloudshell/deploy-e2e-v13.sh` carries a copy of every project file inside it. A
copy is a chance to drift, and a stale `main.py` embedded in a deploy script is
the kind of bug that only shows up after you have paid for an OpenSearch
collection. These tests fail the build if the committed script does not match
what the generator would produce from the current sources.
"""

from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

import pytest

from scripts.build_cloudshell_script import FILES, OUTPUT, TEMPLATE, build

ROOT = Path(__file__).resolve().parent.parent


def test_generated_script_is_committed():
    assert OUTPUT.exists(), "run: python -m scripts.build_cloudshell_script"


def test_committed_script_matches_the_current_sources():
    """The embedded copies are regenerated and compared, so drift fails here."""
    expected = build()
    actual = OUTPUT.read_text(encoding="utf-8")
    assert actual == expected, (
        "cloudshell/deploy-e2e-v13.sh is stale — a source file changed since it was "
        "built. Run: python -m scripts.build_cloudshell_script"
    )


def test_script_has_unix_line_endings():
    """CloudShell is bash; a trailing CR makes every line a 'command not found'."""
    raw = OUTPUT.read_bytes()
    assert b"\r\n" not in raw, "the generated script must use LF endings"


@pytest.mark.skipif(shutil.which("bash") is None, reason="bash not available")
def test_script_is_valid_bash():
    # Passed relative, from the repo root: Git Bash on Windows cannot resolve a
    # native "D:\..." path and reports a misleading "No such file or directory".
    result = subprocess.run(
        ["bash", "-n", OUTPUT.relative_to(ROOT).as_posix()],
        capture_output=True,
        text=True,
        cwd=ROOT,
    )
    assert result.returncode == 0, f"bash -n failed:\n{result.stderr}"


def test_every_project_file_is_embedded():
    script = OUTPUT.read_text(encoding="utf-8")
    for source_rel, dest, sentinel in FILES:
        assert f"<<'{sentinel}'" in script, f"{dest} heredoc missing"
        assert f'cat > "$PROJECT_DIR/{dest}"' in script


def test_embedded_content_is_byte_identical():
    """Extract each heredoc from the script and compare it to its source."""
    script = OUTPUT.read_text(encoding="utf-8")

    for source_rel, dest, sentinel in FILES:
        start = script.index(f"<<'{sentinel}'\n") + len(f"<<'{sentinel}'\n")
        end = script.index(f"\n{sentinel}\n", start) + 1
        embedded = script[start:end]

        original = (ROOT / source_rel).read_text(encoding="utf-8")
        if not original.endswith("\n"):
            # Heredocs always terminate with a newline; adding one to a file
            # that lacks it is the single permitted difference.
            original += "\n"

        assert embedded == original, f"embedded {dest} differs from {source_rel}"


def test_no_source_line_collides_with_its_sentinel():
    """A body line equal to the sentinel would end the heredoc early."""
    for source_rel, _dest, sentinel in FILES:
        for number, line in enumerate(
            (ROOT / source_rel).read_text(encoding="utf-8").splitlines(), start=1
        ):
            assert line.strip() != sentinel, (
                f"{source_rel}:{number} collides with sentinel {sentinel}"
            )


def test_embedded_schema_is_valid_json():
    script = OUTPUT.read_text(encoding="utf-8")
    sentinel = "LAMBDA_SCHEMA_EOF"
    start = script.index(f"<<'{sentinel}'\n") + len(f"<<'{sentinel}'\n")
    end = script.index(f"\n{sentinel}\n", start) + 1

    schema = json.loads(script[start:end])
    assert [t["name"] for t in schema] == [
        "initiate_refund",
        "check_refund_status",
        "get_return_label",
    ]


def test_teardown_removes_opensearch_first():
    """
    The collection is the only resource that bills while idle, so it must be
    deleted before anything that could fail and abort the teardown.
    """
    script = OUTPUT.read_text(encoding="utf-8")
    teardown = script[script.index("teardown() {"):]

    collection = teardown.index("delete-collection")
    for later in ("delete-rest-api", "delete-function", "delete-role"):
        assert collection < teardown.index(later), (
            f"{later} is deleted before the OpenSearch collection"
        )


def test_script_declares_the_cost_warning():
    script = OUTPUT.read_text(encoding="utf-8")
    assert "OpenSearch Serverless" in script
    assert "--teardown" in script
    assert "WHETHER OR NOT ANYTHING" in script, "the idle-billing warning must be prominent"


def test_scenarios_match_the_offline_suite():
    """The live prompts must be the same six the offline runner uses."""
    from scripts.run_scenarios import SCENARIOS

    script = OUTPUT.read_text(encoding="utf-8")
    for scenario in SCENARIOS:
        prompt = scenario["payload"]["prompt"]
        # The script escapes the dollar in the $150 prompt for bash.
        needle = prompt.replace("$150", r"\$150")
        assert needle in script, f"live script is missing the prompt: {prompt}"


def test_template_is_committed_too():
    """The generator is useless without its template."""
    assert TEMPLATE.exists()
