# warp — typed projections over a keyed delta protocol

*warp: the threads held under tension on the loom — the retained structure the weft passes
through.* [weft](../weft) is the web engine; warp is the retained UI tree.

A UI system for [glass](../glass) apps in pure Common Lisp, on [gesso](../gesso) (2D vector) and
[scribe](../scribe) (text). Not in loom (loom is an app), not McCLIM (retained but imperative, and
its size is the problem).

## The core is a protocol, not a renderer

The temptation is to describe warp as a widget kit with a clever repaint strategy. That gets the
layering backwards. What warp actually is:

> **A keyed, budgeted, staleness-annotated delta protocol over typed projections — with encodings
> per consumer.**

Deltas are `changed` / `moved` / `appeared` / `gone`, against a *subscribed projection*, under a
per-consumer byte budget. Macroblocks are the encoding for retinas; tokens would be the encoding
for a model. Neither is privileged. `present` is not a rendering step — it is a **compression
decision**: which slice of the object graph travels toward a consumer with finite intake.

This is why the rules below look like transport rules. They are. A context window is a viewport;
attention is priced per token the way our frames are priced per macroblock. A consumer that cannot
afford the whole graph per tick needs a working set, deltas against what it already holds, and a way
to know what is stale — whether it has eyes or not.

### Two ideas, one refusal

- **Presentations** (CLIM): output is *typed objects that were displayed* —
  `(key, type, object, extent, as-of, render)`.
- **Commands** (CLIM): declared against argument *types*, with an authorization predicate.
- **Refused**: presentation translators, nested input contexts, `accept`-driven parsing. That
  machinery is where CLIM's size lives, and our gesture vocabulary cannot express it anyway.

Reconciliation is not a modern import — it is CLIM's `updating-output` with
`:unique-id`/`:cache-value`. It is also the part of CLIM with the worst bug reputation, and the
reason is identity. Hence rule 1.

### Evidence, not theory

The transport half of this protocol already exists and was tuned end to end under cellular
pressure. Measured on a real 1280×800 desktop:

| | before | after |
|---|---|---|
| static frame | 76 KB / 300 ms | **629 B / 1 ms** |
| a whole-screen change | one 143 KB frame (~570 ms in flight) | **17.7 KB max frame**, 19 progressive frames |
| delivered rate | ~0.5 fps | **24 fps** |

Cellular was not a special case; it was the latency manifold showing itself first.

## Rule 1 — identity is a declared key function

Reconcile matches on `(parent, key)`. **The default key is a per-type key function declared
alongside the type.** Raw `eq` is the fallback *only* for objects with genuine identity.

Keyed identity is what makes deltas possible at all: `enrollment ab3f changed` instead of reshipping
the list is the same trick for a model's context as for the encoder's skip bits.

**`eq` as the default would be a trap, and client one proves it.** Enrollments come from a file that
`sync-devices` re-reads by `clrhash` + reload — there are no persistent objects, only hash-table
entries. `eq` would fail on every render, everything would look new, and we would emit full-frame
damage forever while the code looked correct. It would "work" by accident today and break on client
two. Unstable keys mean every update looks like total novelty and the consumer pays full price to
relearn a world that did not change. Device manager key: **the pubkey**.

## Rule 2 — `moved` is a delta kind

Fixed extents bound the cost of a *mutation*. They do nothing for **scroll**, which translates every
row and would naively dirty the whole viewport.

So a subtree may report **`:moved (dx dy)`**, distinct from `:changed`. For pixels this is RFB
**CopyRect** and, later, VP8 motion vectors. For an agent it is the exact twin: *"these fifty rows
moved, contents unchanged"* as one assertion instead of fifty re-sends. Scroll and re-sort are cheap
**semantically**, not merely as motion vectors.

> **Status:** the pixel payoff is not there yet. Our capture marks the CopyRect *destination* dirty
> and the encoder re-codes it with ZEROMV, so a translation currently costs what a change costs.
> `:moved` is designed in now because it is a *wire* concept and retrofitting it after clients exist
> would be a migration. It goes cheap when VP8 motion vectors land.

Without this the transport argument holds for edits and collapses for navigation — and navigation is
most of what a finger does to a list.

## Rule 3 — extents snap to the macroblock grid

The chain ends in 16px macroblocks. Sub-grid precision is precision the encoder cannot use: a 20px
row dirties two macroblock rows for one row of content. **Row heights and pane edges snap to 16 at
layout time.** One line of layout policy; free now, a migration later.

## Rule 4 — budget, deferred remainder, idle drain, and ordering

Every consumer gets an update budget, and a delta that does not fit is **deferred, not dropped**.
Two disciplines that sound obvious and were both learned the hard way:

- **Idle drain.** Deferred deltas must flush when nothing new arrives. Our first implementation
  only carried them forward on frames that had *new* content, so when a drag stopped, the
  undelivered remainder was stranded forever — the viewer saw two scan lines of a change and never
  the rest. A budgeted protocol without an idle drain silently loses data.
- **Unseen before prettier.** When both are owed, deliver *content the consumer has never seen*
  before *improving quality of what it has*. We had to make the pending-drain outrank the idle
  refinement pass explicitly; correctness of the working set outranks fidelity of it.

## Rule 5 — gestures are recognized at the edge; the wire carries semantics

Press-hold is a *timing* discrimination (down, ~400 ms, no movement). Timing it server-side across
100–300 ms of jittery cellular means holds misread as taps whenever the network hiccups.

Recognition therefore lives in the client — where it **already does**: the phone's touch layer times
tap / press-hold-drag / two-finger locally and animates the cursor ring. What is missing is that it
*flattens* the result into synthetic RFB mouse events. The wire should carry `(gesture, x, y)`, and
the server maps gesture → presentation → command.

| gesture | meaning |
|---|---|
| `tap` | invoke the declared default command |
| `hold` | open the applicable-command menu |
| `two-finger` | reserved (pan / scroll) |

There is no hover, so "pointer over presentation of type T" has nothing to hang on — a second,
independent reason the refusal of translators is not merely discipline.

## Rule 6 — applicability, and safe defaults

- **`tap` invokes the declared default command for `(type, view)`. `hold` lists applicable ones.**
- **Defaults are declared, never derived.** Deriving from "most specific applicable" is the seed of
  translator-creep: once ordering gets clever, we have rebuilt what we refused.
- **A default must be non-destructive** — drill-in, inspect, expand.
- **Destructive commands are hold-menu only**, with confirmation when irreversible. One mis-tap on a
  phone must not revoke a device.
- **Authorization is enforced at invocation, in the gateway.** Menu filtering is courtesy, not
  security. The GUI must not become a second enforcement point someone later trusts.

## Rule 7 — view state is presentations too

Scroll offset, selection, expanded/collapsed. Server-side (the client is a dumb glass), per-*view*
not per-object, and preserved across rebuilds — **keyed the same way presentations are.** A fourth
line in rule 1, not a new system.

## Staleness and cost are first-class

The classic sin of layered systems is a synchronous-looking interface over an asynchronous world,
forcing every consumer to infer latency by suffering it. Cheap fix:

- Every presentation carries its **`as-of`**.
- Every command and drill-in carries a **cost class**.

A human surface renders that as a stale-tint or a disclosure affordance; an agent reads it as
scheduling data — refresh before acting, batch these, do not block on that. Same field, two
renderings, and the latency manifold becomes part of the semantic tree instead of an ambient
betrayal.

The existing command set already has three genuine classes: `devices` is a file read (instant),
`revoke` a file write plus gateway sync (fast), `link` a Nostr round trip (seconds).

## Views are query-shaped — an explicit IOU

Query-shaped views (`expiring-this-week`, `agents-currently-failing`) are where *which slice
travels* is decided. Maintaining them by re-running the query and diffing is a simulation of
incrementality that degrades linearly with data size. The honest floor under this protocol is
**incremental view maintenance** (differential dataflow).

Not release one. But it is no longer "a second project the bandwidth economics might fund" — it is
load-bearing under a protocol we are committing to for *every* consumer. So, cheap now to avoid
re-plumbing later:

> **Views subscribe to result-sets, not to objects they happen to enumerate.**

The device manager subscribes to a query (*enrollments where exp > now*), even though its
implementation is a file scan. The engine can slide underneath without touching clients.

## Consumer-negotiated slices

One asymmetry worth stating, because it is the only place the consumers genuinely differ: **an agent
can renegotiate its own viewport; a human cannot.** A model can ask for fewer fields, different
rows, deltas-only. A human's viewport is fixed by physics and their attention is not re-targetable
on request.

So: the protocol is shared, but *slice negotiation* is a consumer capability. Human surfaces are
curated — someone chose the slice in advance. Agent surfaces are negotiated. Same tree, same deltas,
same budget discipline.

## The one bite of "every view is an inspector"

The pure form (Naked Objects, Self, lenses) dies on three things: generic views are legible but not
*designed* (the value of an interface is mostly editorial — emphasis, sequence, omission); writing
through non-invertible projections is unsolved; and views are onto *queries*, which turns the UI kit
into a database.

CLIM already contains the safe embodiment, and it is the part everyone forgets: **`present`
dispatches on `view`**.

- The **default method** is a MOP-derived slot walk: any new type in the image is immediately
  browsable, with zero UI code.
- **Designing a UI** means specializing `present` for `(enrollment, table-view)`.

Reads are projections; **writes are commands**. That asymmetry is real, and it is the design we are
already running: `revoke` exists once, authorization-checked, in the gateway.

## View lifecycle: playground → committed

Views have a **status** (`playground` or `committed`) and a version; default glass surfaces render
only committed ones. A metadata field and a filter, not a new system — but it carries the trust
boundary.

Humans get **habituation** from an interface: spatial and muscle memory, revoke being third in the
menu today because it was third yesterday. A view that reshapes per-utterance is maximally
responsive and minimally learnable. Worse, rule 6 *depends* on stability — "destructive commands
behind hold" only protects if layouts do not shift under the finger. Adaptive UI is where mis-taps
come from.

And ephemeral views are unauditable in principle: a generated view that happens to omit the field
that would have alarmed you is, in the moment, indistinguishable from a good one. Committed views
are code — diffable, reviewable, blameable. **Promotion is code review for perception.**

So the human UI is not a different system from a generated one; it is the same artifact at a
different temperature. Ephemeral where exploration happens, frozen where trust is required.

## Generated views: freedom over projection, none over invocation

Rule 6 was written as guardrails against mis-taps, but it reads verbatim as **lint constraints on
model-authored `present` methods**: a generated view cannot make a destructive command a default,
cannot bypass confirmation, cannot widen authorization — because commands are objects with declared
safety properties and the view layer cannot override them, and enforcement is at the gateway
regardless of surface.

**Generate the seeing, never the permitting.**

## Client one: the device manager

It exercises every rule in ~200 lines, and it pays for the abstraction immediately. The gateway
already has a command set on a type — `link`, `devices`, `revoke <prefix|all>` — with real
applicability rules (allowlist vs. enrolled device). With commands as first-class objects, the **DM
interface, a CLI, the glass GUI, and an agent become surfaces of one command set**, with
authorization written once. Today a GUI would duplicate both `revoke`'s logic and its authorization
check.

- keyed identity — pubkey; `eq` provably fails
- query-shaped subscription — *enrollments where exp > now*
- fixed, grid-snapped extents — one row per enrollment
- `tap` → inspect (safe default); `hold` → revoke (destructive, confirmed)
- authorization at invocation, in the gateway
- view state — selection survives the file changing underneath
- ships as warp's first **committed** view, because a human must trust it with revoke

## Extract under load

Layout, theming, pane composition (steal GToolkit's Miller columns), animation: **extract when a
second client needs them.** Three clients decide whether the core is right — device manager, loom's
chrome (retiring the flickering immediate-mode code), and the inspector (proving presentations are
real). Fewer than three and we are guessing.

The failure mode is building a framework in the abstract. The presentation concept is tiny; the
gravity well around it is not.
