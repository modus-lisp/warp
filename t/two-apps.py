"""t/two-apps.py — the device manager and the file browser, at once, in a real headless Chromium.

WHAT THIS PROVES.  t/panel.py showed one warp app on a phone.  This shows TWO, over ONE link, which
is the thing the file browser needed that did not exist: the gateway had a single `*warp-projection*`
and the client had a `container()` that put everything which was not "rows" into the hold-menu.  So
the assertions here are about the two halves of that:

  * MULTIPLEXING — the device manager's frames still carry no app label and still land in the
    device manager's panel, while the file browser's carry `a:"files"` and land in the other one.
    Neither client applies the other's bytes and neither counts them.
  * NESTING, RENDERED — one .container element per open column, with the right rows inside it, in
    the right order, and the columns themselves in the order the server stated in `cs`.  Rendered,
    not received: every assertion below reads the DOM.
  * AND THE ⊞ MENU THEY ARE NOW BOTH BEHIND — one button on the row, one entry per app, each entry
    opening one known facet.  Never two panels up at once, nothing left in the DOM when the menu
    shuts, and an app that did not answer marked as such BEFORE the next tap rather than after it.

It takes the panels' ACTUAL BYTES out of payload.js — the three stylesheet blocks, the embedded copy
of client.js, and the three wiring blocks, all lifted by their markers rather than retyped — and gives
them the same three things the page around them provides that t/panel.py does:

    warpCh                 a fake RTCDataChannel backed by a WebSocket to demo/serve-both.lisp,
                           created with the SHELL's own line — negotiated, ordered, stream 102 —
                           because in the split client the channel belongs to shell.js and the
                           payload may not make one
    mkToggle / setBtn      the page's own button helpers, transcribed
    diag                   the page's log line, into an array a test can read

NOT exercised here, and worth saying plainly: SCTP, the negotiated stream id, and the gateway's own
app registry.  Those need the gateway, which carries a live session and may not be started.

    python3 t/two-apps.py <port-of-serve-both> <fixture-root>
"""
import json, os, pathlib, sys, zlib, struct, time
from playwright.sync_api import sync_playwright

PORT = sys.argv[1]
ROOT = pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else "/tmp/warp-two-fixture")
OUT = os.environ.get("WARP_BROWSER_OUT", "/tmp/warp-browser")
os.makedirs(OUT, exist_ok=True)
HERE = pathlib.Path(__file__).resolve().parent
JS = pathlib.Path(os.environ.get(
    "WARP_PHONE_PAYLOAD",
    HERE.parent.parent / "webrtc-data" / "demo" / "glass-webrtc" / "payload.js"))

fails = []
def ok(name, cond, detail=""):
    print(f"  {'ok  ' if cond else 'FAIL'} {name}{('   ' + str(detail)) if detail else ''}")
    if not cond:
        fails.append(name)

if not JS.exists():
    print(f"  skip  the phone client is not checked out at {JS}")
    sys.exit(77)

src = JS.read_text()

def between(a, b, keep_markers=False):
    i = src.index(a)
    j = src.index(b, i)
    return src[i:j + len(b)] if keep_markers else src[i + len(a):j]

FILES_CSS_BEGIN = "/* ==== BEGIN the file browser's stylesheet"
MENU_CSS_BEGIN = "/* ==== BEGIN the app menu's stylesheet"
CSS = ("/* --- the warp panel:" + between("/* --- the warp panel:", FILES_CSS_BEGIN)
       + between(FILES_CSS_BEGIN, "/* ==== END the file browser's stylesheet", True)
       + between(MENU_CSS_BEGIN, "/* ==== END the app menu's stylesheet", True))
CLIENT = between("// ==== BEGIN warp/dom/client.js — VERBATIM, checked by warp/t/client-sync.py ====",
                 "// ==== END warp/dom/client.js ====")
# the menu block comes FIRST in the page for the same reason it comes first in payload.js: it holds
# the registry the two app blocks push themselves into.
MENU_WIRING = between("    // ==== BEGIN the app menu — lifted by warp/t/two-apps.py",
                      "    // ==== END the app menu ", keep_markers=True)
WARP_WIRING = between("    // --- ▤ the device manager: warp, on a third data channel",
                      "window.addEventListener('resize', () => { if (warpOn) warp.viewport(warpFit(), 0); });",
                      keep_markers=True)
FILES_WIRING = between("    // ==== BEGIN the file browser — lifted by warp/t/two-apps.py",
                       "    // ==== END the file browser ", keep_markers=True)

SHIM = """
const diagLog = []; window.diagLog = diagLog;
const diag = (m) => diagLog.push(m);
const gGlyph = g => { const s = document.createElement('span'); s.className='gg'; s.textContent=g; return s; };
const mkToggle = (glyph, right, label) => {
  const b = document.createElement('button');
  b.appendChild(gGlyph(glyph)); b.className = 'gbtn'; b.dataset.state = 'off';
  if (label) b.setAttribute('aria-label', label);
  b.style.bottom = '14px'; b.style.right = right + 'px';
  document.body.appendChild(b); return b;
};
const setBtn = (b, state) => { b.dataset.state = state; b.disabled = state === 'disabled'; };
const pc = {
  createDataChannel(name, opts) {
    window.warpChOpts = opts;
    const ws = new WebSocket(WSURL);
    const ch = {
      _ls: {},
      get readyState() { return ws.readyState === 1 ? 'open' : ws.readyState === 0 ? 'connecting' : 'closed'; },
      send(s) { window.sent.push(s); ws.send(s); },
      addEventListener(t, fn) { (ch._ls[t] = ch._ls[t] || []).push(fn); }
    };
    ws.onmessage = e => {
      // A BOX THAT DOES NOT SERVE AN APP IS SILENT ABOUT IT — warp-app returns NIL, mux-receive
      // drops the message, and no frame for that app ever comes back.  window.dropApp is that,
      // at the transport: it is how the harness gets a box which serves the device manager and
      // not the file browser without a second server, and it is the ONLY thing the phone can
      // ever observe, which is the whole reason the menu has to learn by asking.
      if (window.dropApp) { try { if (JSON.parse(e.data).a === window.dropApp) return; } catch (_) {} }
      window.rx.push(e.data); (ch._ls.message || []).forEach(f => f({data: e.data})); };
    ws.onclose = () => (ch._ls.close || []).forEach(f => f({}));
    window.__ws = ws;
    return ch;
  }
};
window.sent = [];
window.rx = [];      // every frame as it arrived, so a test can price one
// shell.js's own line: the payload may not create a data channel, so both apps get this one.
const warpCh = pc.createDataChannel('warp', { ordered: true, negotiated: true, id: 102 });
"""

page_html = f"""<!doctype html>
<meta charset="utf-8">
<title>warp two-app harness</title>
<style>
html,body{{margin:0;height:100%;background:#111}}
.gbtn{{position:fixed;z-index:20;width:52px;height:52px;border-radius:26px;border:0;padding:0;
  background:rgba(0,0,0,.6);color:#cdd6df;font-size:22px;line-height:1}}
.gbtn[data-state="on"]{{color:#7CFC9B}}
{CSS}
</style>
<body>
<script>
const WSURL = {json.dumps("ws://127.0.0.1:" + str(PORT) + "/warp")};
{SHIM}
{CLIENT}
{MENU_WIRING}
{WARP_WIRING}
{FILES_WIRING}
window.T = {{
  // THE MENU IS THE ONLY WAY IN NOW, so the helpers go through it exactly as a thumb would: tap ⊞
  // until the list is up — one tap from the desktop, two if a panel is open, because the first one
  // puts the panel away — then tap the entry.
  menuOn: () => getComputedStyle(document.getElementById('appsMenu')).display !== 'none',
  tapApps: () => document.querySelector('[aria-label="apps"]').click(),
  openMenu: () => {{ for (let i = 0; i < 3 && !T.menuOn(); i++) T.tapApps(); return T.menuOn(); }},
  entries: () => [...document.querySelectorAll('#appsMenu button')]
                   .map(b => [b.dataset.app, b.querySelector('.an').textContent, !!b.disabled,
                              (b.querySelector('.aw') || {{}}).textContent || null]),
  pick: id => {{ T.openMenu();
                 const e = document.querySelector('#appsMenu button[data-app="' + id + '"]');
                 if (!e || e.disabled) return false;
                 e.click(); return true; }},
  openWarp:  () => T.pick('devices'),
  openFiles: () => T.pick('files'),
  // every fixed round button the page put on the row, by what it says it is
  rowBtns: () => [...document.querySelectorAll('button.gbtn')].map(b => b.getAttribute('aria-label')),
  warpVisible:  () => getComputedStyle(document.getElementById('warpPanel')).display,
  filesVisible: () => getComputedStyle(document.getElementById('filesPanel')).display,
  warpRows: () => [...document.querySelectorAll('#warpRows li')].map(li => li.dataset.key),
  // THE DEVICE MANAGER'S PANEL AS A STRING, with the client's own rows and hold-menu left out —
  // those are the server's and change with the fixture's clock.  What is left is the four elements
  // payload.js builds, which a rearrangement of how the panel is REACHED must not touch, and
  // which is compared below against a literal rather than looked at.
  warpSkeleton: () => {{
    const dump = el => el.tagName.toLowerCase() + (el.id ? '#' + el.id : '') +
      (el.id === 'warpRows' || el.id === 'warpMenu'
       ? '' : '(' + [...el.children].map(dump).join(',') + ')');
    return dump(document.getElementById('warpPanel'));
  }},
  // and the shape of a row as the CLIENT built it: its own class, and the cells inside it
  warpRowShapes: () => [...new Set([...document.querySelectorAll('#warpRows > li')].map(
      li => '[' + li.className + ']' + [...li.children].map(s => s.className).join('/')))].sort(),
  warpMenu: () => [...document.querySelectorAll('#warpMenu li')].map(li => li.textContent),
  filesMenu: () => [...document.querySelectorAll('#filesMenu li')].map(li => li.textContent),
  warpNote: () => document.getElementById('warpNote').textContent,
  filesNote: () => document.getElementById('filesNote').textContent,
  // THE RENDERED NESTING, read off the DOM: the container elements in document order, each with
  // the keys of the rows actually inside it.
  cols: () => [...document.querySelectorAll('#filesRows > .container')]
                .map(c => [c.dataset.container, [...c.children].map(li => li.dataset.key)]),
  colText: () => [...document.querySelectorAll('#filesRows > .container')]
                .map(c => [...c.children].map(li => (li.querySelector('.v') || li).textContent)),
  opaque: () => [...document.querySelectorAll('#filesRows .opaque')]
                .map(el => [el.querySelector('.cap').textContent, el.querySelector('.dim').textContent,
                            el.parentNode.dataset.container]),
  // mark every rendered row node, so a later pass can tell "the same element moved" from
  // "a new element was built with the same content"
  mark: () => {{ let i = 0; for (const li of document.querySelectorAll('#filesRows li')) li.dataset.mark = String(i++); }},
  marks: () => [...document.querySelectorAll('#filesRows li')].map(li => [li.dataset.mark, (li.querySelector('.v')||li).textContent]),
  // a real press and release, through the client's own gesture recognizer — down, up inside the
  // hold window, which is what rule 5 calls a tap.  Not client.tap(key): that is the harness door.
  tapText: t => {{ for (const li of document.querySelectorAll('#filesRows li')) {{
                     const v = li.querySelector('.v');
                     if (v && v.textContent === t) {{
                       li.dispatchEvent(new PointerEvent('pointerdown', {{bubbles: true}}));
                       li.dispatchEvent(new PointerEvent('pointerup', {{bubbles: true}}));
                       return li.dataset.key; }} }}
                   return null; }},
  holdText: t => {{ for (const li of document.querySelectorAll('#filesRows li')) {{
                     const v = li.querySelector('.v'); if (v && v.textContent === t) {{ files.hold(li.dataset.key); return li.dataset.key; }} }}
                    return null; }},
  warp: () => warp, files: () => files
}};
</script>
"""

harness = pathlib.Path(OUT) / "warp-two-apps-harness.html"
harness.write_text(page_html)


def png(path, w, h):
    """A real PNG, written by hand, so the box has a genuine image to decode a preview from."""
    rows = []
    for y in range(h):
        row = bytearray(b"\x00")
        for x in range(w):
            row += bytes(((3 * x) % 256, (3 * y) % 256, 200 if (x + y) % 32 < 16 else 60))
        rows.append(bytes(row))
    raw = b"".join(rows)
    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff))
    path.write_bytes(b"\x89PNG\r\n\x1a\n"
                     + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(raw))
                     + chunk(b"IEND", b""))


with sync_playwright() as pw:
    browser = pw.chromium.launch()
    page = browser.new_page(viewport={"width": 390, "height": 780})
    errors = []
    page.on("pageerror", lambda e: errors.append(str(e)))
    page.goto(harness.as_uri())

    print("== two panels, one channel, and nothing sent until one is opened ==")
    ok("the page's own script ran without an error", not errors, errors)
    ok("there is still exactly ONE data channel, negotiated, on stream 102",
       page.evaluate("warpChOpts") == {"ordered": True, "negotiated": True, "id": 102},
       page.evaluate("warpChOpts"))
    ok("both panels are display:none, so both are out of hit-testing",
       page.evaluate("T.warpVisible()") == "none" and page.evaluate("T.filesVisible()") == "none")
    page.wait_for_timeout(700)
    ok("and nothing at all is on the wire", page.evaluate("sent") == [], page.evaluate("sent"))

    print("== the ⊞ menu: one button for the rich apps, and nothing else on the row ==")
    ok("the two apps left NO buttons behind — the row carries the menu button and nothing else",
       page.evaluate("T.rowBtns()") == ["apps"], page.evaluate("T.rowBtns()"))
    ok("and the menu is shut, holding nothing at all",
       not page.evaluate("T.menuOn()") and page.evaluate("T.entries()") == [])
    ok("one tap opens it", page.evaluate("T.openMenu()"))
    entries = page.evaluate("T.entries()")
    ok("with ONE ENTRY PER APP, each naming one known facet — no 'best available' anything",
       [e[0] for e in entries] == ["devices", "files"], entries)
    ok("both are offered, because nothing has been asked yet and silence is the only evidence there is",
       all(e[2] is False for e in entries), entries)
    ok("opening the menu is still not a probe: it puts nothing on the wire",
       page.evaluate("sent") == [], page.evaluate("sent"))
    ok("and it has not opened a panel either",
       page.evaluate("T.warpVisible()") == "none" and page.evaluate("T.filesVisible()") == "none")
    ok("⊞ itself stays above the backdrop, so the button you tapped is still the way out",
       page.evaluate("(b => +getComputedStyle(b).zIndex > "
                     "+getComputedStyle(document.getElementById('appsBackdrop')).zIndex)"
                     "(document.querySelector('[aria-label=\"apps\"]'))"))
    ok("and the backdrop is over everything else, including the debug toggle at 31",
       page.evaluate("+getComputedStyle(document.getElementById('appsBackdrop')).zIndex") > 31)
    ok("the list opens clear of the button that summoned it — nothing under the thumb",
       page.evaluate("(m => m.bottom <= document.querySelector('[aria-label=\"apps\"]')"
                     ".getBoundingClientRect().top)"
                     "(document.getElementById('appsMenu').getBoundingClientRect())"))
    page.evaluate("T.tapApps()")
    ok("a second tap shuts it and takes its entries out of the DOM with it",
       not page.evaluate("T.menuOn()") and page.evaluate("T.entries()") == []
       and page.evaluate("document.querySelector('[aria-label=\"apps\"]').style.zIndex") == "")

    print("== app one: the device manager, exactly as it was, reached through the menu ==")
    ok("the entry opens it", page.evaluate("T.openWarp()"))
    ok("and the menu is gone, so what is on screen is the panel", not page.evaluate("T.menuOn()"))
    page.wait_for_function("T.warpRows().length > 0", timeout=15000)
    sent = [json.loads(s) for s in page.evaluate("sent")]
    # NOT "the first message is a viewport report" but "it is THIS message and has these fields":
    # the whole claim about the menu is that it changed how the panel is reached and nothing about
    # what the panel says, and the first bytes on the channel are where that claim is cheapest to
    # break.  An extra field here would be a different consumer as far as the box is concerned.
    ok("its first message is EXACTLY the viewport report it has always been, unlabelled",
       sorted(sent[0]) == ["rows", "scroll", "t"]
       and sent[0]["t"] == "viewport" and sent[0]["scroll"] == 0 and sent[0]["rows"] >= 3,
       sent[0])
    ok("and it is the ONLY thing opening the panel put on the wire", len(sent) == 1, sent)
    dm_rows = page.evaluate("T.warpRows()")
    ok("its rows are the box's enrolled terminals, in the box's keys",
       dm_rows[:2] == ["aa11bb22cc33", "dd33ee44ff55"], dm_rows[:3])
    ok("and they are flat: the device manager's panel made no containers",
       page.evaluate("document.querySelectorAll('#warpRows .container').length") == 0)
    ok("its client counted only its own frames",
       page.evaluate("T.warp().stats().frames") > 0 and page.evaluate("T.warp().stats().nodes") > 0,
       page.evaluate("T.warp().stats()"))
    ok("the panel is the same four elements it was before the menu existed",
       page.evaluate("T.warpSkeleton()")
       == "div#warpPanel(div#warpHead(b(),span#warpStat()),"
          "div#warpBody(ul#warpRows,ul#warpMenu),div#warpNote())",
       page.evaluate("T.warpSkeleton()"))
    ok("and every row is still an li of .v .l .stale, trended by the class the server sent",
       all(s.endswith("v/l/stale") or s.endswith("v/l")
           for s in page.evaluate("T.warpRowShapes()"))
       and all(s.split("]")[0][1:] in ("", "selected", "warn", "bad",
                                       "selected warn", "selected bad")
               for s in page.evaluate("T.warpRowShapes()")),
       page.evaluate("T.warpRowShapes()"))

    print("== app two: the file browser, on the same channel, reached through the same menu ==")
    ok("its entry opens it", page.evaluate("T.openFiles()"))
    page.wait_for_function("T.cols().length > 0", timeout=15000)
    ok("and the device manager was PUT AWAY — one rich panel at a time, always",
       page.evaluate("T.filesVisible()") == "flex" and page.evaluate("T.warpVisible()") == "none",
       (page.evaluate("T.warpVisible()"), page.evaluate("T.filesVisible()")))
    sent = [json.loads(s) for s in page.evaluate("sent")]
    labelled = [m for m in sent if "a" in m]
    ok("its messages carry the app label, and the device manager's still carry none",
       labelled and all(m["a"] == "files" for m in labelled)
       and len(labelled) < len(sent), (len(labelled), len(sent)))
    cols = page.evaluate("T.cols()")
    ok("ONE CONTAINER, for the one open column, and it is a real element in the DOM",
       len(cols) == 1 and cols[0][0] == "col:" + str(ROOT) + "/", cols)
    text = page.evaluate("T.colText()")
    ok("with the column's own rows inside it — the header first, then the entries",
       text[0][0] == ROOT.name and "alpha.txt" in text[0] and "fix" in text[0], text[0])
    ok("and the device manager's rows were not disturbed by any of it",
       page.evaluate("T.warpRows()") == dm_rows)

    print("== drilling in: a second column, to the RIGHT of the first ==")
    page.evaluate("T.tapText('fix')")
    page.wait_for_function("T.cols().length === 2", timeout=15000)
    cols = page.evaluate("T.cols()")
    ok("two containers now, in the order the server stated in `cs`",
       [c[0] for c in cols] == ["col:" + str(ROOT) + "/", "col:" + str(ROOT) + "/fix/"],
       [c[0] for c in cols])
    text = page.evaluate("T.colText()")
    ok("each holds ITS OWN rows and no others",
       "alpha.txt" in text[0] and "alpha.txt" not in text[1]
       and "gamma.txt" in text[1] and "gamma.txt" not in text[0], text)
    ok("the second column's header is its own directory", text[1][0] == "fix", text[1][0])
    ok("nothing is parked waiting for an anchor that never came",
       page.evaluate("T.files().parked()") == [], page.evaluate("T.files().parked()"))

    print("== a third column, and the columns stay left to right ==")
    page.evaluate("T.tapText('pics')")
    page.wait_for_function("T.cols().length === 3", timeout=15000)
    ok("three containers, in path order — NOT in the order the deltas arrived, which is reversed",
       [c[0] for c in page.evaluate("T.cols()")]
       == ["col:" + str(ROOT) + "/", "col:" + str(ROOT) + "/fix/", "col:" + str(ROOT) + "/fix/pics/"],
       [c[0] for c in page.evaluate("T.cols()")])

    print("== :moved reorders the nodes it already has, and does not rebuild them ==")
    page.evaluate("T.mark()")
    before = page.evaluate("T.marks()")
    (ROOT / "fix" / "aaa-new.txt").write_text("z" * 10)
    page.wait_for_function("T.colText()[1].includes('aaa-new.txt')", timeout=15000)
    after = page.evaluate("T.marks()")
    moved = [m for m in after if m[0] is not None]
    ok("the inserted row is the only node without a mark — every other one is the SAME element",
       len([m for m in after if not m[0]]) == 1, [m[1] for m in after if not m[0]])
    kept = {m[0]: m[1] for m in before}
    ok("and each kept element still holds the content it held — a :moved carries no cells",
       all(kept[m[0]] == m[1] for m in moved if m[0] in kept))
    ok("but the order changed: the new file sorts above them",
       [m[1] for m in before] != [m[1] for m in after])

    print("== the opaque node: pixels this surface cannot have, and the caption it can ==")
    png(ROOT / "fix" / "swatch.png", 320, 200)
    page.wait_for_function("T.colText()[1].includes('swatch.png')", timeout=20000)
    page.evaluate("T.tapText('swatch.png')")
    page.wait_for_function("T.opaque().length === 1", timeout=20000)
    op = page.evaluate("T.opaque()")[0]
    ok("it is drawn as a placeholder, in its own container, not as a row",
       op[2] == "preview", op[2])
    ok("and it is LABELLED with the caption the app supplied", "swatch.png" in op[0], op[0])
    ok("which says what the region is, in words no consumer could derive from pixels",
       "320 x 200" in op[0], op[0])
    # THE ASSERTION IS THAT THE PIXELS ARE NOT THERE, not that the caption is.  A 320x200 image is
    # ~190 KB of RGB and could not hide in a frame this size, and the decoded thumbnail lives on the
    # domain object where only a consumer that can blit will ever reach it.
    pv = None
    for f in page.evaluate("rx"):
        if "fs-preview" not in f:
            continue
        for d in json.loads(f)["deltas"]:
            if d.get("type") == "fs-preview":
                pv = json.dumps(d, separators=(",", ":"), ensure_ascii=False)
    ok("the delta that carried the preview carried NO pixels with it",
       pv and len(pv) < 400 and "data:" not in pv and "base64" not in pv,
       str(len(pv)) + " bytes: " + pv if pv else None)

    print("== a hold in one app does not open a menu in the other ==")
    page.evaluate("T.holdText('alpha.txt')")
    page.wait_for_function("T.filesMenu().length > 0", timeout=8000)
    ok("the file browser's menu opened, in the file browser's panel",
       len(page.evaluate("T.filesMenu()")) >= 2, page.evaluate("T.filesMenu()"))
    ok("and the device manager's menu is untouched", page.evaluate("T.warpMenu()") == [],
       page.evaluate("T.warpMenu()"))
    ok("the device manager's rows are still exactly what they were before any of this",
       page.evaluate("T.warpRows()") == dm_rows)

    print("== closing a column removes its container rather than leaving an empty box ==")
    n = len(page.evaluate("T.cols()"))
    page.evaluate("T.tapText('alpha.txt')")     # a file in column 0: closes columns to its right
    page.wait_for_timeout(1200)
    page.evaluate("T.holdText('fix')")
    page.wait_for_function("T.filesMenu().length > 0", timeout=8000)
    page.evaluate("T.tapText('pics')")          # back down to two columns and out again
    page.wait_for_timeout(1500)
    cols = page.evaluate("T.cols()")
    ok("every container in the DOM still has rows in it — an emptied one is removed",
       all(len(c[1]) > 0 for c in cols), [(c[0], len(c[1])) for c in cols])

    print("== closing returns to the desktop, and leaves nothing behind ==")
    page.evaluate("T.tapApps()")
    page.wait_for_timeout(200)
    ok("one tap puts the panel away and does NOT open the menu in its place",
       page.evaluate("T.warpVisible()") == "none" and page.evaluate("T.filesVisible()") == "none"
       and not page.evaluate("T.menuOn()"))
    ok("the button says so — nothing is up",
       page.evaluate("document.querySelector('[aria-label=\"apps\"]').dataset.state") == "off")
    ok("the row is still one button wide", page.evaluate("T.rowBtns()") == ["apps"],
       page.evaluate("T.rowBtns()"))
    ok("every container the file browser made is still inside its own panel, not loose in the page",
       page.evaluate("[...document.querySelectorAll('.container')]"
                     ".every(c => document.getElementById('filesPanel').contains(c))")
       and page.evaluate("document.querySelectorAll('.container').length") > 0,
       page.evaluate("document.querySelectorAll('.container').length"))
    ok("and the shut menu holds nothing — no entry left where nobody can see it",
       page.evaluate("document.getElementById('appsMenu').children.length") == 0)
    cols_before = page.evaluate("T.cols()")
    ok("reopening the file browser finds the columns it had — closing is not a teardown",
       page.evaluate("T.openFiles()") and page.evaluate("T.cols()") == cols_before,
       page.evaluate("T.cols()"))

    ok("no page errors anywhere in all of that", not errors, errors)

    # THE SCREENSHOTS.  Both panels are live at the same time and they overlap, so each is shot with
    # the other shut — which is also how a phone uses them, and now how the menu makes them.
    page.evaluate("T.openWarp()")
    page.wait_for_timeout(400)
    shot = os.path.join(OUT, "warp-two-apps-devices.png")
    page.screenshot(path=shot)
    print("     screenshot (device manager): " + shot)
    page.evaluate("T.openFiles()")
    page.wait_for_timeout(600)
    shot2 = os.path.join(OUT, "warp-two-apps-files.png")
    page.screenshot(path=shot2)
    print("     screenshot (file browser):   " + shot2)
    page.evaluate("T.tapApps(); T.openMenu()")
    page.wait_for_timeout(300)
    shotm = os.path.join(OUT, "warp-two-apps-menu.png")
    page.screenshot(path=shotm)
    print("     screenshot (the ⊞ menu):     " + shotm)
    page.evaluate("T.openFiles()")
    page.wait_for_timeout(400)
    # and one more with the image selected and the columns scrolled to the preview pane, because the
    # opaque node is the other half of what this client was built to test
    page.evaluate("T.tapText('swatch.png')")
    page.wait_for_function("T.opaque().length === 1", timeout=20000)
    page.evaluate("document.getElementById('filesRows').scrollLeft = 1e6")
    page.wait_for_timeout(500)
    shot3 = os.path.join(OUT, "warp-two-apps-opaque.png")
    page.screenshot(path=shot3)
    print("     screenshot (opaque node):    " + shot3)
    print("     files: " + str(page.evaluate("T.files().stats()")))
    print("     warp:  " + str(page.evaluate("T.warp().stats()")))
    print("     diag: " + str(page.evaluate("diagLog")))

    # ---- a box that does not serve the file browser -------------------------------------------
    #
    # WARP_FILES gates that app on its own and nothing announces the answer: the gateway drops the
    # message and no frame comes back, which is indistinguishable — to the phone — from a box that
    # is merely slow.  So the menu cannot know before it asks, and the honest behaviour is to ask,
    # find out, and then stop offering it.  window.dropApp is that box, at the transport.
    #
    # A FRESH PAGE, because the point is a client that has never spoken to this app.
    print("\n== an app this box does not serve: asked once, then no longer an offer ==")
    page.goto(harness.as_uri())
    page.evaluate("window.dropApp = 'files'")
    ok("both apps are offered to begin with, because nothing has been asked",
       page.evaluate("T.openMenu()") and [e[2] for e in page.evaluate("T.entries()")] == [False, False],
       page.evaluate("T.entries()"))
    ok("the device manager answers", page.evaluate("T.openWarp()"))
    page.wait_for_function("T.warpRows().length > 0", timeout=15000)
    ok("the file browser's entry can be picked — nothing yet says otherwise",
       page.evaluate("T.openFiles()"))
    ok("and it says it is asking", page.evaluate("T.filesNote()") == "asking the box…",
       page.evaluate("T.filesNote()"))
    page.wait_for_function("T.filesNote().indexOf('no answer') === 0", timeout=12000)
    ok("after the no-answer timeout the panel names WHICH thing is missing, as it always did",
       page.evaluate("T.filesNote()") == "no answer — this box is not serving the file browser",
       page.evaluate("T.filesNote()"))
    page.evaluate("T.tapApps()")
    entries = page.evaluate("T.openMenu() && T.entries()")
    ok("and the menu has learnt it: the entry is struck out and cannot be picked",
       entries[1][0] == "files" and entries[1][2] is True, entries)
    ok("captioned with why, BEFORE the tap rather than after it",
       entries[1][3] == "not served by this box", entries)
    ok("it is still LISTED, though — a client that asked and heard nothing may not claim the app "
       "was never there", [e[0] for e in entries] == ["devices", "files"], entries)
    ok("picking it does nothing at all", page.evaluate("T.openFiles()") is False)
    ok("and the app that does answer is untouched",
       page.evaluate("T.openWarp()") and page.evaluate("T.warpRows()")[:2]
       == ["aa11bb22cc33", "dd33ee44ff55"])
    page.evaluate("T.tapApps(); T.openMenu()")
    page.wait_for_timeout(300)
    shot4 = os.path.join(OUT, "warp-two-apps-menu-unserved.png")
    page.screenshot(path=shot4)
    print("     screenshot (menu, files unserved): " + shot4)
    ok("still no page errors", not errors, errors)
    browser.close()

print(f"\n{'ALL TWO-APP ASSERTIONS HELD' if not fails else str(len(fails)) + ' FAILED: ' + str(fails)}")
sys.exit(1 if fails else 0)
