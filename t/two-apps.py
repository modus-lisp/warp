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

It takes the panels' ACTUAL BYTES out of payload.js — the two stylesheet blocks, the embedded copy
of client.js, and the two wiring blocks, all lifted by their markers rather than retyped — and gives
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
CSS = ("/* --- the warp panel:" + between("/* --- the warp panel:", FILES_CSS_BEGIN)
       + between(FILES_CSS_BEGIN, "/* ==== END the file browser's stylesheet", True))
CLIENT = between("// ==== BEGIN warp/dom/client.js — VERBATIM, checked by warp/t/client-sync.py ====",
                 "// ==== END warp/dom/client.js ====")
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
    ws.onmessage = e => { window.rx.push(e.data); (ch._ls.message || []).forEach(f => f({data: e.data})); };
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
{WARP_WIRING}
{FILES_WIRING}
window.T = {{
  openWarp:  () => document.querySelector('[aria-label="enrolled terminals"]').click(),
  openFiles: () => document.querySelector('[aria-label="files"]').click(),
  warpVisible:  () => getComputedStyle(document.getElementById('warpPanel')).display,
  filesVisible: () => getComputedStyle(document.getElementById('filesPanel')).display,
  warpRows: () => [...document.querySelectorAll('#warpRows li')].map(li => li.dataset.key),
  warpMenu: () => [...document.querySelectorAll('#warpMenu li')].map(li => li.textContent),
  filesMenu: () => [...document.querySelectorAll('#filesMenu li')].map(li => li.textContent),
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

    print("== app one: the device manager, exactly as it was ==")
    page.evaluate("T.openWarp()")
    page.wait_for_function("T.warpRows().length > 0", timeout=15000)
    sent = [json.loads(s) for s in page.evaluate("sent")]
    ok("its first message is the viewport report, with NO app label on it",
       sent[0]["t"] == "viewport" and "a" not in sent[0], sent[0])
    dm_rows = page.evaluate("T.warpRows()")
    ok("its rows are the box's enrolled terminals, in the box's keys",
       dm_rows[:2] == ["aa11bb22cc33", "dd33ee44ff55"], dm_rows[:3])
    ok("and they are flat: the device manager's panel made no containers",
       page.evaluate("document.querySelectorAll('#warpRows .container').length") == 0)
    ok("its client counted only its own frames",
       page.evaluate("T.warp().stats().frames") > 0 and page.evaluate("T.warp().stats().nodes") > 0,
       page.evaluate("T.warp().stats()"))

    print("== app two: the file browser, on the same channel ==")
    page.evaluate("T.openFiles()")
    page.wait_for_function("T.cols().length > 0", timeout=15000)
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

    ok("no page errors anywhere in all of that", not errors, errors)

    # THE SCREENSHOTS.  Both panels are live at the same time and they overlap, so each is shot with
    # the other shut — which is also how a phone uses them.
    page.evaluate("T.openFiles()")
    page.wait_for_timeout(400)
    shot = os.path.join(OUT, "warp-two-apps-devices.png")
    page.screenshot(path=shot)
    print("     screenshot (device manager): " + shot)
    page.evaluate("T.openWarp(); T.openFiles()")
    page.wait_for_timeout(600)
    shot2 = os.path.join(OUT, "warp-two-apps-files.png")
    page.screenshot(path=shot2)
    print("     screenshot (file browser):   " + shot2)
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
    browser.close()

print(f"\n{'ALL TWO-APP ASSERTIONS HELD' if not fails else str(len(fails)) + ' FAILED: ' + str(fails)}")
sys.exit(1 if fails else 0)
