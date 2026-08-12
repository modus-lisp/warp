"""Drive the warp DOM client in a real (headless) Chromium and assert what it actually did.

The point is not that a page loads.  It is that the DOM the browser is holding IS the projection —
same keys, same order, same cells — and that a click travels back as a semantic gesture, reaches the
server, resolves against a presentation, and returns as a delta the client applies.
"""
import json, os, sys
from playwright.sync_api import sync_playwright

PORT = sys.argv[1]
OUT = os.environ.get("WARP_BROWSER_OUT", "/tmp/warp-browser")
os.makedirs(OUT, exist_ok=True)
SHOT = os.path.join(OUT, "warp-dom-client.png")
URL = f"http://127.0.0.1:{PORT}/"
fails = []

def ok(name, cond, detail=""):
    print(f"  {'ok  ' if cond else 'FAIL'} {name}{('   ' + str(detail)) if detail else ''}")
    if not cond:
        fails.append(name)

with sync_playwright() as pw:
    browser = pw.chromium.launch()
    page = browser.new_page(viewport={"width": 900, "height": 720})
    frames = []
    page.on("websocket", lambda ws: ws.on("framereceived",
                                          lambda p: frames.append(p if isinstance(p, str) else p.payload)))
    page.goto(URL)
    page.wait_for_function("window.warp && window.warp.keys().length >= 14", timeout=15000)

    print("== the DOM the browser holds IS the projection ==")
    keys = page.evaluate("warp.keys()")
    ok("the client built one node per row of the server's slice", len(keys) == 14, len(keys))
    ok("in the server's order, keyed by the server's keys",
       keys[:4] == ["aa11bb22cc33", "dd33ee44ff55", "stat00", "stat01"], keys[:4])

    cells = page.evaluate(
        "[...document.querySelectorAll('#rows li')].map(li => "
        "[li.dataset.key, li.querySelector('.v').textContent, li.querySelector('.l').textContent])")
    ok("every row's rendered text is the cells PRESENT produced",
       all(c[1] != "" and c[2] != "" for c in cells))
    ok("and a stat row reads value-then-label, as the view designed it",
       [c for c in cells if c[0] == "stat05"][0][1:] == ["5", "stat05"],
       [c for c in cells if c[0] == "stat05"][0])

    print("== only what changed travelled ==")
    seen = [json.loads(f) for f in frames]
    n_deltas = sum(len(f["deltas"]) for f in seen)
    ok("the first fill arrived as :appeared deltas and nothing else",
       all(d["k"] == "appeared" for f in seen for d in f["deltas"]),
       f"{n_deltas} deltas in {len(seen)} frames")
    ok("each delta carried a key, a container and an anchor, and no rectangle",
       all(("key" in d and "in" in d and "after" in d and "cells" in d)
           for f in seen for d in f["deltas"]))
    ok("the first row's anchor is null; the second's is the first's key",
       [d for f in seen for d in f["deltas"] if d["key"] == "aa11bb22cc33"][0]["after"] is None
       and [d for f in seen for d in f["deltas"] if d["key"] == "stat00"][0]["after"]
           == "dd33ee44ff55")

    print("== a click is a gesture, and the gesture reaches the server ==")
    before = len(frames)
    page.click("li[data-key='stat05']")
    page.wait_for_function(
        "() => document.querySelector(\"li[data-key='stat05']\").className.includes('selected')",
        timeout=8000)
    after = [json.loads(f) for f in frames[before:]]
    changed = [d for f in after for d in f["deltas"] if d["key"] == "stat05"]
    ok("the tap came back as ONE :changed for the row that was tapped",
       len(changed) >= 1 and changed[0]["k"] == "changed", changed[0] if changed else None)
    ok("carrying the selection as view state, not folded into the content",
       changed[0].get("state", {}).get("selected") is True, changed[0].get("state"))
    # scoped to the frame the selection arrived in: the fixture is live and other rows legitimately
    # change on their own clock, which is the point of using a moving fixture
    sel_frame = [f for f in after
                 if any(d["key"] == "stat05" and d["k"] == "changed" for d in f["deltas"])][0]
    # stat03 is the row this fixture ticks on its own clock, so it may legitimately share the pass.
    # Everything else being absent is the claim: selecting a row does not re-send the list.
    collateral = sorted({d["key"] for d in sel_frame["deltas"]} - {"stat05", "stat03"})
    ok("and selecting a row re-sent no OTHER row (bar the one the fixture ticks itself)",
       collateral == [], collateral)
    ok("the browser painted the selection it was told about",
       page.eval_on_selector("li[data-key='stat05']", "el => el.className").find("selected") >= 0)

    print("== hold opens the applicable-command menu, as presentations ==")
    before = len(frames)
    page.evaluate("warp.hold('aa11bb22cc33')")
    page.wait_for_function("warp.menu().length >= 3", timeout=8000)
    menu = page.evaluate(
        "[...document.querySelectorAll('#menu li')].map(li => li.textContent)")
    ok("the menu is three items: the applicable commands, plus cancel",
       len(menu) == 3, menu)
    ok("including the destructive one, which is rendered as destructive",
       page.evaluate("[...document.querySelectorAll('#menu li.destructive')].length") == 1)
    ok("and it arrived through the ordinary delta path, into its own container",
       any(d["in"].startswith("menu:") for f in [json.loads(x) for x in frames[before:]]
           for d in f["deltas"] if "in" in d))

    print("== a GUEST tab: one projection, two consumers, two authorities ==")
    guest = browser.new_page(viewport={"width": 900, "height": 720})
    gframes = []
    guest.on("websocket", lambda ws: ws.on(
        "framereceived", lambda p: gframes.append(p if isinstance(p, str) else p.payload)))
    guest.goto(URL + "?as=device")
    guest.wait_for_function("window.warp && window.warp.keys().length >= 14", timeout=15000)
    ok("the guest sees the same rows, off the same query",
       guest.evaluate("warp.keys()")[:2] == ["aa11bb22cc33", "dd33ee44ff55"])
    guest.evaluate("warp.hold('aa11bb22cc33')")
    guest.wait_for_function("warp.menu().length >= 1", timeout=8000)
    gmenu = guest.evaluate("[...document.querySelectorAll('#menu li')].map(l => l.textContent)")
    ok("but its hold-menu does NOT offer revoke — courtesy filtering, per invoker",
       not any("revoke" in m for m in gmenu), gmenu)

    print("== and a client that sends a command it was never offered is still refused ==")
    guest.evaluate("warp.cmd('revoke-terminal', 'aa11bb22cc33', true)")
    guest.wait_for_timeout(1500)
    ok("the row is still there — invocation is the enforcement point, not the menu",
       "aa11bb22cc33" in guest.evaluate("warp.keys()"))
    ok("and the owner's view was not disturbed by the refusal",
       "aa11bb22cc33" in page.evaluate("warp.keys()"))

    print("== the same command, from the owner, at the same instant, over the same projection ==")
    page.evaluate("warp.cmd('revoke-terminal', 'aa11bb22cc33', true)")
    page.wait_for_function("!warp.keys().includes('aa11bb22cc33')", timeout=8000)
    ok("the owner may, and the row left the owner's DOM as :gone",
       "aa11bb22cc33" not in page.evaluate("warp.keys()"))
    guest.wait_for_function("!warp.keys().includes('aa11bb22cc33')", timeout=8000)
    ok("and the guest was told too — one projection, both streams, no shared memory",
       "aa11bb22cc33" not in guest.evaluate("warp.keys()"))
    ok("as a :gone delta, carrying nothing but the key",
       any(d["k"] == "gone" and d["key"] == "aa11bb22cc33" and "cells" not in d
           for f in [json.loads(x) for x in gframes] for d in f["deltas"]))
    guest.close()

    print("== :moved reorders nodes without re-sending them ==")
    before = len(frames)
    page.evaluate("warp.viewport(14, 2)")
    page.wait_for_timeout(1500)
    after = [json.loads(f) for f in frames[before:]]
    moved = [d for f in after for d in f["deltas"] if d["k"] == "moved"]
    ok("a scroll produced :moved deltas", len(moved) >= 1, f"{len(moved)} moved")
    ok("and a :moved carried NO cells — the node was re-anchored, not rebuilt",
       all("cells" not in d for d in moved))
    # An independent check: rebuild the order the SERVER asserted, from the anchors carried on the
    # wire, and compare it to the order the browser actually rendered.  This is the assertion the
    # forward-anchor bug failed before the client learned to park an unplaceable node — the client
    # had put a row second that the wire said was last.
    def chain_from_wire(all_frames):
        after, alive = {}, set()
        for f in [json.loads(x) for x in all_frames]:
            for d in f["deltas"]:
                if d["k"] == "gone":
                    alive.discard(d["key"]); after.pop(d["key"], None)
                elif d.get("in") == "rows":
                    alive.add(d["key"]); after[d["key"]] = d["after"]
        after = {k: v for k, v in after.items() if k in alive}
        head = [k for k, v in after.items() if v is None]
        if len(head) != 1:
            return None
        nxt = {v: k for k, v in after.items() if v is not None}
        order, cur = [head[0]], head[0]
        while cur in nxt:
            cur = nxt[cur]; order.append(cur)
        return order

    expected = chain_from_wire(frames)
    rendered = page.evaluate("warp.keys()")
    ok("the anchors on the wire describe one unbroken chain", expected is not None
       and len(expected) == len(rendered), f"{len(expected or [])} vs {len(rendered)}")
    ok("and the browser's rendered order IS that chain, node for node",
       expected == rendered, f"\n       wire     {expected}\n       rendered {rendered}")
    ok("with nothing left parked waiting for an anchor that never came",
       page.evaluate("warp.parked()") == [], page.evaluate("warp.parked()"))

    stats = page.evaluate("warp.stats()")
    print(f"     client: {stats}")
    page.screenshot(path=SHOT, full_page=True)
    print("     screenshot: " + SHOT)
    browser.close()

print(f"\n{'ALL BROWSER ASSERTIONS HELD' if not fails else str(len(fails)) + ' FAILED: ' + str(fails)}")
sys.exit(1 if fails else 0)
