"""
Render the evidence transcripts as terminal screenshots.

    python -m scripts.render_screenshots

The project's submission checklist asks for "screenshots or terminal output"
for each of the six tests. This renders the terminal output that
``scripts/run_scenarios.py`` actually produced into PNGs the README can embed,
so a reader sees the result without cloning the repo.

One thing this deliberately does not do: invent content. It reads the
transcript files on disk and typesets them. Every character in every image came
out of a real run — if a scenario failed, its screenshot says FAIL in red.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import List, Tuple

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

# ── Terminal theme ───────────────────────────────────────────────────────────

BG = (13, 17, 23)            # GitHub dark canvas
CHROME = (22, 27, 34)
BORDER = (48, 54, 61)
FG = (201, 209, 217)
DIM = (125, 133, 144)
GREEN = (63, 185, 80)
RED = (248, 81, 73)
CYAN = (86, 182, 194)
YELLOW = (210, 153, 34)
PURPLE = (188, 140, 255)
BLUE = (88, 166, 255)

FONT_CANDIDATES = [
    r"C:\Windows\Fonts\consola.ttf",
    r"C:\Windows\Fonts\cour.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    "/System/Library/Fonts/Menlo.ttc",
]

FONT_SIZE = 15
LINE_HEIGHT = 21
PAD_X = 22
PAD_Y = 16
CHROME_H = 38
MAX_COLS = 108


def _font(bold: bool = False) -> ImageFont.FreeTypeFont:
    candidates = list(FONT_CANDIDATES)
    if bold:
        candidates.insert(0, r"C:\Windows\Fonts\consolab.ttf")
    for path in candidates:
        if Path(path).exists():
            try:
                return ImageFont.truetype(path, FONT_SIZE)
            except OSError:
                continue
    return ImageFont.load_default()


def colour_for(line: str) -> Tuple[int, int, int]:
    """Pick a colour from the line's own prefix — no per-file special-casing."""
    stripped = line.strip()

    if stripped.startswith("$ "):
        return GREEN
    if stripped.startswith("===") or stripped.startswith("---"):
        return BORDER
    if "[PASS]" in line:
        return GREEN
    if "[FAIL]" in line:
        return RED
    if stripped.startswith("[gateway]") or stripped.startswith("[tool]"):
        return CYAN
    if stripped.startswith("[memory]"):
        return PURPLE
    if stripped.startswith("[sandbox]") or stripped.startswith("[kb]"):
        return YELLOW
    if stripped.startswith("[browser]"):
        return BLUE
    if stripped.startswith("Expected:"):
        return DIM
    if stripped.startswith("#") or stripped.startswith("Capability under test"):
        return DIM
    if stripped in {"AGENT REPLY", "SUMMARY"}:
        return YELLOW
    if line.startswith("            "):
        return DIM
    return FG


def wrap(lines: List[str], width: int = MAX_COLS) -> List[str]:
    """Hard-wrap long lines, keeping the indent so the layout survives."""
    out: List[str] = []
    for line in lines:
        if len(line) <= width:
            out.append(line)
            continue
        indent = " " * (len(line) - len(line.lstrip()) + 2)
        remaining = line
        first = True
        while remaining:
            take = width if first else width - len(indent)
            out.append(("" if first else indent) + remaining[:take])
            remaining = remaining[take:]
            first = False
    return out


def render(text: str, out_path: Path, title: str) -> Path:
    lines = wrap(text.rstrip().splitlines())

    font = _font()
    title_font = _font(bold=True)

    char_w = font.getlength("M") or 9
    width = int(PAD_X * 2 + char_w * MAX_COLS)
    height = CHROME_H + PAD_Y * 2 + LINE_HEIGHT * len(lines)

    image = Image.new("RGB", (width, height), BG)
    draw = ImageDraw.Draw(image)

    # Window chrome: title bar, traffic lights, title.
    draw.rectangle([0, 0, width, CHROME_H], fill=CHROME)
    draw.line([(0, CHROME_H), (width, CHROME_H)], fill=BORDER)
    for index, colour in enumerate([(255, 95, 86), (255, 189, 46), (39, 201, 63)]):
        cx = 20 + index * 19
        draw.ellipse([cx - 6, CHROME_H // 2 - 6, cx + 6, CHROME_H // 2 + 6], fill=colour)
    draw.text((92, CHROME_H // 2 - 8), title, font=title_font, fill=DIM)

    y = CHROME_H + PAD_Y
    for line in lines:
        draw.text((PAD_X, y), line, font=font, fill=colour_for(line))
        y += LINE_HEIGHT

    draw.rectangle([0, 0, width - 1, height - 1], outline=BORDER)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    image.save(out_path, "PNG", optimize=True)
    return out_path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-dir", default=str(ROOT / "evidence" / "run-01"))
    args = parser.parse_args()

    run_dir = Path(args.run_dir)
    transcripts = run_dir / "transcripts"
    screenshots = run_dir / "screenshots"

    if not transcripts.exists():
        print(f"No transcripts in {transcripts}. Run: python -m scripts.run_scenarios")
        return 1

    rendered = []

    for path in sorted(transcripts.glob("*.txt")):
        out = render(
            path.read_text(encoding="utf-8"),
            screenshots / f"{path.stem}.png",
            f"agentcore invoke — {path.stem}",
        )
        rendered.append(out)

    summary = run_dir / "run_summary.txt"
    if summary.exists():
        rendered.append(
            render(
                summary.read_text(encoding="utf-8"),
                screenshots / "00-run-summary.png",
                "python -m scripts.run_scenarios",
            )
        )

    tests = run_dir / "pytest_output.txt"
    if tests.exists():
        rendered.append(
            render(
                tests.read_text(encoding="utf-8"),
                screenshots / "07-offline-test-suite.png",
                "python -m pytest",
            )
        )

    for path in rendered:
        size_kb = path.stat().st_size / 1024
        print(f"  {path.relative_to(ROOT)}  ({size_kb:.0f} KB)")

    print(f"\n{len(rendered)} screenshot(s) written to {screenshots}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
