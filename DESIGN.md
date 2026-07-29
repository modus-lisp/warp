# warp — a presentation-based UI kit for glass

*warp: the threads held under tension on the loom — the retained structure the weft passes
through. weft is the web engine; warp is the retained UI tree.*

## What this is

A small UI system for glass apps, on **gesso** (2D vector) and **scribe** (text). Not in loom
(loom is an app), not McCLIM (retained but imperative, and its size is the problem).

Two ideas, one refusal:

- **Presentations** (from CLIM): output is not pixels, it is *typed objects that were displayed*.
  A presentation is `(key, type, object, extent, render)`. The retained tree of these is the UI.
- **Commands** (from CLIM): declared against argument *types*, not wired to widgets.
- **Refused**: presentation translators, nested input contexts, `accept`-driven parsing. That
  machinery is where CLIM's size lives, and our gesture vocabulary cannot express it anyway.

Reconciliation (rebuild declaratively, diff against the retained tree) is *not* a modern import —
it is CLIM's `updating-output` with `:unique-id`/`:cache-value`. It is also the part of CLIM with
the worst bug reputation, and the reason is identity. Hence rule 1.

## Why a retained tree, and not immediate mode

1. **The inspector needs a thing to inspect.** Immediate mode has no object between frames.
2. **The transport is priced per pixel.** glass ships a framebuffer to a phone as VP8 over
   cellular. The pipeline is tuned end to end for *only what changed*:
   `presentation extent → RFB damage rect → dirty macroblock → skip bit`.
   A UI that re-emits the world each frame is the pathological input for it. (loom's chrome is
   immediate-mode and paints straight into the live framebuffer; that is why it flickers.)

warp does not need to invent damage transport. It needs to emit correct rects into a chain that
already exists and is already tuned.

## Rule 1 — identity

A presentation is `(key, type, object, extent, render)`. Reconcile matches on `(parent, key)`.

- **The default key is a per-type key function, declared once alongside the type.** Raw `eq` is
  the fallback *only* for objects with genuine identity.
- **`eq` as the default would be a trap.** Our first client proves it: enrollments come from a
  file that `sync-devices` re-reads by `clrhash` + reload. There are no persistent objects at all —
  every sync yields fresh state. `eq` would fail universally, everything would look new, and we
  would emit full-frame damage forever while the code looked correct. It would "work" by accident
  today and break on client two.
- Device manager key: **the pubkey**.

Damage from reconciliation:

| outcome | damage |
|---|---|
| matched, render inputs unchanged | none |
| matched, changed | its extent |
| new | its extent |
| dropped | its extent |
| subtree translated | `:translated (dx dy)` — see rule 2 |

## Rule 2 — damage kinds, and translation

Fixed extents bound damage per *mutation*. They do nothing for **scroll**, which translates every
row and would naively dirty the whole viewport — blowing the per-frame byte budget that exists
because one 143 KB frame is ~570 ms on cellular and reads as a freeze.

So a subtree may report **`:translated (dx dy)`** as its damage, distinct from `:changed`. This
maps onto transport that already exists: RFB **CopyRect** (glass emits it on window moves; the
capture applies it as a plane move) and, eventually, **VP8 motion vectors**.

> **Honest status:** the payoff is not there yet. Our capture marks the CopyRect *destination*
> dirty, and the encoder re-codes it with ZEROMV, so a translation currently costs what a change
> costs. `:translated` is designed in now because it is a *wire/damage* concept — retrofitting it
> after clients exist would be a migration. It becomes cheap when VP8 MVs land.

Without this, the transport argument holds for edits and collapses for navigation — and navigation
is most of what a finger does to a list.

## Rule 3 — extents snap to the macroblock grid

The chain ends in 16px macroblocks. Sub-grid precision is precision the encoder cannot use: a 20px
row dirties two macroblock rows for one row of content. **Row heights and pane edges snap to 16 at
layout time.** One line of layout policy; free now, a migration later.

## Rule 4 — gestures are recognized on the client, and the wire carries semantic gestures

Press-hold is a *timing* discrimination (down, ~400 ms, no movement). Doing it server-side from raw
touch events over 100–300 ms of jittery cellular means holds misread as taps whenever the network
hiccups.

Recognition therefore lives in the phone client — where it **already does**: the touch layer
discriminates tap / press-hold-drag / two-finger locally and animates the cursor ring. What is
missing is that it *flattens* the result into synthetic RFB mouse events. The wire should carry
**semantic gestures**: `(gesture, x, y)`, with the server mapping gesture → presentation → command.

The vocabulary is frozen into the client protocol. That is acceptable because it is deliberately
tiny — and it is a protocol decision, so it belongs here:

| gesture | meaning |
|---|---|
| `tap` | invoke the declared default command |
| `hold` | open the applicable-command menu |
| `two-finger` | reserved (pan / scroll) |

There is no hover. "Pointer over presentation of type T" has nothing to hang on, which is a second,
independent reason the refusal of translators is not merely discipline.

## Rule 5 — applicability, and safe defaults

A command declares argument types, a name, and an **authorization predicate**. A presentation has a
type. One flat rule:

- **`tap` invokes the declared default command for `(type, view)`.**
- **`hold` lists applicable commands.**

Hardening:

- **Defaults are declared, never derived.** Deriving from "most specific applicable" is the seed of
  translator-creep: once ordering gets clever, we have rebuilt what we refused.
- **A default must be non-destructive** — drill-in, inspect, expand. Idempotent or read-only.
- **Destructive commands are hold-menu only**, with confirmation when irreversible. One mis-tap on
  a phone must not revoke a device.
- **Authorization is enforced at invocation, in the gateway.** Menu filtering is courtesy, not
  security. The GUI must not become a second enforcement point that someone later trusts.

## Rule 6 — view state is presentations too

Scroll offset, selection, expanded/collapsed. It lives server-side (the client is a dumb glass),
it is per-*view* not per-object, and the reconciler must preserve it across rebuilds. This is a
fourth line in rule 1, not a new system: **viewport and selection are presentations, keyed to their
parent, surviving reconciliation.**

## The one bite of the seductive idea

"Every view is an inspector" is the Naked Objects thesis with the Self aesthetic. Its pure form
dies on three things: generic views are legible but not *designed* (the value of an interface is
mostly editorial — emphasis, sequence, omission); writing through non-invertible projections is
unsolved; and views are really onto *queries*, which turns the UI kit into a database needing
incremental view maintenance.

CLIM already contains the safe embodiment, and it is the part everyone forgets: **`present`
dispatches on `view`** — `present (object type view)`.

- The **default method** is a MOP-derived slot walk. Any new type in the image is immediately
  browsable, with zero UI code.
- **Designing a UI** means specializing `present` for `(enrollment, table-view)`.

So "every view is an inspector" is true as the *degenerate case*, and apps are editorial overrides
layered method by method — Naked Objects' free-admin-panel property without betting the
architecture on lenses. Steal GToolkit's pane composition (Miller columns) when panes arrive.

Reads are projections; **writes are commands**. The asymmetry is real, and it is the design we are
already running: `revoke` exists once, authorization-checked, in the gateway.

## Why the device manager is client one

It exercises every rule in ~200 lines, and it pays for the abstraction immediately:

The gateway already has a command set on a type — `link`, `devices`, `revoke <prefix|all>` — with
real applicability rules (allowlist vs. enrolled device). With commands as first-class objects, the
**DM interface, a CLI, and the glass GUI become three presentations of one command set**, with
authorization written once. Today a GUI would duplicate both `revoke`'s logic and its authorization
check. That is the concrete argument for presentations+commands over a widget kit.

- keyed identity — pubkey, naturally stable, and `eq` provably fails
- fixed, grid-snapped extents — a row per enrollment
- tap → inspect (safe default), hold → revoke (destructive, confirmed)
- authorization at invocation, in the gateway
- view state — selection survives the file changing underneath

## Extract under load, do not design up front

Layout, theming, pane composition, animation: **extract when a second client needs them.** Three
clients decide whether the core is right — device manager, loom's chrome (retiring the flickering
immediate-mode code), and the inspector (proving presentations are real). Fewer than three and we
are guessing.

The failure mode is building a framework in the abstract. The presentation concept itself is tiny;
the gravity well around it is not.
