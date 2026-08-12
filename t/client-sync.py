"""t/client-sync.py — one client, two hosts, and a check that they are still the same file.

warp/dom/client.js is loaded by the standalone page over a WebSocket and EMBEDDED, verbatim, in
glass-webrtc's phone client, which is one self-contained HTML file that a bundler splices and an
nsite serves — there is no <script src> it could use.  So the second copy is a copy, and a copy
without a check is two clients that agree today.

This is the check.  It compares the marked region of index-nostr.html against client.js byte for
byte and fails if they have drifted.  To re-sync after editing client.js, run the same script that
put it there:

    python3 <scratch>/insert.py          # or by hand: replace the marked region

    python3 t/client-sync.py [path/to/index-nostr.html]

Exit 0 identical, 1 drifted, 77 when the phone client is not checked out beside warp — which is
the ordinary case for anyone who has warp and not webrtc-data, and is not a failure.
"""
import pathlib, sys, difflib

BEGIN = "// ==== BEGIN warp/dom/client.js — VERBATIM, checked by warp/t/client-sync.py ===="
END = "// ==== END warp/dom/client.js ===="

here = pathlib.Path(__file__).resolve().parent
client = (here.parent / "dom" / "client.js").read_text()
html_path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else (
    here.parent.parent / "webrtc-data" / "demo" / "glass-webrtc" / "index-nostr.html")

if not html_path.exists():
    print(f"  skip  the phone client is not checked out at {html_path}")
    sys.exit(77)

html = html_path.read_text()
if BEGIN not in html or END not in html:
    print(f"  FAIL  {html_path} has no marked warp client block")
    sys.exit(1)

embedded = html[html.index(BEGIN) + len(BEGIN):html.index(END)]
embedded = embedded[1:] if embedded.startswith("\n") else embedded   # the newline after BEGIN
# the END marker is indented to match its surroundings; that indent is not part of the file
embedded = embedded[:-len(embedded) + embedded.rindex("\n") + 1] if embedded.rstrip(" ").endswith("\n") else embedded

if embedded == client:
    n = len(client.splitlines())
    print(f"  ok    dom/client.js and {html_path.name} hold the same {n} lines")
    sys.exit(0)

print("  FAIL  the embedded copy has drifted from dom/client.js")
for line in list(difflib.unified_diff(client.splitlines(), embedded.splitlines(),
                                      "dom/client.js", f"{html_path.name} (embedded)",
                                      lineterm=""))[:40]:
    print("        " + line)
sys.exit(1)
