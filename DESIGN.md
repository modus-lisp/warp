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

Keys are scoped to the parent, so **re-parenting reads as `gone` + `appeared`, not `moved`** — a
deliberate choice, recorded here so nobody later "fixes" it. `:moved` is for a subtree that
translated within its parent, which is the case the transport can make cheap.

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

The grid is **framebuffer-space, not logical points.** The browser already scales the video to the
viewport and applies a pinch-zoom transform, so if a scale factor ever appears between layout and
encoder the snap must stay with the macroblocks rather than drifting with the logical units.

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

### The stream carries state, not events

**Deltas supersede by key.** If a presentation changes three times while over budget, the consumer
receives the latest state *once* — never a replay of intermediates. The stream's contract is
*converge to current state under budget*, nothing more.

The pixel encoding is already built this way, structurally: a dirty macroblock is a **bit in a
vector, not an entry in a queue**, and `capture-take` hands over the *current* planes rather than a
history. Three changes between frames cost one bit. The semantic encoding must be deliberately the
same shape.

A consumer that wants event history — audit, undo, "what happened while I was away" — is asking for
a **different product**, and should read the command log rather than the presentation stream. Saying
so now is what stops this protocol from being quietly bent into an event bus later, which is the
standard way delta protocols die. `as-of` makes coalesced, deferred delivery honest for free: the
consumer can see it is holding old news.

### Resync is a delta kind

Every real delta protocol needs an answer to *connected late / fell too far behind / lost state*: a
**snapshot** of the full subscribed projection, itself under budget and chunked by the same deferral
discipline, carrying a **generation** marker.

The pixel encoding already contains both halves, which is why this is a naming exercise rather than
a design one:

- a periodic keyframe (`key-interval`) so a late or recovering viewer resynchronises;
- on capture reconnect, `fill dirty-mbs 1` — re-announce the entire working set while retaining the
  planes;
- and our progressive whole-screen refresh (19 frames × 17.7 KB) *is* a chunked snapshot under
  budget, already validated.

One rule the pixel path gets for free and the semantic path must state, because it is where
key-mismatch bugs breed: **snapshot chunks carry the generation, and deltas older than the current
generation are discarded.** Otherwise a live change arriving mid-snapshot can be applied on top of a
chunk that already reflects it, or under one that supersedes it.

## Rule 5 — gestures are recognized at the edge; the wire carries semantics

Press-hold is a *timing* discrimination (down, ~400 ms, no movement). Timing it server-side across
100–300 ms of jittery cellular means holds misread as taps whenever the network hiccups.

Recognition therefore lives in the client — where it **already does**: the phone's touch layer times
tap / press-hold-drag / two-finger locally and animates the cursor ring. What is missing is that it
*flattens* the result into synthetic RFB mouse events. The wire should carry `(gesture, x, y)`, and
the server maps gesture → presentation → command.

| gesture | meaning |
|---|---|
| `tap` | invoke the declared default command for the presentation under the finger |
| `hold` | open the applicable-command menu — **hold-drag-release is one continuous gesture**: hold opens, dragging moves the selection, release invokes |
| `hold` on empty space | the **view's** own commands (refresh, revoke-all), or nothing if it declares none |
| `two-finger` | **pan / scroll — v1, not reserved** |

The enum is closed. `hold-drag` is the menu interaction, not drag-and-drop; if dragging *objects*
is ever wanted it needs a new verb rather than an overload.

**Two-finger scroll is client one, not future work.** Rule 2 exists *because* of scroll, and a list
is the case that exercises `:moved`, budget-under-continuous-input, and idle drain simultaneously —
which is exactly where the strand-the-remainder bug lived. It is the first honest test of the
protocol.

> These are the gestures of a *warp surface*. The glass desktop's RFB passthrough keeps its own
> pointer semantics (where press-hold arms a drag); the two vocabularies coexist because they are
> different consumers of the same client.

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

Scroll offset, selection, expanded/collapsed. Server-side (the client is a dumb glass),
per-*consumer*-per-*view* not per-object, and preserved across rebuilds — **keyed the same way
presentations are.** A fourth line in rule 1, not a new system. (Per *consumer*: see rule 8. Two
people looking at one list have one list and two selections.)

## Rule 8 — the consumer is the seat; the projection is shared

`warp-glass::surface` currently holds one shared thing and a pile of private ones:

```lisp
rows-fn    ; () -> the current result-set        <- THE PROJECTION.  shared.
stream     ; what has been emitted so far        <- what THIS consumer holds
budget     ; 400                                 <- THIS consumer's link
selected menu                                    <- rule 7 view state
invoker    ; :allowlist                          <- WHO is asking
fb                                               <- where it lands
```

One field is the thing being looked at. Every other field is a property of *the one looking*. With a
single consumer nothing forces the distinction, which is exactly why it has to be written down before
the second one arrives.

> **The projection is pulled once per epoch and shared. Every other field is per consumer.**

Not "once per tick and fanned out" — that wording implies a shared clock and a driver, and there is
neither: glass's WM polls each window's `dirty-p`, and `run` gives every seat its own thread. A fast
seat and a slow seat have different ticks and neither may block the other. The invariant is
**per-consumer-epoch idempotence**: the query runs only when a caller needs a newer epoch than the
one it holds, so the read is a cached one, not the destructive one the mixer analogy warns about.
Query count is the *max* of the consumers' tick counts, never the sum.

glass reached the same split from the other side: a seat is one person watching a session — own
screen, own pointer, own focus, own clipboard, own mix — over shared windows and shared window
*sizes*. **A glass seat and a warp consumer are the same object**, and the fields line up one for one.

### The stream is a memory, and memories are not shared

The efficiency argument (N consumers should not run N copies of the same query) is the weak one.
The correctness argument is that **`stream` is the consumer's memory of what it has already been
told.** Share one between two consumers and a change is emitted once, painted to whichever ticked
first, and the other is never told — it is not stale, it is *wrong*, and it looks correct because the
code emitted the delta exactly once as designed. A late joiner is the same bug wearing a different
hat: its memory must start empty and get a snapshot, not inherit someone else's high-water mark.

This is the third time this decomposition has been forced, and the third time the destructive-read is
the tell:

| plane | pulled once | fanned out per consumer |
|---|---|---|
| compositor | the window paints itself | each seat composites its own screen |
| mixer | `(funcall (src-thunk s))` **advances** the source | each seat sums with its own gains |
| warp | the query runs | each consumer diffs against its own stream, under its own budget |

The mixer is the cautionary one: two clocks pulling the same source take *alternate* frames and both
listeners hear it at double speed with half missing. `stream` is the same hazard in a slower coat.

### Where the boundary goes: the projection holds the QUERY, not the layout

The first draft of this rule said two consumers over one projection could scroll independently. That
was wrong, and implementing it is what proved it: `rows-fn` returns *laid-out presentations* — extents
already computed from a scroll offset and a viewport height — so sharing a projection necessarily
shares scroll **and window size**. It also contradicted this document two sections up ("views
subscribe to result-sets") and `present.lisp`'s own header ("PRESENT returns CONTENT, not pixels —
layout then assigns extents"). `rows-fn` fuses the result-set with its layout.

**The boundary belongs one level lower:**

| | |
|---|---|
| **projection** | the query, and the domain objects it returns. `rows-fn : () -> objects` |
| **consumer** | `present`, layout, diff, encode — and therefore scroll, viewport, and extents |

The forcing argument is the same one that motivates the rule: **encodings per consumer.** A DOM
consumer does its own layout in a browser with its own viewport; a token consumer has no extents at
all. Neither can share a macroblock consumer's laid-out rows. Per-consumer layout is not a refinement
of "encodings per consumer" — it is what that phrase *means* once there is a second encoding.

Two consequences worth stating, because they are what the fused version got wrong:

- **`view` is on the projection, not the consumer** — while layout is fused. `present` dispatches on
  `view`, so the shared rows' fingerprints were *derived under it*, and a consumer holding a different
  view could not diff them. A second view is a second projection. When layout moves per consumer,
  `view` moves with it, and this restriction lifts.
- **Co-presence stays a window question.** Two seats holding one glass window share its content
  framebuffer, so they share scroll — that is two people at one screen and warp should not invent a
  way to disagree about it. What they do not share is stream, budget, invoker, selection, or menu.

> **Status:** shipped fused (`d0ed2bf`, `b4cf950`) — two consumers share scroll and viewport because
> they are two seats at one window. Splitting layout out of the projection is its own change, with
> its own no-change proof. It is half-built already: `monitor-rows` is separate from
> `monitor-presentations`, and `layout-list` is in core.

### What this makes real

- **`invoker` stops being a constant.** Seat A the owner, seat B a guest, one list, and the hold-menu
  offers each the commands they may actually invoke. Rule 6 is unchanged — enforcement stays at
  invocation, menu filtering stays courtesy — but it stops describing a hypothetical.
- **The agent stops being a special case.** Give a consumer an *encoding* (macroblocks for a retina,
  DOM for a browser, tokens for a model) and a *negotiable* flag, and "a context window is a
  viewport" is no longer an analogy: an agent is a consumer with a token encoding, its own budget,
  its own stream, and a narrower invoker. Consumer-negotiated slices (below) is then the one
  capability that differs, rather than a separate architecture.
- **Rule 7 gains its fourth line.** View state is per-*consumer*-per-view, keyed the way
  presentations are.

### Attaching is not a resync

A consumer arrives with an empty stream at generation 0, and that emptiness *is* its initial
snapshot: there is nothing older to discard, so **attaching does not bump the generation.** `resync`
bumps it, and stays for the case it was written for — a consumer that fell too far behind. Stated
because the alternative is defensible and silently choosing it would break the discard rule's
meaning.

### Doing it

Split `surface` into a shared projection and a per-consumer view, keeping delegating accessors so the
single-consumer path is untouched, and prove the one-consumer case is unchanged before adding a
second. glass ran exactly this refactor twice in one week; the method that worked both times was
copy-on-write defaults plus a no-change proof — a scripted session dumped as (damage box, hint, hash
of every pixel) per step, compared line for line against the previous build.

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

**Time is an input to queries.** `exp > now` changes when *nothing changes*: an enrollment crosses
its expiry with zero writes and zero mutations, and the result-set is silently wrong until something
unrelated re-runs the scan. So the cheap policy, chosen now because it is also the
forward-compatible one:

> `now` **quantizes to a tick** (60 s is ample for expiries), the tick is a **subscribable source**,
> and crossing it emits ordinary `gone` / `changed` deltas.

The gateway currently hides this by evaluating `(> exp (%unix-now))` at call time — correct, but it
means the *view* has no way to learn that a row lapsed. When differential dataflow slides underneath,
"time is just another input relation" is exactly how it wants this modelled.

## Consumer-negotiated slices

One asymmetry worth stating, because it is the only place the consumers genuinely differ: **an agent
can renegotiate its own viewport; a human cannot.** A model can ask for fewer fields, different
rows, deltas-only. A human's viewport is fixed by physics and their attention is not re-targetable
on request.

So: the protocol is shared, but *slice negotiation* is a consumer capability. Human surfaces are
curated — someone chose the slice in advance. Agent surfaces are negotiated. Same tree, same deltas,
same budget discipline — and under rule 8, the same *object*: negotiability is a flag on a consumer,
not a second kind of surface.

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
