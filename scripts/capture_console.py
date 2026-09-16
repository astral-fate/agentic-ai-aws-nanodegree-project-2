#!/usr/bin/env python3
"""
Screenshot the AWS console pages that evidence this project's infrastructure.

    python scripts/capture_console.py --out evidence/run-02/screenshots

These are **real console screenshots**, taken by driving a real Chrome against
the real console. Nothing here renders a console-lookalike page from API data
— a fabricated image passed off as a console screenshot is a falsified record,
so the browser genuinely loads each page, and a page that does not paint is
reported as BLANK rather than filed as evidence.

Signing in
----------
The console needs an interactive login. Two ways to get one:

* **Federated sign-in (default when credentials are available).**
  ``sts:GetFederationToken`` turns an IAM user's keys into a URL that logs a
  browser in with no typing, so the run is headless and unattended.

  The account root **cannot** call GetFederationToken — AWS forbids it — so
  this needs an IAM user. ``cloudshell/create-evidence-user.sh`` creates a
  read-only one and prints its keys; put them in ``.env`` as
  ``EVIDENCE_AWS_ACCESS_KEY_ID`` / ``EVIDENCE_AWS_SECRET_ACCESS_KEY``.

* **Persistent profile.** With no evidence credentials, the first run opens a
  visible Chrome window and waits for you to sign in. The session is saved to
  ``.aws-console-profile/`` (git-ignored), so later runs are automatic.

Why Playwright rather than the browser extension: Playwright drives its own
Chrome, so it needs no per-site permission grant and no already-signed-in
profile.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.parse
import urllib.request
from pathlib import Path

try:
    from playwright.sync_api import TimeoutError as PWTimeout
    from playwright.sync_api import sync_playwright
except ImportError:  # pragma: no cover - dependency guidance
    print(
        "playwright is not installed. Run:\n"
        "  pip install playwright\n"
        "  python -m playwright install chromium",
        file=sys.stderr,
    )
    raise SystemExit(1)

ROOT = Path(__file__).resolve().parent.parent
SIGNIN_HOSTS = ("signin.aws.amazon.com", "signin.aws.com")

# The console shell — nav bar, search, footer — renders immediately and
# contributes roughly this much text. At or below it, the page body has not
# painted: a screenshot taken then is a blank frame under a correct-looking
# header, which is worse than an obvious failure because it looks plausible.
# Raised from 700: the Bedrock console's left navigation alone renders
# ~1000 characters, so a page whose *content pane* never painted still
# cleared the old bar. Per-target `expect` strings below are the real
# check; this is just the floor.
SHELL_TEXT_CHARS = 1200


def console(region: str, path: str) -> str:
    return f"https://{region}.console.aws.amazon.com/{path}"


# ── State written by the deploy script ───────────────────────────────────────

def load_state() -> dict:
    """
    Read resource IDs from DEPLOYED_RESOURCES.txt if it was downloaded, so the
    deep links point at the real resources rather than at list pages.
    """
    state: dict[str, str] = {}
    for candidate in (
        ROOT / "cloudshell" / "cs-agent-submission" / "DEPLOYED_RESOURCES.txt",
        ROOT / "DEPLOYED_RESOURCES.txt",
    ):
        if not candidate.exists():
            continue
        for line in candidate.read_text(encoding="utf-8").splitlines():
            parts = line.split(None, 1)
            if len(parts) != 2:
                continue
            key, value = parts[0].strip(), parts[1].strip()
            if key == "Knowledge" or key == "Base":
                continue
            state.setdefault(key.lower(), value)
        # Named fields, parsed explicitly rather than by position.
        text = candidate.read_text(encoding="utf-8")
        for label, key in (
            ("Knowledge Base", "kb_id"),
            ("Memory", "memory_id"),
            ("REST API", "api_url"),
            ("S3 bucket", "bucket"),
            ("Collection", "collection_arn"),
        ):
            for line in text.splitlines():
                if line.strip().startswith(label):
                    state[key] = line.split(label, 1)[1].strip()
                    break
        break
    return state


def build_targets(region: str, state: dict) -> list[dict]:
    """The console pages that evidence each rubric capability."""
    kb_id = state.get("kb_id", "")
    memory_id = state.get("memory_id", "")
    api_id = (state.get("api_url", "").split("//")[-1].split(".")[0]
              if state.get("api_url") else "")

    targets: list[dict] = [
        {
            "name": "01-agentcore-runtime",
            "url": console(region, f"bedrock-agentcore/home?region={region}#/runtimes"),
            "alt_urls": [
                console(region, f"bedrock-agentcore/home?region={region}#/agents"),
                console(region, f"bedrock-agentcore/home?region={region}#"),
            ],
            "note": "Bedrock → AgentCore → Runtime: the deployed agent.",
            "wait": 12000,
            "expect": "customer_support_agent",
            "attempts": 14,
            "warm_url": console(region, f"bedrock-agentcore/home?region={region}#"),
        },
        {
            "name": "02-agentcore-gateway",
            "url": console(region, f"bedrock-agentcore/home?region={region}#/gateways"),
            "note": "Bedrock → AgentCore → Gateways: CustomerSupportGateway "
                    "and its two targets (API Gateway + Lambda).",
            "wait": 12000,
            "expect": "CustomerSupport",
            "attempts": 12,
            "warm_url": console(region, f"bedrock-agentcore/home?region={region}#"),
        },
        {
            "name": "03-knowledge-base",
            "url": console(
                region,
                f"bedrock/home?region={region}#/knowledge-bases/{kb_id}"
                if kb_id else f"bedrock/home?region={region}#/knowledge-bases",
            ),
            "alt_urls": [console(region, f"bedrock/home?region={region}#/knowledge-bases")],
            "note": "Bedrock → Knowledge Bases → CustomerSupportKB, data source synced.",
            "wait": 12000,
            "expect": "CustomerSupportKB",
            "attempts": 14,
            "warm_url": console(region, f"bedrock/home?region={region}"),
        },
        {
            "name": "04-agentcore-memory",
            "url": console(region, f"bedrock-agentcore/home?region={region}#/memories"),
            "note": "Bedrock → AgentCore → Memory: both strategies and their namespaces.",
            "wait": 12000,
            "expect": "CustomerSupport",
            "attempts": 14,
            "warm_url": console(region, f"bedrock-agentcore/home?region={region}#"),
        },
        {
            "name": "05-lambda-functions",
            "url": console(region, f"lambda/home?region={region}#/functions"),
            "note": "Lambda → order-tracker and refund-processor.",
            "wait": 10000,
            "expect": "order-tracker",
            "attempts": 12,
        },
        {
            "name": "06-api-gateway-resources",
            "url": console(
                region,
                f"apigateway/main/apis/{api_id}/resources?api={api_id}&region={region}"
                if api_id else f"apigateway/main/apis?region={region}",
            ),
            "alt_urls": [console(region, f"apigateway/main/apis?region={region}")],
            "note": "API Gateway → cs-agent-order-api: the three GET methods, "
                    "each carrying the operation name the Gateway exposes as a tool.",
            "wait": 12000,
            "attempts": 12,
        },
        {
            "name": "07-opensearch-collection",
            "url": console(region, f"aos/home?region={region}#opensearch/collections"),
            "note": "OpenSearch Serverless → the vector store behind the Knowledge Base.",
            "wait": 10000,
            "attempts": 10,
            "optional": True,
        },
        {
            "name": "08-s3-bucket",
            "url": (f"https://{region}.console.aws.amazon.com/s3/buckets/"
                    f"{state.get('bucket', '')}?region={region}"
                    if state.get("bucket")
                    else f"https://{region}.console.aws.amazon.com/s3/home?region={region}"),
            "note": "S3 → the Knowledge Base source bucket with product_catalog.txt.",
            "wait": 9000,
            "attempts": 10,
            "optional": True,
        },
        {
            "name": "09-lambda-cloudwatch-logs",
            "url": console(
                region,
                f"cloudwatch/home?region={region}#logsV2:log-groups/log-group/"
                + urllib.parse.quote("/aws/lambda/order-tracker", safe="").replace("%", "$25"),
            ),
            "note": "CloudWatch → the order-tracker log group: real invocations, "
                    "which is stronger evidence than a console test click.",
            "wait": 11000,
            "expect": "order-tracker",
            "attempts": 12,
            "warm_url": console(region, f"cloudwatch/home?region={region}#logsV2:log-groups"),
            "optional": True,
        },
    ]
    return targets


# ── Federated sign-in ────────────────────────────────────────────────────────

def mint_signin_url(region: str, duration: int = 3600) -> str | None:
    """
    Turn EVIDENCE_AWS_* credentials into a console sign-in URL.

    Returns None when no evidence credentials are configured, so the caller
    can fall back to an interactive sign-in.
    """
    access = os.environ.get("EVIDENCE_AWS_ACCESS_KEY_ID", "").strip()
    secret = os.environ.get("EVIDENCE_AWS_SECRET_ACCESS_KEY", "").strip()
    if not access or not secret:
        return None

    try:
        import boto3
        from botocore.exceptions import ClientError
    except ImportError:
        print("boto3 is needed for federated sign-in", file=sys.stderr)
        return None

    sts = boto3.client(
        "sts",
        region_name=region,
        aws_access_key_id=access,
        aws_secret_access_key=secret,
        aws_session_token=None,
    )

    # A federation session's effective permissions are the *intersection* of
    # this policy and the IAM user's own, and that user has ReadOnlyAccess.
    # So "*" here does not grant write access — it declines to narrow further.
    #
    # It cannot be narrowed the obvious way regardless: AWS rejects a wildcard
    # in the service vendor, so "*:Get*" is a MalformedPolicyDocument. Listing
    # every console service explicitly would be a long list that breaks
    # whenever a page loads from a service not on it.
    policy = json.dumps({
        "Version": "2012-10-17",
        "Statement": [{"Effect": "Allow", "Action": "*", "Resource": "*"}],
    })

    try:
        creds = sts.get_federation_token(
            Name="evidence-capture", Policy=policy, DurationSeconds=duration
        )["Credentials"]
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "")
        if "AccessDenied" in code or "not authorized" in str(exc):
            print(
                "GetFederationToken was denied.\n"
                "  The account root cannot call it at all, and an IAM user needs\n"
                "  an explicit sts:GetFederationToken grant.\n"
                "  Run cloudshell/create-evidence-user.sh to set one up.",
                file=sys.stderr,
            )
        else:
            print(f"GetFederationToken failed: {exc}", file=sys.stderr)
        return None

    session = urllib.parse.quote(json.dumps({
        "sessionId": creds["AccessKeyId"],
        "sessionKey": creds["SecretAccessKey"],
        "sessionToken": creds["SessionToken"],
    }))
    with urllib.request.urlopen(
        f"https://signin.aws.amazon.com/federation?Action=getSigninToken&Session={session}",
        timeout=30,
    ) as resp:
        token = json.load(resp)["SigninToken"]

    destination = urllib.parse.quote(
        f"https://{region}.console.aws.amazon.com/console/home?region={region}"
    )
    return ("https://signin.aws.amazon.com/federation?Action=login"
            f"&Issuer=evidence-capture&Destination={destination}&SigninToken={token}")


def load_dotenv(path: Path) -> None:
    """Load .env into the environment without overwriting what is already set."""
    if not path.exists():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip())


# ── Page helpers ─────────────────────────────────────────────────────────────

def dismiss_overlays(page) -> None:
    """
    Close the console's onboarding popover.

    The "Service menu" tooltip renders on top of the content pane and lands in
    every screenshot taken soon after sign-in. Escape closes it; the explicit
    close buttons are tried too because the markup varies by page.
    """
    try:
        page.keyboard.press("Escape")
        for selector in ('button[aria-label="Close"]',
                         'button[data-testid="close-button"]',
                         '[class*="awsui_dismiss"] button'):
            for handle in page.query_selector_all(selector)[:3]:
                try:
                    handle.click(timeout=1200)
                except Exception:  # noqa: BLE001 - best effort only
                    pass
        page.wait_for_timeout(600)
    except Exception:  # noqa: BLE001 - never block a capture on this
        pass


def is_signin(page) -> bool:
    return any(host in page.url for host in SIGNIN_HOSTS)


def settle(page, initial_wait: int, attempts: int = 4, expect: str = "") -> int:
    """
    Wait for the console SPA to actually paint.

    These are single-page apps behind a fragment router: DOMContentLoaded
    fires long before any content exists, so poll the rendered text rather
    than trusting a fixed sleep.
    """
    page.wait_for_timeout(initial_wait)
    try:
        page.wait_for_load_state("networkidle", timeout=20000)
    except PWTimeout:
        pass  # some console pages poll forever and never go idle

    def ready() -> tuple[int, bool]:
        try:
            text = page.evaluate("() => document.body?.innerText || ''")
        except Exception:  # noqa: BLE001 — page may be mid-navigation
            return 0, False
        enough = len(text) > SHELL_TEXT_CHARS
        if expect:
            enough = enough and expect in text
        return len(text), enough

    length, done = ready()
    for _ in range(attempts):
        if done:
            return length
        page.wait_for_timeout(5000)
        length, done = ready()
    return length if done else min(length, SHELL_TEXT_CHARS)


# ── Main ─────────────────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--out", default="evidence/run-02/screenshots")
    parser.add_argument("--region", default="us-east-1")
    parser.add_argument("--profile", default=".aws-console-profile",
                        help="Chrome profile that keeps an interactive login.")
    parser.add_argument("--signin-url", default=None,
                        help="A pre-minted federated sign-in URL.")
    parser.add_argument("--headless", action="store_true")
    parser.add_argument("--login-timeout", type=int, default=300)
    args = parser.parse_args()

    load_dotenv(ROOT / ".env")

    signin_url = args.signin_url or mint_signin_url(args.region)
    headless = args.headless or bool(signin_url)

    state = load_state()
    targets = build_targets(args.region, state)

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    profile = Path(args.profile)
    profile.mkdir(parents=True, exist_ok=True)

    print(f"Capturing {len(targets)} console pages into {out}/")
    print(f"  region  : {args.region}")
    print(f"  sign-in : {'federated (headless)' if signin_url else 'interactive profile'}")
    if state:
        print(f"  targets : resolved from DEPLOYED_RESOURCES.txt")

    captured: list[dict] = []
    failed: list[str] = []
    blank: list[str] = []

    with sync_playwright() as pw:
        try:
            ctx = pw.chromium.launch_persistent_context(
                str(profile.resolve()),
                channel="chrome",
                headless=headless,
                viewport={"width": 1600, "height": 1000},
                args=["--disable-blink-features=AutomationControlled"],
            )
        except Exception as exc:  # noqa: BLE001
            print(f"\nCould not start Chrome: {exc}", file=sys.stderr)
            print("Install Google Chrome, or: python -m playwright install chromium",
                  file=sys.stderr)
            return 1

        page = ctx.pages[0] if ctx.pages else ctx.new_page()

        # ── sign in ──────────────────────────────────────────────────────────
        if signin_url:
            print("\nSigning in with the federated URL...")
            page.goto(signin_url, wait_until="domcontentloaded", timeout=60000)
            page.wait_for_timeout(6000)
            if is_signin(page):
                print("The federated URL did not sign in — it may have expired.",
                      file=sys.stderr)
                ctx.close()
                return 2
            print("  signed in")
        else:
            page.goto(console(args.region, f"console/home?region={args.region}"),
                      wait_until="domcontentloaded", timeout=60000)
            page.wait_for_timeout(4000)
            if is_signin(page):
                if headless:
                    print("\nNot signed in and --headless was requested.\n"
                          "Run once without --headless, or configure "
                          "EVIDENCE_AWS_* in .env.", file=sys.stderr)
                    ctx.close()
                    return 2
                print("\n" + "=" * 62)
                print("  Sign in to AWS in the Chrome window that just opened.")
                print("  This happens ONCE — the session is saved to")
                print(f"  {profile}, so later runs are automatic.")
                print(f"  Waiting up to {args.login_timeout}s...")
                print("=" * 62)
                try:
                    page.wait_for_url(
                        lambda url: not any(h in url for h in SIGNIN_HOSTS),
                        timeout=args.login_timeout * 1000,
                    )
                    page.wait_for_timeout(5000)
                    print("  signed in")
                except PWTimeout:
                    print("\nTimed out waiting for sign-in.", file=sys.stderr)
                    ctx.close()
                    return 2

        # ── capture ──────────────────────────────────────────────────────────
        for target in targets:
            name = target["name"]
            print(f"\n  {name}")
            try:
                if target.get("warm_url"):
                    # Prime the service bundle before the fragment route.
                    page.goto(target["warm_url"], wait_until="commit", timeout=90000)
                    settle(page, 7000, attempts=5)

                length = 0
                urls = [target["url"], *target.get("alt_urls", [])]
                for index, url in enumerate(urls):
                    page.goto(url, wait_until="commit", timeout=90000)
                    if is_signin(page):
                        raise RuntimeError("bounced to the sign-in page")
                    length = settle(page, target.get("wait", 8000),
                                    attempts=target.get("attempts", 6),
                                    expect=target.get("expect", ""))
                    if length > SHELL_TEXT_CHARS:
                        break
                    if index + 1 < len(urls):
                        print(f"    blank ({length} chars) — trying the next route")

                dismiss_overlays(page)
                path = out / f"{name}.png"
                page.screenshot(path=str(path), full_page=True)
                size = path.stat().st_size

                if length <= SHELL_TEXT_CHARS:
                    print(f"    BLANK: only {length} chars rendered "
                          f"({size:,} bytes) — not usable as evidence")
                    blank.append(name)
                else:
                    print(f"    saved {path.name} ({size:,} bytes, {length} chars)")
                    captured.append({"name": name, "file": path.name,
                                     "url": page.url, "note": target["note"]})
            except Exception as exc:  # noqa: BLE001
                level = "optional" if target.get("optional") else "FAILED"
                print(f"    {level}: {exc}")
                if not target.get("optional"):
                    failed.append(name)

        ctx.close()

    # ── index ────────────────────────────────────────────────────────────────
    if captured:
        lines = [
            "# Console screenshots",
            "",
            "Captured by `scripts/capture_console.py`, which drives a real Chrome",
            "session against the real AWS console. Pages that did not paint are",
            "reported as BLANK and not listed here.",
            "",
            "| File | Shows | Console location |",
            "|---|---|---|",
        ]
        for item in captured:
            lines.append(f"| `{item['file']}` | {item['note']} | `{item['url']}` |")
        (out / "README.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
        print(f"\n  wrote {out / 'README.md'}")

    print(f"\n{len(captured)} captured, {len(blank)} blank, {len(failed)} failed")
    if blank:
        print("blank:  " + ", ".join(blank), file=sys.stderr)
    if failed:
        print("failed: " + ", ".join(failed), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
