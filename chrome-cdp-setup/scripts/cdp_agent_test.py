"""External-agent CDP smoke test.

Connects to the running Chrome like an independent AI agent would, proves it
can see existing browser state, opens its own tab, manipulates the DOM,
screenshots the result, and disconnects — leaving Chrome running.

Usage:  uv run --with playwright python cdp_agent_test.py [port]
        (no `playwright install` needed — attaches to the running Chrome)
"""
import sys
from pathlib import Path

from playwright.sync_api import sync_playwright

PORT = sys.argv[1] if len(sys.argv) > 1 else "9222"
SHOT = str(Path.cwd() / "cdp_agent_proof.png")

with sync_playwright() as p:
    # connect_over_cdp attaches to every target (tabs, iframes, service workers)
    # and waits for each to answer. A daily-driver profile that has been up for
    # hours with dozens of tabs can exceed Playwright's default 30 s on the
    # first attach; the attempt wakes the idle renderers, so a retry is fast.
    browser = p.chromium.connect_over_cdp(f"http://127.0.0.1:{PORT}", timeout=120_000)
    print(f"[1] connected: Chrome {browser.version}, contexts={len(browser.contexts)}")

    ctx = browser.contexts[0]
    print(f"[2] sees {len(ctx.pages)} existing tab(s) in the real profile:")
    for pg in ctx.pages:
        print(f"      - {pg.url[:70]}")

    page = ctx.new_page()
    page.goto("https://example.com", wait_until="load", timeout=20000)
    print(f"[3] opened own tab -> title: {page.title()!r}")

    page.evaluate(
        """() => {
            document.querySelector('h1').textContent = 'Driven via CDP by an external agent';
            document.querySelector('p').textContent =
                'This heading and paragraph were rewritten over the DevTools Protocol.';
            document.body.style.background = '#0f2a1d';
            document.body.style.color = '#d7f5e3';
        }"""
    )
    print(f"[4] DOM manipulated -> h1 now reads: {page.inner_text('h1')!r}")

    page.screenshot(path=SHOT)
    print(f"[5] screenshot saved: {SHOT}")

    page.close()
    print(f"[6] closed own tab; profile tabs remaining: {len(ctx.pages)}")

print("[7] disconnected cleanly — Chrome left running")
