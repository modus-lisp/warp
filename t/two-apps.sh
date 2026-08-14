#!/bin/bash
# t/two-apps.sh — the device manager AND the file browser, on one link, in a real headless Chromium.
#
# Same shape as t/panel.sh, with demo/serve-both.lisp in place of demo/serve-dom.lisp: a FREE port
# (never 5910, never the gateway's, never a desktop's), a fixture tree under /tmp, and the phone
# client's own bytes driven by t/two-apps.py.  Everything it writes goes to /tmp.  The gateway is
# never loaded, started, or contacted.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
out="${WARP_BROWSER_OUT:-/tmp/warp-browser}"
root="${WARP_TWO_ROOT:-/tmp/warp-two-fixture}"
mkdir -p "$out"

# the fixture: two columns' worth of directories and files, all under /tmp.  The PNG that makes the
# opaque node is written by the harness, mid-run, so its arrival is a delta like any other.
case "$root" in /tmp/*) ;; *) echo "refusing to build a fixture outside /tmp: $root"; exit 1;; esac
rm -rf "$root"
mkdir -p "$root/fix/pics"
printf 'aaaa\n' > "$root/alpha.txt"
printf 'bbbbbbbb\n' > "$root/beta.txt"
printf 'cccc\n' > "$root/fix/gamma.txt"
printf 'dddddddd\n' > "$root/fix/delta.txt"
printf 'eeee\n' > "$root/fix/pics/note.txt"

port=$(python3 -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()")
echo "== serving two apps on 127.0.0.1:$port, files rooted at $root =="

CL_SOURCE_REGISTRY='(:source-registry (:tree "/home/claude/") :inherit-configuration)' \
  sbcl --dynamic-space-size 2048 --non-interactive \
       --load "$here/../demo/serve-both.lisp" "$port" "$root" > "$out/two-apps-server.log" 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null' EXIT

for i in $(seq 1 180); do
  grep -q "consumer on" "$out/two-apps-server.log" && break
  sleep 1
done
grep -q "consumer on" "$out/two-apps-server.log" || {
  echo "server did not start"; tail -20 "$out/two-apps-server.log"; exit 1; }

WARP_BROWSER_OUT="$out" python3 "$here/two-apps.py" "$port" "$root"
