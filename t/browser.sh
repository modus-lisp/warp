#!/bin/bash
# t/browser.sh — the DOM encoding, verified in a real headless Chromium.
#
# Starts demo/serve-dom.lisp on a FREE port (never 5910, never the gateway's, never a desktop's),
# drives t/browser.py against it with Playwright, screenshots the result, and stops the server.
# Everything it writes goes to /tmp.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"    # warp itself
ws="$(cd "$repo/.." && pwd)"      # the workspace warp and its siblings live in
out="${WARP_BROWSER_OUT:-/tmp/warp-browser}"
mkdir -p "$out"

port=$(python3 -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()")
echo "== serving on 127.0.0.1:$port =="

# warp's fasls only: the cache is shared with other work in this image
for d in ~/.cache/common-lisp/*"$repo"; do [ -e "$d" ] && rm -rf "$d"; done

CL_SOURCE_REGISTRY="(:source-registry (:tree \"$ws/\") :inherit-configuration)" \
  sbcl --dynamic-space-size 2048 --non-interactive \
       --load "$here/../demo/serve-dom.lisp" "$port" > "$out/server.log" 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null' EXIT

for i in $(seq 1 120); do
  grep -q "consumer on" "$out/server.log" && break
  sleep 1
done
grep -q "consumer on" "$out/server.log" || { echo "server did not start"; tail -20 "$out/server.log"; exit 1; }

WARP_BROWSER_OUT="$out" python3 "$here/browser.py" "$port"
