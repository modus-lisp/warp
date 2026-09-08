#!/bin/bash
# demo/shot-catalogue.sh — the widget catalogue, photographed.
#
# Serves warp-catalogue on a FREE port, drives a headless Chromium at it, puts the live controls
# into a state worth looking at, writes a full-page screenshot, and stops the server.
#
# The image is EVIDENCE, not decoration: every widget in it was rendered by the real encoding
# from a real projection, so a widget that is wrong here is wrong in warp-files too.  That is why
# this is a script and not a checked-in PNG somebody remembers to update.
#
#   demo/shot-catalogue.sh [outfile]
set -e
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
out="${1:-/tmp/warp-storybook.png}"
port="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"

sbcl --noinform --disable-debugger --load "$repo/demo/serve-catalogue.lisp" "$port" \
     >/tmp/warp-catalogue-shot.log 2>&1 &
srv=$!
trap 'kill -9 $srv 2>/dev/null || true' EXIT

for _ in $(seq 1 60); do grep -qa "catalogue on" /tmp/warp-catalogue-shot.log && break; sleep 1; done
grep -qa "catalogue on" /tmp/warp-catalogue-shot.log || { tail -5 /tmp/warp-catalogue-shot.log; exit 1; }

python3 - "$port" "$out" <<'PY'
import sys
from playwright.sync_api import sync_playwright
port, out = sys.argv[1], sys.argv[2]
with sync_playwright() as pw:
    b = pw.chromium.launch(); p = b.new_page(viewport={"width": 900, "height": 2400})
    p.goto(f"http://127.0.0.1:{port}/")
    p.wait_for_function("window.warp && warp.keys().length > 0", timeout=20000)
    # The client asks for 14 rows by default; the catalogue is the whole set at once.
    p.evaluate("warp.viewport(160,0)")
    p.wait_for_function("warp.keys().length >= 80", timeout=20000)
    # A control at rest photographs as a control that does nothing, so set them first.
    #
    # SET, DO NOT TOGGLE.  The demo state is a domain fact and is therefore SHARED across every
    # connection -- which is correct, and means a previous run leaves it wherever it left it.  A
    # script that blindly taps photographs the opposite of what it meant half the time.
    if "on" not in p.evaluate("document.querySelector('#rows li.toggle').className"):
        p.evaluate("warp.tap('live/toggle')")
        p.wait_for_function("document.querySelector('#rows li.toggle').className.includes('on')",
                            timeout=8000)
    p.evaluate("warp.setText('set-title','live/field','Quarterly review')")
    p.evaluate("warp.tap('live/choice/grid')")
    segs = p.evaluate("[...document.querySelectorAll('#rows .container[data-container=\"seek:level\"] li')]"
                      ".map(li=>li.dataset.key)")
    p.evaluate(f"warp.tap({segs[11]!r})")
    p.wait_for_timeout(2500)
    print("  rows      :", p.evaluate("warp.keys().length"))
    print("  containers:", p.evaluate("document.querySelectorAll('#rows .container').length"))
    kinds = p.evaluate("[...new Set([...document.querySelectorAll('#rows li')]"
                       ".map(li=>li.className.split(' ')[0]))]")
    print("  widgets   :", " ".join(sorted(k for k in kinds if k)))
    p.screenshot(path=out, full_page=True)
    b.close()
PY
echo "  -> $out"
