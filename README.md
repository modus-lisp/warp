# warp

A presentation-based UI kit for [glass](../glass) apps, in pure Common Lisp on
[gesso](../gesso) (2D vector) and [scribe](../scribe) (text).

*warp: the threads held under tension on the loom — the retained structure the weft passes
through.* [weft](../weft) is the web engine; warp is the retained UI tree.

warp is not really a widget kit. It is a **keyed, budgeted, staleness-annotated delta protocol
over typed projections**, with encodings per consumer — macroblocks for retinas, tokens for a
model. `present` is not a rendering step but a compression decision: which slice of the object
graph travels toward a consumer with finite intake. A context window is a viewport.

Output is therefore *typed objects that were displayed* (CLIM's presentations), and **commands** are
declared against those types rather than wired to widgets. The payoff compounds: the inspector is a
consequence rather than a feature; one command set serves the DM interface, a CLI, the GUI and an
agent with authorization written once; and deltas are semantic, which is what makes the transport
affordable over cellular.

See [DESIGN.md](DESIGN.md) for the rules and, more importantly, for what is deliberately refused.

## Status

The protocol is in `warp` and depends on `bordeaux-threads` and nothing else. **Three encodings:**

| system | target | budget spent in | position is |
|---|---|---|---|
| `warp-glass` | a glass framebuffer, over RFB | 16px macroblocks | `(x y w h)`, grid-snapped |
| `warp-dom` | a DOM in a browser, over JSON | serialized bytes | `(parent . after-key)` |
| `warp` itself | `recording-consumer` — the deltas, kept | a flat 1 per delta | whatever it is handed |

One projection, one query, several consumers, each with its own stream, budget, viewport, scroll,
selection and invoker.

- `demo/two-encodings.lisp` — a framebuffer and a browser over one query, asserted rather than drawn
- `demo/serve-dom.lisp` — the DOM consumer live in a browser on a local port
- `t/browser.sh` — the same thing verified in a headless Chromium
- `demo/damage-film.lisp` — the delta stream, rendered so you can watch it

First practical client is the pipeline monitor (`app/`), not the device manager.
