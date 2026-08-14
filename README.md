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

**A transport is a function of one string.** `dom/channel.lisp` is a consumer, a clock and a link,
where the link is `(lambda (frame) ...)` and nothing else — plus the four things a host would
otherwise write by hand around it: one lock over ticks and messages, a send that cannot signal, and
a close that runs on every unwind path. It has two callers, a local WebSocket and a WebRTC data
channel in the glass-webrtc gateway, and they share `dom/client.js` as well.

- `demo/two-encodings.lisp` — a framebuffer and a browser over one query, asserted rather than drawn
- `demo/serve-dom.lisp` — the DOM consumer live in a browser on a local port
- `t/channel.lisp` — the channel, over a fake transport: deltas out, gestures in, budget in bytes,
  owner and guest on one projection, and a guest's `revoke` refused at invocation
- `t/browser.sh` / `t/panel.sh` — the standalone client, and the phone panel, in a headless Chromium
- `t/nochange.lisp` — a 40-step scripted session over both encodings, dumped per step, so a
  refactor can be *shown* to have changed nothing
- `demo/damage-film.lisp` — the delta stream, rendered so you can watch it

The first practical client was the pipeline monitor (`app/`). **Client one — the device manager —
now runs too**, inside the glass-webrtc gateway, over the enrolment file that gateway writes, with
the invoker taken from the authenticated Nostr identity: an allowlisted owner is offered `revoke`,
an enrolled guest is not, and a guest who sends it anyway is refused by `invoke`.

**Client two — a Miller-column file browser (`files/`)** — is the first that is not a flat list. It
projects [warren](../warren)'s `fs.lisp` (198 lines of filesystem model with no drawing in it);
warren itself is untouched and still runs, because the two are the *data* and *pixel* facets of one
app. It is the first client to **nest** and the first to carry an **opaque node** — an image preview
that one consumer blits and the other receives as the caption the app supplied.

| system | what it adds |
|---|---|
| `warp-files` | the projection over warren's model, and the Miller walk (no pixels, no JSON) |
| `warp-files/glass` | rectangles, painting, and the blit |
| `warp-files/dom` | one container per column, and a node it is told about but cannot draw |

- `t/files.lisp` — the delta-scoping numbers, `eq` failing across a re-read, the opaque node on both
  encodings, and a delete refused at invocation that the menu never offered
- `demo/files-shot.lisp` — real columns of real files, rendered offscreen to a PNG

It also falsified rule 1's opening line: the reconciler does **not** match on `(parent, key)` — it
holds one flat table keyed by `p-key`, `p-children` is read by nothing, and parent scoping is
something a key function has to do for itself. See DESIGN.md rules 1 and 9 for what that costs and
what it does not.
