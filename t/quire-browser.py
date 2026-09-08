#!/usr/bin/env python3
"""t/quire-browser.py — the compound document, in a real headless Chromium.

The Lisp test proves the PROTOCOL is right: six kinds, widths 1/2/5, every row resolving
against its declared layout.  This one proves the other half — that a client which was
written for flat lists paints a pivot table when it asks the declared TYPE what the cells
mean instead of testing the third one.

Every assertion is about the DOM the browser actually built.  A screenshot is written too,
but the screenshot is evidence for a human and never the test.
"""
import os, sys
from playwright.sync_api import sync_playwright

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8788
OUT = os.environ.get("WARP_BROWSER_OUT", "/tmp/warp-quire-browser")
os.makedirs(OUT, exist_ok=True)
SHOT = os.path.join(OUT, "quire.png")
URL = f"http://127.0.0.1:{PORT}/"
fails = []

def ok(name, cond, detail=""):
    print(f"  {'ok  ' if cond else 'FAIL'} {name}{('   ' + str(detail)) if detail else ''}")
    if not cond:
        fails.append(name)

with sync_playwright() as pw:
    browser = pw.chromium.launch()
    page = browser.new_page(viewport={"width": 980, "height": 1200})
    page.goto(URL)
    page.wait_for_function("window.warp && window.warp.keys().length > 0", timeout=20000)
    # THE SLICE IS THE BROWSER'S (rule 8), and the reference client asks for 14 rows because
    # that is its default -- not because the window is that size.  Ask for the whole document,
    # which is also the viewport protocol under test.
    page.evaluate("warp.viewport(60, 0)")
    page.wait_for_function("warp.keys().length >= 24", timeout=20000)

    print("== the document the browser built ==")
    keys = page.evaluate("warp.keys()")
    ok("every row of every part arrived", len(keys) >= 24, len(keys))

    # ---- containers: one per part, which is the OpenDoc claim ----------------------
    containers = page.evaluate(
        "[...document.querySelectorAll('#rows .container')].map(e => e.dataset.container)")
    ok("one container per part, not one flat list",
       len([c for c in containers if c.startswith("part:")]) >= 8, containers[:4])

    # ---- the pivot is a real table -------------------------------------------------
    head = page.evaluate(
        "(() => {const li = document.querySelector('#rows li.thead');"
        " return li ? [...li.querySelectorAll('.td')].map(s => s.textContent) : null})()")
    ok("the pivot head rendered as a table head", head is not None, head)
    ok("with a corner, one heading per quarter, and a total",
       head is not None and len(head) == 5 and head[0] == "region" and head[-1] == "total", head)

    row = page.evaluate(
        "(() => {const li = document.querySelector('#rows li.trow:not(.thead)');"
        " return li ? [...li.querySelectorAll('.td')].map(s => s.textContent) : null})()")
    ok("a pivot row rendered five cells, not three", row is not None and len(row) == 5, row)

    # THE CELL CLASSES ARE THE DECLARED NAMES.  This is the whole point: the client knows
    # cell 0 is the label and cell 4 is the total because the TYPE said so, not because it
    # looked at what is in them.
    classes = page.evaluate(
        "(() => {const li = document.querySelector('#rows li.trow:not(.thead)');"
        " return li ? [...li.querySelectorAll('.td')].map(s => s.className) : null})()")
    ok("each cell is painted under its declared name",
       classes == ["td label", "td value", "td value", "td value", "td total"], classes)

    # ---- authored parts render as prose, not as rows -------------------------------
    ok("headings render as headings",
       page.evaluate("document.querySelectorAll('#rows li.heading').length") >= 4)
    ok("prose renders as prose", page.evaluate("document.querySelectorAll('#rows li.prose').length") >= 3)
    ok("the h1 is the document title",
       page.evaluate("document.querySelector('#rows li.heading.h1 .h').textContent")
       == "Quarterly review")

    # ---- and nothing fell through to the old three-cell fallback -------------------
    fellback = page.evaluate(
        "[...document.querySelectorAll('#rows li')].filter(li =>"
        " !li.className || li.className === '' ).length")
    ok("no row fell through to the undeclared fallback", fellback == 0, fellback)

    # ---- chips: the thing that could not be expressed an hour ago ------------------
    # Drill by tapping a row, then check the breadcrumb is INDIVIDUALLY tappable -- which is
    # only true because each chip is its own presentation with its own key.
    # A ROW IN A LIST PART, not the pivot: a pivoted slice is already at its finest grain and
    # its rows carry no drill clause, so tapping one is correctly refused.  Found that by
    # tapping the wrong row first.
    page.evaluate("(() => {const c = document.querySelector("
                  "  '#rows .container[data-container=\"part:channel\"]');"
                  " const li = c.querySelector('li.trow:not(.thead)');"
                  " warp.tap(li.dataset.key)})()")
    page.wait_for_function("document.querySelectorAll('#rows li.chip').length > 0", timeout=10000)
    chips = page.evaluate(
        "[...document.querySelectorAll('#rows li.chip')].map(li => [li.dataset.key,"
        " li.textContent])")
    ok("a chip appeared after drilling", len(chips) >= 1, chips)
    ok("each chip is its own node with its own key",
       len(set(k for k, _ in chips)) == len(chips), [k for k, _ in chips])
    strip = page.evaluate(
        "(() => {const c = document.querySelector('#rows .container[data-container^=\"crumbs:\"]');"
        " return c ? getComputedStyle(c).display : null})()")
    ok("and they sit in a container the client lays out as a row", strip == "flex", strip)

    page.screenshot(path=SHOT, full_page=True)
    print(f"     screenshot: {SHOT}")
    browser.close()

print(f"\n== {'all checks passed' if not fails else str(len(fails)) + ' FAILED'} ==\n")
sys.exit(1 if fails else 0)
