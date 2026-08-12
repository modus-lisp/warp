#!/bin/bash
# t/panel.sh — the glass-webrtc warp panel, verified in a real headless Chromium.
#
# Same shape as t/browser.sh: start demo/serve-dom.lisp on a FREE port (never 5910, never the
# gateway's, never a desktop's), drive t/panel.py against it, stop the server.  Everything it
# writes goes to /tmp.  The gateway is never loaded, started, or contacted.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
out="${WARP_BROWSER_OUT:-/tmp/warp-browser}"
mkdir -p "$out"

port=$(python3 -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()")
echo "== serving on 127.0.0.1:$port =="

CL_SOURCE_REGISTRY='(:source-registry (:tree "/home/claude/") :inherit-configuration)' \
  sbcl --dynamic-space-size 2048 --non-interactive \
       --load "$here/../demo/serve-dom.lisp" "$port" > "$out/panel-server.log" 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null' EXIT

for i in $(seq 1 120); do
  grep -q "consumer on" "$out/panel-server.log" && break
  sleep 1
done
grep -q "consumer on" "$out/panel-server.log" || { echo "server did not start"; tail -20 "$out/panel-server.log"; exit 1; }

WARP_BROWSER_OUT="$out" python3 "$here/panel.py" "$port"
