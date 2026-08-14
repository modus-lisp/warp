"""t/client-sync.py — one client, several hosts, and a check that they are still the same file.

warp/dom/client.js is loaded by the standalone page over a WebSocket and EMBEDDED, verbatim, in
glass-webrtc's phone client, which is one self-contained HTML file that a bundler splices and an
nsite serves — there is no <script src> it could use.  So the second copy is a copy, and a copy
without a check is two clients that agree today.

THERE ARE TWO OF THEM NOW, and the one that ships is the second: `payload.js` is the half of the
phone client the box serves over stream 104, so a change to it costs a file copy, while
`index-nostr.html` is the pre-split monolith kept beside it.  Both are checked by default, because
the whole hazard is a copy nobody remembers to re-sync.

This is the check.  It compares the marked region of each host against client.js byte for byte and
fails if they have drifted.  To re-sync after editing client.js, re-run whatever put it there — the
region is delimited by the two markers below and nothing else in the host is touched.

    python3 t/client-sync.py [path/to/host ...]

Exit 0 identical, 1 drifted, 77 when no host is checked out beside warp — which is the ordinary
case for anyone who has warp and not webrtc-data, and is not a failure.
"""
import pathlib, sys, difflib

BEGIN = "// ==== BEGIN warp/dom/client.js — VERBATIM, checked by warp/t/client-sync.py ===="
END = "// ==== END warp/dom/client.js ===="

here = pathlib.Path(__file__).resolve().parent
client = (here.parent / "dom" / "client.js").read_text()
gw = here.parent.parent / "webrtc-data" / "demo" / "glass-webrtc"
hosts = ([pathlib.Path(a) for a in sys.argv[1:]]
         or [gw / "payload.js", gw / "index-nostr.html"])

checked = 0
drifted = 0

for html_path in hosts:
    if not html_path.exists():
        print(f"  skip  the phone client is not checked out at {html_path}")
        continue
    checked += 1

    html = html_path.read_text()
    if BEGIN not in html or END not in html:
        print(f"  FAIL  {html_path} has no marked warp client block")
        drifted += 1
        continue

    embedded = html[html.index(BEGIN) + len(BEGIN):html.index(END)]
    embedded = embedded[1:] if embedded.startswith("\n") else embedded   # the newline after BEGIN
    # the END marker is indented to match its surroundings; that indent is not part of the file
    embedded = (embedded[:-len(embedded) + embedded.rindex("\n") + 1]
                if embedded.rstrip(" ").endswith("\n") else embedded)

    if embedded == client:
        n = len(client.splitlines())
        print(f"  ok    dom/client.js and {html_path.name} hold the same {n} lines")
        continue

    drifted += 1
    print(f"  FAIL  the copy embedded in {html_path.name} has drifted from dom/client.js")
    for line in list(difflib.unified_diff(client.splitlines(), embedded.splitlines(),
                                          "dom/client.js", f"{html_path.name} (embedded)",
                                          lineterm=""))[:40]:
        print("        " + line)

if not checked:
    sys.exit(77)
sys.exit(1 if drifted else 0)
