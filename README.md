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
- `demo/serve-both.lisp` — two apps over one link, which is what the gateway does on stream 102
- `t/channel.lisp` — the channel, over a fake transport: deltas out, gestures in, budget in bytes,
  owner and guest on one projection, a guest's `revoke` refused at invocation, and the mux that
  routes several projections down one link
- `t/browser.sh` / `t/panel.sh` / `t/two-apps.sh` — the standalone client, the phone panel, and the
  device manager and file browser at once, all in a headless Chromium
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

**Client three — a media player (`media/`)** — is the first client whose opaque node *moves*.
`warp-media` projects a folder of files as Winamp's arrangement: a playlist, a transport that never
moves, a clock, and the picture. The picture is a rule-9 opaque node whose fingerprint is
`(caption, size, frame-number)`, so each decoded frame is one `:changed` delta on one extent — the
framebuffer encoding blits it, everyone else gets "Big Buck Bunny — 640 x 360, frame 812". Decoding
is [cassette](../cassette) — WebM and MP4, VP8 and H.264 — and reed; sound is one source thunk on glass's session
mixer, and the mixer's 20 ms clock is what paces the picture (a silent film falls back to the wall
clock). It is a `:surface` app in the desktop's root menu, not a McCLIM frame.

| system | what it adds |
|---|---|
| `warp-media` | the engine (decode threads, two bounded queues, the thunk, the clock), the domain, commands, the layout seam |
| `warp-media/glass` | the transport and rows painted, the frame scaled into its 512x288 band |

- `t/media.lisp` — a folder of real WebM files, the mixer's clock driven by hand: frame numbers
  climb with the audio taken, pause is `NIL`, the end of the folder stops, and a framebuffer pass
  after the clock moves repaints the picture and nothing else
- MP4 plays too, picture and sound. The video is H.264, which [reel](../reel) decodes bit-exactly
  for intra-only streams, and the audio is AAC: cassette demuxes the track and reed decodes it.
  That layering is load-bearing rather than tidy — reed's own MP4 reader looks for a decoder config
  under the first track it finds, so on a file with video first it finds an `avcC` and reports
  "no esds AudioSpecificConfig", and an A/V mp4 would not play at all, not even its sound.
- **A picture that gives up does not take the sound with it.** reel does not decode H.264 P slices
  yet, so a normal inter-coded MP4 stops producing frames part way through. The player drops the
  picture, puts the reason where the transport shows it, and runs the audio to the end. That is the
  difference between a media player and a decoder test, and `t/media-seek.lisp` asserts it.
- `t/media-seek.lisp` — seeking: WebM to the exact frame (decoding forward from the cue, with a
  cluster walk for files without Cues), MP3 by a Xing/TOC or CBR index landing on the right sound,
  Opus from the decoded cache in ~10 ms, a paused seek that stays paused, and the 32-cell seek bar
  whose cells are ordinary presentations with `seek-to-cell` as their default command
- `demo/media-run.lisp` — Big Buck Bunny against a live mixer at 60 Hz, with a keeping-up verdict

It also falsified rule 1's opening line: the reconciler does **not** match on `(parent, key)` — it
holds one flat table keyed by `p-key`, `p-children` is read by nothing, and parent scoping is
something a key function has to do for itself. See DESIGN.md rules 1 and 9 for what that costs and
what it does not.

**It runs on the phone now, beside the device manager, on the one data channel there is.** A client
message may carry `a` — the app it is for — and a frame carries `a` back; the device manager is the
app with **no** name, so its bytes are exactly what they were. A second channel would have been
simpler and was not available: channels are created before the offer, in the shell that lives on
nsite, so one more of them costs a publish. Putting `warp-files` on a phone also found the two
things no flat client could: the DOM client had no containers at all (everything that was not
`rows` went to the hold-menu), and nothing on the wire said where a container goes — the frame
carries `cs` for that now.
