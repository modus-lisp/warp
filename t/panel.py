"""t/panel.py — the glass-webrtc warp panel, in a real headless Chromium.

WHAT THIS DOES AND DOES NOT PROVE.  The panel lives inside index-nostr.html, which needs a WebRTC
peer connection to a live gateway to run — and that gateway is carrying somebody's session and may
not be started a second time.  So this harness takes the panel's ACTUAL BYTES out of that file —
the stylesheet block, the embedded copy of client.js, and the wiring block, all three lifted by
their markers rather than retyped — and gives them the three things they expect from the page
around them:

    pc.createDataChannel   a fake RTCDataChannel backed by a WebSocket to demo/serve-dom.lisp
    mkToggle / setBtn      the page's own button helpers, transcribed (they are eight lines)
    diag                   the page's log line, into an array a test can read

Everything else — the panel markup, its CSS, the viewport report, the first-open hello, the
no-answer timeout, the gesture scoping, the reset on close, and the whole of client.js — is the
file's own code, running.

NOT exercised here, and worth saying plainly: SCTP, the negotiated stream id, and the interaction
with the real page's trackpad and modifier row.  Those need the gateway.

    python3 t/panel.py <port-of-serve-dom>
"""
import json, os, pathlib, re, sys
from playwright.sync_api import sync_playwright

PORT = sys.argv[1]
OUT = os.environ.get("WARP_BROWSER_OUT", "/tmp/warp-browser")
os.makedirs(OUT, exist_ok=True)
HERE = pathlib.Path(__file__).resolve().parent
HTML = pathlib.Path(os.environ.get(
    "WARP_PHONE_CLIENT",
    HERE.parent.parent / "webrtc-data" / "demo" / "glass-webrtc" / "index-nostr.html"))

fails = []
def ok(name, cond, detail=""):
    print(f"  {'ok  ' if cond else 'FAIL'} {name}{('   ' + str(detail)) if detail else ''}")
    if not cond:
        fails.append(name)

if not HTML.exists():
    print(f"  skip  the phone client is not checked out at {HTML}")
    sys.exit(77)

src = HTML.read_text()

def between(a, b, keep_markers=False):
    i = src.index(a)
    j = src.index(b, i)
    return src[i:j + len(b)] if keep_markers else src[i + len(a):j]

CSS = between("/* --- the warp panel:", "  </style>")
CSS = "/* --- the warp panel:" + CSS
CLIENT = between("// ==== BEGIN warp/dom/client.js — VERBATIM, checked by warp/t/client-sync.py ====",
                 "// ==== END warp/dom/client.js ====")
WIRING = between("    // --- ▤ the device manager: warp, on a third data channel",
                 "window.addEventListener('resize', () => { if (warpOn) warp.viewport(warpFit(), 0); });",
                 keep_markers=True)

SHIM = """
// ---- the three things the page around the panel provides -------------------------------------
const diagLog = []; window.diagLog = diagLog;
const diag = (m) => diagLog.push(m);
const gGlyph = g => { const s = document.createElement('span'); s.className='gg'; s.textContent=g; return s; };
const mkToggle = (glyph, right, label) => {          // transcribed from index-nostr.html
  const b = document.createElement('button');
  b.appendChild(gGlyph(glyph)); b.className = 'gbtn'; b.dataset.state = 'off';
  if (label) b.setAttribute('aria-label', label);
  b.style.bottom = '14px'; b.style.right = right + 'px';
  document.body.appendChild(b); return b;
};
const setBtn = (b, state) => { b.dataset.state = state; b.disabled = state === 'disabled'; };

// a fake RTCDataChannel: a WebSocket wearing the four members the wiring touches
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
    ws.onmessage = e => (ch._ls.message || []).forEach(f => f({data: e.data}));
    ws.onclose = () => (ch._ls.close || []).forEach(f => f({}));
    window.__ws = ws;
    return ch;
  }
};
window.sent = [];
"""

page_html = f"""<!doctype html>
<meta charset="utf-8">
<title>warp panel harness</title>
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
{WIRING}
window.warpTest = {{
  btn: () => document.querySelector('[aria-label="enrolled terminals"]'),
  open: () => document.querySelector('[aria-label="enrolled terminals"]').click(),
  visible: () => getComputedStyle(document.getElementById('warpPanel')).display,
  rows: () => [...document.querySelectorAll('#warpRows li')].map(li => li.dataset.key),
  menu: () => [...document.querySelectorAll('#warpMenu li')].map(li => li.textContent),
  note: () => document.getElementById('warpNote').textContent,
  stat: () => document.getElementById('warpStat').textContent,
  api: () => warp
}};
</script>
"""

harness = pathlib.Path(OUT) / "warp-panel-harness.html"
harness.write_text(page_html)

with sync_playwright() as pw:
    browser = pw.chromium.launch()
    page = browser.new_page(viewport={"width": 390, "height": 780})   # a phone, not a desktop
    errors = []
    page.on("pageerror", lambda e: errors.append(str(e)))
    page.goto(harness.as_uri())

    print("== the panel is out of the way until it is asked for ==")
    ok("the page's own script ran without an error", not errors, errors)
    ok("the channel was created negotiated, on stream 102",
       page.evaluate("warpChOpts") == {"ordered": True, "negotiated": True, "id": 102},
       page.evaluate("warpChOpts"))
    ok("the panel is display:none, so it is out of hit-testing entirely",
       page.evaluate("warpTest.visible()") == "none")
    ok("the ▤ button exists and is off", page.evaluate("warpTest.btn().dataset.state") == "off")
    ok("it sits on the LEFT, above the ≡, clear of the five-button right-hand row",
       page.evaluate("warpTest.btn().style.left") == "14px"
       and page.evaluate("warpTest.btn().style.bottom") == "78px")
    page.wait_for_timeout(700)
    ok("and NOTHING has been sent — a session where nobody taps ▤ costs zero bytes",
       page.evaluate("sent") == [], page.evaluate("sent"))

    print("== opening it is what puts the first byte on the channel ==")
    page.evaluate("warpTest.open()")
    page.wait_for_function("warpTest.rows().length > 0", timeout=15000)
    sent = [json.loads(s) for s in page.evaluate("sent")]
    ok("the first thing sent is the viewport report — the consumer-negotiated slice",
       sent and sent[0]["t"] == "viewport" and sent[0]["rows"] >= 3, sent[0] if sent else None)
    ok("the panel is showing", page.evaluate("warpTest.visible()") == "flex")
    rows = page.evaluate("warpTest.rows()")
    ok("and it filled with the server's rows, in the server's keys", len(rows) >= 3, rows[:3])
    ok("the header counts them", "terminal" in page.evaluate("warpTest.stat()"),
       page.evaluate("warpTest.stat()"))
    # THE SLICE ARRIVES ONE PASS LATE, ON PURPOSE.  The server seats the consumer with its own
    # default row count and its clock is already running, so the first frame is that default; the
    # browser's report then trims it and the difference comes back as :gone.  Converging rather
    # than negotiating up front is what makes the report an ordinary message instead of a
    # handshake, and it is the same discipline everywhere else in this protocol — say the current
    # state, let the stream close the gap.
    asked = sent[0]["rows"]
    page.wait_for_function(f"warpTest.rows().length === {asked}", timeout=8000)
    ok("and the slice converges to the number of rows the panel actually fits",
       page.evaluate("warpTest.rows().length") == asked,
       f"asked {asked}, settled at {page.evaluate('warpTest.rows().length')} (first frame had {len(rows)})")

    print("== a hold opens the applicable-command menu, inside the panel ==")
    page.evaluate("warpTest.api().hold('aa11bb22cc33')")
    page.wait_for_function("warpTest.menu().length >= 3", timeout=8000)
    menu = page.evaluate("warpTest.menu()")
    ok("the menu is the applicable commands plus cancel", len(menu) == 3, menu)
    ok("and the destructive one is drawn as destructive",
       page.evaluate("document.querySelectorAll('#warpMenu li.destructive').length") == 1)
    ok("it is inside the panel, not over the desktop",
       page.evaluate("document.getElementById('warpMenu').closest('#warpPanel') !== null"))

    print("== a tap on a row is a gesture, and the panel is where it is recognized ==")
    page.click("#warpRows li[data-key='stat05']")
    page.wait_for_function(
        "() => document.querySelector(\"#warpRows li[data-key='stat05']\")"
        ".className.includes('selected')", timeout=8000)
    ok("the tap travelled and came back as view state on that row", True)
    ok("gestures are scoped to the panel — a tap on the page behind it sends nothing",
       (lambda before: (page.mouse.click(5, 770), page.wait_for_timeout(400),
                        len(page.evaluate("sent")) == before)[-1])(len(page.evaluate("sent"))))

    print("== closing the panel leaves the page as it found it ==")
    page.evaluate("warpTest.open()")
    ok("display:none again", page.evaluate("warpTest.visible()") == "none")
    ok("and the button says so", page.evaluate("warpTest.btn().dataset.state") == "off")
    n = len(page.evaluate("sent"))
    page.evaluate("warpTest.open()")
    page.wait_for_timeout(300)
    ok("re-opening re-reports the viewport rather than opening a second consumer",
       len(page.evaluate("sent")) == n + 1
       and json.loads(page.evaluate("sent")[-1])["t"] == "viewport")

    print("== a box that never answers says so, instead of showing an empty list ==")
    dead = browser.new_page(viewport={"width": 390, "height": 780})
    dead_html = page_html.replace(json.dumps("ws://127.0.0.1:" + str(PORT) + "/warp"),
                                  json.dumps("ws://127.0.0.1:1/warp"))
    dead_file = pathlib.Path(OUT) / "warp-panel-noanswer.html"
    dead_file.write_text(dead_html)
    dead.goto(dead_file.as_uri())
    dead.evaluate("warpTest.open()")
    dead.wait_for_function("warpTest.note().includes('not serving')", timeout=12000)
    ok("the note names the reason rather than implying nobody is enrolled",
       "not serving" in dead.evaluate("warpTest.note()"), dead.evaluate("warpTest.note()"))
    ok("and the panel is empty rather than wrong", dead.evaluate("warpTest.rows()") == [])
    dead.close()

    ok("no page errors anywhere in all of that", not errors, errors)
    # leave it OPEN for the screenshot — the toggle has been flipped an even number of times above
    if page.evaluate("warpTest.visible()") == "none":
        page.evaluate("warpTest.open()")
    page.evaluate("warpTest.api().hold('dd33ee44ff55')")
    page.wait_for_timeout(700)
    shot = os.path.join(OUT, "warp-panel.png")
    page.screenshot(path=shot)
    print("     screenshot: " + shot)
    print("     diag: " + str(page.evaluate("diagLog")))
    browser.close()

print(f"\n{'ALL PANEL ASSERTIONS HELD' if not fails else str(len(fails)) + ' FAILED: ' + str(fails)}")
sys.exit(1 if fails else 0)
