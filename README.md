# warp

A presentation-based UI kit for [glass](../glass) apps, in pure Common Lisp on
[gesso](../gesso) (2D vector) and [scribe](../scribe) (text).

*warp: the threads held under tension on the loom — the retained structure the weft passes
through.* [weft](../weft) is the web engine; warp is the retained UI tree.

Output is not pixels but **typed objects that were displayed** (CLIM's presentations), and
**commands** are declared against those types rather than wired to widgets. That buys three things
at once: the inspector is a consequence rather than a feature, one command set can serve several
surfaces with authorization written once, and damage is semantic — which matters because glass
ships its framebuffer to a phone as VP8 over cellular, where pixels are priced.

See [DESIGN.md](DESIGN.md) for the rules and, more importantly, for what is deliberately refused.

## Status

Design settled; first client (the glass device manager) not yet written.
