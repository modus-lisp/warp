#!/bin/bash
# Render the damage film: warp's delta stream, side by side with the damage it emitted.
# Left pane = what a viewer sees.  Right = the same frame dimmed, with emitted damage
# tinted/outlined by kind (green appeared, red gone, blue moved, amber changed).
set -e
here="$(cd "$(dirname "$0")" && pwd)"
out="${1:-/tmp/warp-demo.mp4}"
work=$(mktemp -d)
CL_SOURCE_REGISTRY='(:source-registry (:tree "/home/claude/") :inherit-configuration)' \
  sbcl --dynamic-space-size 2048 --non-interactive --load "$here/damage-film.lisp"
# the rawvideo demuxer wants one stream, not a numbered pattern
cat $(ls /tmp/warp-film/f*.rgb | sort) > "$work/all.rgb"
ffmpeg -hide_banner -loglevel error -f rawvideo -pix_fmt rgb24 -s 968x476 -framerate 1 \
  -i "$work/all.rgb" -vf "scale=1936:952:flags=neighbor,fps=12" \
  -c:v libx264 -pix_fmt yuv420p -crf 20 -y "$out"
rm -rf "$work"
echo "wrote $out"
