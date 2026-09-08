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

> **What met the code: "reconcile matches on `(parent, key)`" was never true.** Client two went
> looking for the parent-scoping this rule opens with, on the understanding that the reconciler had
> it and no flat client had used it. It does not have it. `%diff` holds **one** `delivered` table,
> keyed by `p-key` and by nothing else, and there is no parent anywhere in the reconciler.
>
> Three things looked like the feature and all three are something else:
>
> - **`p-children` is dead.** It is a slot on `presentation`, it is exported, and it is read by no
>   line of code in warp, warp-glass, warp-dom, the monitor, or any test. A projection that put its
>   nesting where the slot's name says to put it would ship its roots and silently drop every
>   descendant. Asserted now, in `t/files.lisp`, so it stops looking like a feature.
> - **`presentation-key`'s signature is `(type object)`** — a key function *cannot see the parent*.
>   "The default key is a per-type key function" and "keys are scoped to the parent" cannot both be
>   satisfied by the key function alone, and the second one loses.
> - **the DOM's `(parent . after)` is in `p-extent`**, which is *position*, not identity. Its own
>   comment calls it "rule 1's keys-are-scoped-to-the-parent written as data" and that is a
>   different claim: two nodes in different containers with the same key still collide in
>   `delivered`, whatever their extents say.
>
> The fix client two used needs no change to core: **give the object its parent and cons the two
> together in the key function** — `fs-row` is an entry plus the column it is in, and the key is
> `(column-path . entry-path)`. Scoping happens where rule 1 says identity is declared. It works,
> and the honest reading of *why* is in rule 9's status below: it is sufficient for correctness and
> it is not a diff scope.
>
> The observable case is smaller than it sounds and it is not contrived. A column **header**'s own
> key component is the constant `:head`, identical in every column; only the parent separates them.
> Entry rows happen not to need it, because a full pathname is already globally unique — so on a
> filesystem the scoping is belt-and-braces for the rows and load-bearing for everything else.
> Change the entry component to the display name, which is what a display-first implementation
> reaches for, and two columns holding a `shared.txt` collide immediately.

## Rule 2 — `moved` is a delta kind

Fixed extents bound the cost of a *mutation*. They do nothing for **scroll**, which translates every
row and would naively dirty the whole viewport.

So a subtree may report **`:moved (dx dy)`**, distinct from `:changed`. For pixels this is RFB
**CopyRect** and, later, VP8 motion vectors. For an agent it is the exact twin: *"these fifty rows
moved, contents unchanged"* as one assertion instead of fifty re-sends. Scroll and re-sort are cheap
**semantically**, not merely as motion vectors.

> **Status:** the pixel payoff is still not there — our capture marks the CopyRect *destination*
> dirty and the encoder re-codes it with ZEROMV, so a translation costs what a change costs, until
> VP8 motion vectors land. **But `:moved` has paid, in the encoding it was not designed for.** The DOM
> consumer has no absolute coordinates, so rows a scroll did not touch genuinely do not move: a
> one-row scroll is 1 `gone` + 1 `appeared` + **1** `moved`, against the framebuffer's 1 + 1 + **13**.
> Designing a wire concept in before its first client was the right call for the wrong client.
>
> Two corrections that encoding forced. A **translation vector is a pixel notion** — a browser
> reorders nodes rather than shifting them — so `moved-p` may answer a bare `t`, and `(dx dy)` is the
> framebuffer's dialect rather than the protocol's. And **`extent` is over-named**: only the
> framebuffer's position is a rectangle. The DOM's is `(parent . after-key)` — precisely what
> `insertBefore` takes. Position is *the encoding's claim*, and the tuple in "Two ideas, one refusal"
> should be read that way.

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
- **Ordering within a pass is by priority only** — and an encoding whose positions are *relative*
  must therefore tolerate an anchor it has not been told about yet. `%diff` emits within a band in
  reverse layout order, so appending two rows sends `r05 after r04` **before** `r04`; the DOM client's
  first screenshot rendered a row second that the wire said was last, silently. Emitting in layout
  order would fix that case and is still not sufficient: **the budget can defer an anchor to a later
  pass entirely**, and no server-side ordering repairs that. So the obligation is the client's — park
  an unplaceable node *out of the document* until its anchor arrives, never in a position you
  invented. A framebuffer never noticed because absolute coordinates have no anchors.

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

## The interaction language is not the wire vocabulary

Rule 5 closes an enum, and that enum has quietly been read as a statement about what a *person*
may do. It is not. It is a statement about what the *wire* carries, and the two are different
layers that happen to have been the same size so far because every client has been simple.

> **The wire vocabulary is an architecture decision. The interaction language is a design
> decision. A closed enum on the first does not close the second.**

The distinction matters because people arrive with expectations formed by iOS, Android, Windows
and macOS, and those expectations are not decoration — a swipe that does nothing reads as a
broken app, not as a minimal one. Nothing about warp requires refusing them.

### The decomposition rule

The design already uses this argument once without naming it. Rule 5 says hold-drag-release
"decomposes into a `hold` plus a `tap` on a menu item, **which is why Rule 5's vocabulary needed
no new verb**". That generalises, and it is the whole mechanism:

> A familiar interaction is admissible when it decomposes into gestures the wire already has,
> plus state the client already holds.

Worked, for the ones people will reach for:

| what a person does | how it decomposes | needs |
|---|---|---|
| swipe a row to reveal actions | client reveals; the revealed action is a presentation; tapping it is a `tap` | nothing new |
| swipe-to-delete | as above, onto a `destructive` command — which rule 6 already routes through confirmation | nothing new |
| pull to refresh | the client asks for a `resync` (rule 4), which is already a delta kind | nothing new |
| back | the client pops its own navigation state, or taps a `chip` — which is why chips became presentations | nothing new |
| double-tap | two `tap`s the client coalesces, or a distinct local meaning | nothing new |
| momentum scrolling | `two-finger`, with the client extrapolating and reporting the viewport it lands on | nothing new |
| long-press preview | `hold` opens a menu; a peek is a menu whose item is an `opaque` | nothing new |

None of that is a protocol change. All of it is a client that recognises more than it forwards —
which is exactly what rule 5 already asks for, one step further along.

### Where it genuinely stops

Two shapes do not decompose, and pretending otherwise is how a protocol acquires a coordinate
channel by accident.

**Continuous manipulation with live feedback.** Drag-to-reorder, pinch-to-zoom, and scrubbing by
dragging all need the *thing being manipulated* to follow the finger at frame rate. The wire
carries semantics, not coordinates, and a budgeted delta stream at 4 Hz is not a feedback loop.
The honest options are: the client animates locally and sends ONE committed message at the end
(reorder becomes a `cmd` carrying the new position — a picker, not a drag); or the interaction is
declined. What must not happen is a stream of positional updates, because that is a coordinate
channel wearing a different word, and §10.5's "there are no coordinates on this wire" is load-
bearing for every encoding that is not a browser.

**Free-form text.** Tap, hold and two-finger can select from choices; they cannot compose a
string. Every parameter in warp is enumerable today and the picker (`:values` on a command) made
that comfortable. A genuinely free-form value — a search box, a rename — has no expression here at
all, and inventing one is a protocol question rather than a widget question. It is the next thing
that will force one.

### When they conflict, the vision wins

Familiarity is a real cost to ignore, so this is a rule rather than a preference:

> Where a platform convention and warp's long-term shape conflict, resolve in favour of the
> long-term shape — and say which convention was declined and why.

The reason is not purity. Many conventions exist *because a widget kit was in-process*: they
assume a toolkit that can measure text, hit-test pixels, animate at will and lie about latency
because there is none. Reproduced over a wire, those same conventions become a translator layer,
which is the thing "The core is a protocol, not a renderer" refuses in its opening paragraph.
Copying them out of habit is how a delta protocol turns back into a remote widget kit.

The test to apply, when tempted: **does this convention still make sense when the thing drawing
it is a framebuffer 200 ms away that is told about changes and not about frames?** Hold-drag-release
passes. Drag-to-reorder does not, and becomes a picker. Hover does not exist at all, which rule 5
already notes for an unrelated reason and which is the same finding arriving twice.

## Rule 6 — applicability, and safe defaults

- **`tap` invokes the declared default command for `(type, view)`. `hold` lists applicable ones.**
- **Defaults are declared, never derived.** Deriving from "most specific applicable" is the seed of
  translator-creep: once ordering gets clever, we have rebuilt what we refused.
- **A default must be non-destructive** — drill-in, inspect, expand.
- **Destructive commands are hold-menu only**, with confirmation when irreversible. One mis-tap on a
  phone must not revoke a device.
- **Authorization is enforced at invocation, in the gateway.** Menu filtering is courtesy, not
  security. The GUI must not become a second enforcement point someone later trusts.

> **Status: literally true now, and the phrasing turned out to be exact.** warp runs *inside* the
> glass-webrtc gateway, over the enrolment file that gateway writes, and `revoke` is refused by
> `invoke` on the same process that would have refused the DM. An allowlisted owner is offered it;
> an enrolled guest is not, and a guest that names it anyway over the wire gets nothing.
>
> **What the rule did not say, and had to learn: where the invoker comes from.** The gateway already
> classified every connection — `code`, `allowlist`, `device`, first match wins — and reusing that
> string is the obvious move and is wrong in *both* directions at once. An owner who arrives holding
> a magic link classifies as `code`, so mapping it demotes the owner; a guest who was sent the same
> link also classifies as `code`, so mapping it promotes the guest. One string, two opposite
> authorities, because it was computed to answer a different question (*may this connection open at
> all*) than the one the menu asks (*who is this*).
>
> So, as a fourth line under this rule:
>
> **The invoker is the output of the same predicate the policy is written against — never a nearby
> value computed for a different question.** Here that is literally `authorized-p`, the function the
> DM surface calls `admin`. Two surfaces, one predicate, and no way for them to drift; a second
> answer to "who is this" is the same failure as a second answer to "may they", one step earlier.

## Rule 7 — view state is presentations too

Scroll offset, selection, expanded/collapsed. Server-side (the client is a dumb glass),
per-*consumer*-per-*view* not per-object, and preserved across rebuilds — **keyed the same way
presentations are.** A fourth line in rule 1, not a new system. (Per *consumer*: see rule 8. Two
people looking at one list have one list and two selections.)

## Rule 8 — the consumer is the seat; the projection is shared

`warp-glass::surface` — the whole UI, before this rule — held one shared thing and a pile of private
ones:

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

(Kept as written, because it is the argument. Both halves have since moved: `rows-fn` returns
*objects* rather than a laid-out result-set, and `view` — absent above — went to the consumer with
layout. See "Where the boundary goes" below.)

> **The projection is pulled once per epoch and shared. Every other field is per consumer.**

Not "once per tick and fanned out" — that wording implies a shared clock and a driver, and there is
neither: glass's WM polls each window's `dirty-p`, and `run` gives every seat its own thread. A fast
seat and a slow seat have different ticks and neither may block the other. The invariant is
**per-consumer-epoch idempotence**: the query runs only when a caller needs a newer epoch than the
one it holds, so the read is a cached one, not the destructive one the mixer analogy warns about.
Query count is the *max* of the consumers' tick counts, never the sum.

glass reached the same split from the other side: a seat is one person watching a session — own
screen, own pointer, own focus, own clipboard, own mix — over shared windows and shared window
*sizes*.

### A consumer is whatever owns an encoding target — which is not always a seat

The first draft said a glass seat and a warp consumer are the same object. That is false, and moving
layout down is what exposed it: a consumer is bound to the thing it encodes *into*, and under glass's
seat model the content framebuffer belongs to the **window**, shared by every seat looking at it. So
two glass seats at one glass window are **one** warp consumer — sharing not only scroll (which this
rule wants) but stream, budget, `invoker`, selection and menu (which it explicitly does not).

The sharpened claim:

> **A consumer is whatever owns an encoding target.** For a browser that is a person; for a token
> stream it is a session; for glass it is a *window*, because glass seats deliberately share window
> content.

So "owner and guest see different hold-menus over one list" needs two **windows**, not two seats at
one window — which is the same answer glass gives for independent scroll, and consistent with
co-presence meaning two people at one screen. The identity `seat = consumer` holds exactly where a
seat has a private encoding target, and glass is precisely the case where it does not.

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

> **Status:** shipped. The seat/projection split landed fused (`d0ed2bf`, `b4cf950`); the boundary
> moved below layout in `84b967a`, so the table above is now what the code does. `rows-fn` returns
> objects, a `type-fn` says what a row *is* (a property of the result-set, not of the seat), and
> `present`, layout, extents, `view`, scroll and viewport are the consumer's — `lay-out` and
> `apply-deltas` generic on it, which is the seam a DOM or token encoding subclasses.
>
> **The `view` bullet above is spent.** Fingerprints are per consumer now, derived under its own view
> at its own offset, so two seats holding *different* views diff correctly against one projection and
> one query. A second view is no longer a second projection.
>
> **The protocol is in core.** All of the above first shipped inside `warp-glass`, and the consumer
> it shipped was framebuffer-shaped: `apply-deltas`'s only method needed an `fb`, the viewport
> defaulted off one, and `menu-presentations` measured itself against `glass:fb-width` — so a DOM or
> token consumer had to subclass a class in the glass package, and load glass, to reach a protocol
> that has nothing to do with pixels. `projection`, `consumer`, `pull`, `lay-out`, `apply-deltas`,
> `menu-presentations`, scroll, the menu model and `on-gesture` are `warp` now. `warp-glass` is one
> encoding: paint, pixel hit-testing, RFB input, menu geometry, and an `fb-consumer` whose target is
> a framebuffer. The names it used to own are imported and re-exported, so `warp-glass:tick` *is*
> `warp:tick` — the same symbol, not a wrapper — and no call site moved.
>
> Three judgement calls fell out of it, each one a place the old shape was lying:
>
> - **the viewport is ordinary slots.** It used to be read off the framebuffer, which quietly made
>   "how big is the view" a pixel question for every consumer. An encoding that knows better says so
>   by specialising `viewport-width` / `viewport-height`.
> - **the menu model is core; only its measurement is glass's.** Rules 5 and 6 are warp concepts, and
>   a consumer that reimplemented "destructive commands confirm first" would be the second
>   enforcement point rule 6 refuses. So core owns what a menu is and what tapping an item does, and
>   its default items carry **no extents at all** — geometry is a claim only an encoding can make.
>   Same line for input: resolving `(x, y)` to a presentation is the encoding's, what the gesture
>   *means* once it lands is `on-gesture`.
> - **a consumer with no encoding target cannot be constructed.** Not one that crashes the first time
>   a budget happens to let something through, which is indistinguishable from an intermittent
>   reconciler bug. `initialize-instance` refuses a consumer with no applicable `apply-deltas`.
>
> `t/core.lisp` is the standing proof: the entire round trip — pull, lay out, budget, defer, drain,
> menu, gesture, refusal, and a second encoding written in twelve lines — in an image where glass has
> never been loaded.
>
> `p-state` survives the copy-on-write machinery that motivated it, for a better reason: `present`'s
> signature is `(object type view)` with no room for a seat's state, and an encoding needs the two
> halves apart — one tints a row, another would write "(selected)".
>
> **There are three encodings now, and the third was written from outside.** `warp-dom` is a DOM in
> somebody else's browser: it depends on `"warp"` and nothing else, never loads glass, and supplies
> five methods. One projection, one query, a framebuffer painting macroblocks and a browser
> receiving JSON — `demo/two-encodings.lisp` asserts the query count, each consumer's own working
> set, and that the shared projection carries no position of any kind.
>
> Writing it from outside is what found the three places core was still shaped like a framebuffer,
> each of which is now a question asked of the consumer:
>
> - **`delta-cost (consumer delta)`.** Cost was `ceil(w/16)·ceil(h/16)`, so rule 4's budget was a
>   *pixel* budget for every consumer that would ever exist — and an extent-less one cost a flat 1,
>   which silently degenerates `budget` into "N deltas per pass". A browser's budget is **bytes on a
>   data channel**. glass deliberately does not specialise it: its unit *is* the default's.
> - **`moved-p (consumer old new)`.** Recognising a *reposition* is the encoding's, because only the
>   encoding knows what position is. A browser reorders siblings; it has no translation vector, so
>   `moved-p` returns a bare `t` and the new place travels on the presentation. And `p-extent` is
>   revealed as over-named: it is **this encoding's positional claim**, and only the framebuffer's is
>   a rectangle. The DOM's is `(parent . after-key)` — exactly what `insertBefore` takes, and rule 1's
>   "keys are scoped to the parent" written as data.
> - **`content-height`.** The scroll axis is in the consumer's own unit — pixels for a framebuffer,
>   **rows** for a browser that reports "I can show 12 and I am 3 down". One scroll slot, rule 7
>   intact, and the clamp lands in the right unit. That report is the
>   consumer-negotiated-slice capability arriving for a *human* surface, which the "agent can
>   renegotiate, a human cannot" section did not expect: a browser is more like an agent than like a
>   framebuffer here, because it knows its own viewport and a retina does not.
>
> And one bug the generalisation exposed rather than introduced: `p-macroblocks` read `p-extent` as
> four numbers and signalled on anything else, so core's own default cost *crashed* on a position it
> did not recognise. A pixel assumption with a stack trace attached is the same bug as one without.
>
> Rule 5 came out best: glass hit-tests pixels only because RFB flattened the gesture, and a browser
> sends back the key it already holds, so the whole of `hit` is three lines. The vocabulary needed no
> new verb — `hold-drag-release` decomposes into `hold` plus a tap on a menu item, because menu items
> are presentations.
>
> Per-consumer work went from ~0 to O(visible rows), as intended: ~0.25 µs a row, +2.5 µs per seat
> per tick for a 14-row viewport, against a 66 µs file query. **There is no crossover.** N seats over
> one projection cost `Q + N·(L+D)`; the N projections you would otherwise need for N scroll offsets
> cost `N·(Q+L+D)`. Sharing wins for every N > 1 whenever the query costs anything at all.

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

## Rule 9 — an app is a bundle of facets, and the consumer chooses

Everything above treats a projection as one thing rendered several ways. That is too small. What an
application actually publishes is a **bundle of optional facets**, and a consumer takes whichever it
can use:

| facet | what a consumer does with it |
|---|---|
| **data** | queries it — rows, types, commands, `as-of`, cost |
| **DOM** | renders it — a real browser, or weft in-image |
| **pixels** | blits it |

**All three are optional.** A terminal offers pixels, and perhaps a little data (its cwd, its
process). cortez offers pixels and nothing else — a Lisp machine's screen is a bit array and always
will be. The device manager offers data, from which the other two are made.

### The facets are not peers: some are derivable and one is terminal

    data ──present──▶ DOM ──weft──▶ pixels
    data ─────────present + paint─▶ pixels
    pixels ──────────────────────▶ (nothing)

`present`'s default method is a MOP slot walk, so **data yields a DOM for free** — any type in the
image is browsable with no UI code. weft turns a DOM into pixels, so an app that only speaks DOM is
never blocked from appearing on a desktop. But **nothing is derivable from pixels.** That asymmetry
is the whole of this rule, and it explains a thing we kept rediscovering: a surface app is invisible
to an agent not because agents are poorly served but because there is genuinely nothing there to
serve.

So the author's rule is one line:

> **Offer the highest facet you can afford, because everything below it can be manufactured and
> nothing above it can.**

### The consumer chooses, by capability and by budget

This generalises "Consumer-negotiated slices" below from *how much* travels to *in what form*. A
browser takes DOM if offered and pixels otherwise. An agent takes data if offered, DOM if not (cheap
to tokenise), and for pixels gets only what the app **supplied**. A VNC viewer takes pixels, always.

Two axes, and conflating them is what made "DOM versus VP8" sound like a choice when it is not:

    projection ──encoding──▶ pixels ──transport──▶ VNC · VP8/WebRTC
                           ──encoding──▶ DOM    ──transport──▶ data channel
                           ──encoding──▶ tokens ──transport──▶ an agent

VNC and VP8 are **transports of the pixel facet**, not alternatives to DOM.

> **Status: "by capability and by budget" is one axis short, and the bundle is not advertised.**
> Both were found by putting the two apps behind one menu on the phone (glass-webrtc RUNBOOK §7.2),
> and both are narrow.
>
> **A consumer with a person in it also chooses by INTENT.** The phone can blit *and* render DOM,
> and its budget covers either, so neither of this section's two axes decides anything between
> `warp-files`' Miller columns and warren's pixel browser — and the rule that they are not ranked
> means nothing else does either. A surface that picks for the user is the consumer choosing the
> encoder on the user's behalf, which is this rule inverted. What the menu does instead is offer
> **one entry per facet, named**, so the pick *is* the intent; it explicitly does not offer a "best
> available" entry, because an entry that means the columns today and the pixels tomorrow is one
> nobody can learn. Where capability and budget merely *permit* several facets, something has to
> say which one was wanted, and only a person can.
>
> **Nothing on the wire says which facets — or which apps — exist.** "The consumer chooses" is
> silent on how a consumer learns what it is choosing between, and there is no message for it: a
> host that does not serve an app returns `NIL` from its registry and the mux drops the message, so
> the answer is *silence*, which is indistinguishable from a slow link. That is the right refusal —
> see rule 6 — but it is not an answer to "what is on offer", and the phone's menu has to learn by
> asking, once per app, and remembering. Deliberately not fixed by a `hello` that enumerates the
> bundle: **asking costs whatever the app costs to load** (`:warp-files` drags warren → gesso,
> scribe, pigment into the image at first mention), so an enumeration is either a lie about what
> would load or a reason to load everything. Recorded as the honest shape of the gap rather than
> designed around.

### Opaque nodes, and the caption that cannot be derived

A node inside a data tree may offer only pixels: loom's page, cortez's screen, a video. The tree
around it stays structured — chrome, tabs, titles, commands — and only that node is a hole.

Such a node **must carry a caption**, because a consumer that cannot blit has no other way to know
what it is, and no amount of cleverness extracts "showing news.ycombinator.com" from a macroblock.
That is not a workaround for agents; it is the app saying what the region *is* while each consumer
takes what it can use. An opaque node's `:moved` is exactly the surface `copy-p` it already had.

### The desktop is a projection too

Windows are objects with keys, titles, positions and z-order; a session is a projection of them; a
seat is a consumer; and a window's content is either a nested projection or an opaque node. `glass`
is then what its README already claims — a framebuffer and an RFB server — with the window manager
living where a window manager belongs.

**Sequence this last.** It depends on two things that are unproven at app scale (nesting with
independent diff scopes, and opaque nodes), and being wrong about them in an app costs a day while
being wrong about them in the session costs the screen.

### Deliberately not doing

- **Not requiring every app to offer every facet.** Pixels-only is a legitimate app, and saying so
  is what keeps this a bundle rather than a framework tax.
- **Not deriving captions from pixels.** Guessing produces a plausible caption for the wrong thing,
  which is worse than the honest absence of one.
- **Not putting weft in core.** `:warp` depends on `bordeaux-threads` and nothing else; weft drags
  in shuttle, gesso, scribe, pigment and stencil. `warp-weft` is an optional system, the way
  `:glass/nostr` is.
- **Not making the DOM facet mandatory for pixels.** A hand-written `paint` stays available and stays
  faster; weft is the *default*, the way the MOP walk is the default `present`. Specialize to
  design, specialize for precision — the same rule one layer down.

### What it costs, honestly

**weft has no incremental relayout.** loom's shell calls `render-page` and marks dirty; glass's tile
diff extracts the damage afterwards. So the weft path re-renders a fragment and lets the diff find
what moved. The **wire** stays efficient — only changed tiles ship, which is the scarce resource —
but the *paint* does not, and warp-glass's invariant ("a pass paints only the extents the stream
emitted, so the tiles glass finds dirty are exactly those extents") is lost on that path, and with it
a free oracle. Rule 3's macroblock snapping likewise applies only to the hand-painted path, since
weft lays out by CSS.

Accepted deliberately: **weft is functional and can be made faster later.** Recorded here so that
when someone measures it, they find the trade already named rather than a regression.

Still open, and each one is a real question rather than an omission: **binary payloads** (the DOM
wire is JSON cells and cannot yet say "this is a picture"), **input into an opaque node** (rule 5's
gesture enum is closed and deliberately semantic, while a pixel region wants raw keys and
coordinates — an escape hatch that needs stating carefully or it becomes a hole), and **nesting with
independent diff scopes**, which no client has yet exercised because both are flat lists.

> **Status: two of those three have now met a client, and the answers differ.**
>
> **The opaque node works, and the caption is the whole of why.** A file browser's image preview is
> presented as caption + dimensions + an `opaque` tag and *nothing else* — the decoded pixels live
> on the domain object, never in the fingerprint. So the framebuffer reaches through `p-object` and
> blits, the DOM receives a 168-byte JSON delta carrying `"swatch.png — PNG file, 320 x 200"`, and
> neither encoding has a special case in it. The consumer that cannot blit knows what the region is
> because **the app said so**, which is exactly the claim, and no binary channel was needed to get
> there. Its `:moved` is the surface `copy-p` it was promised to be: shifting the pane one column
> costs **1 unit** against the **154 macroblocks** a re-send would cost.
>
> The thing worth writing down is a slot discipline, not a mechanism: **what travels is the
> fingerprint, so the pixels must not be in it.** Put them there and every consumer is charged for
> a payload only one of them can use, and the DOM's budget is spent on bytes it will discard.
>
> **Nesting works, and the phrase "independent diff scopes" does not describe what makes it work.**
> Miller columns over a filesystem give the numbers this section wanted:
>
> | event | deltas | in the changed column | in the other column |
> |---|---|---|---|
> | one file's content changes | **1** (`:changed`) | 1 | **0** |
> | a file is inserted at the top of a column | **5** (1 `appeared`, 3 `moved`, 1 `changed`) | 5 | **0** |
> | the same, in the *other* column | **5** | 5 | **0** |
>
> A change to one row is scoped to that row; a change in one column does not re-send the others.
> But it holds for a **different reason than this document implies**. There is exactly one diff,
> over one flat table, and "the column was not re-sent" is true because **no column-shaped thing
> exists that could have been re-sent** — not because a sub-diff was skipped. Cost is
> O(all rows in all columns) per pass either way.
>
> That is a cheaper result than the rule advertises, and a genuinely useful one: flat-with-
> composite-keys gets nesting for free and needs no reconciler change. What it does **not** get is
> the thing this rule wants before it projects the desktop — a subtree that can be diffed,
> budgeted, or **resynced** without touching its siblings. `resync` clears the one `delivered`
> table and re-announces everything; a window's contents cannot be resynced without re-diffing the
> session. So the sequencing advice stands, but the hazard is not "nesting might not work". It is:
> **the reconciler has one scope, and a session wants one per window.**

> **What met the code, again: the wire nested and the CLIENT did not — and the encoding never said
> where a container goes.** The status above was written against the server. Putting `warp-files` on
> a phone found the other half, and it is two separate holes rather than one.
>
> - **`container(name)` was `name === "rows" ? rowsEl : menuEl`.** Every name that was not `"rows"`
>   landed in the hold-menu. Both previous clients were flat, so the only other name that had ever
>   existed was `menu:<key>` and the wrong branch was accidentally the right one. A delta naming
>   `col:/tmp/foo/` as its parent rendered *into the menu*, silently and with no error anywhere.
>   Containers are real now: created on demand, keyed by name, removed when the last child leaves.
> - **Nothing on the wire said where a container GOES**, and no client could have worked it out.
>   `after` orders siblings *within* one container and says nothing across them, and `%diff` emits
>   within a priority band in **reverse layout order** — so the rightmost column's rows arrive first
>   and first-appearance ordering draws Miller columns right to left. Rule 4 already answers this
>   for a node ("park it rather than invent a position"); the same obligation one level up needs the
>   server to speak. So a frame carries **`cs`** — the app's containers, in that consumer's layout
>   order, as *state* rather than as an event, present only when the app names containers of its
>   own. A flat client's frame is byte for byte what it was, which is how `t/nochange.lisp` stayed
>   identical across this whole change.
>
> The honest reading of `cs` is that **`p-extent` was one field short for a nesting encoding.** The
> DOM's positional claim is `(container . after)`, and a container is a thing whose own position is
> undeclared. Putting it on every delta would repeat ~30 bytes per row; putting it on the frame
> costs it once per pass and supersedes by nature, which is what this protocol does with state
> everywhere else.
>
> And one bug underneath both, which no flat client could have hit: **the DOM's key round-trip was
> string-only.** `delta-json` ships `(princ-to-string (p-key p))` because JSON has no conses, and
> `%visible-by-key` compared what came back with `equal` against the key *object*. A pubkey prints
> as itself so client one never noticed; client two's key is `(column . entry)`, so every tap and
> every hold in the file browser resolved to `NIL` and did nothing — on a surface that otherwise
> looked completely correct. The comparison is made in the wire's unit now, which puts a constraint
> back on rule 1: **a key must print distinguishably**, or this encoding will merge two of them.

## Consumer-negotiated slices

The first draft of this section said **an agent can renegotiate its own viewport; a human cannot** —
a model asks for fewer fields, different rows, deltas-only, while a human's viewport is fixed by
physics. The DOM encoding falsified it on arrival: a browser is a human surface that reports its own
viewport and scroll offset, in rows, and is sliced accordingly.

The line is not human/agent. It is **whether the consumer can measure itself.**

- A **framebuffer cannot**: it is handed a size and lays out into it. Its slice is curated — someone
  chose it in advance.
- A **browser can**, and so can a model. Both tell the server what they can hold, and the server
  slices to fit.

> **The negotiation is a convergence, not a handshake** — which is the one thing this section got
> to find out by being on a real link. The server seats a consumer at *its own* default row count
> and its clock is already running, so the first frame carries that default; the browser's report
> then trims it and the difference comes back as ordinary `gone` deltas. Nobody waits for anybody.
>
> That is worth stating because the alternative is so tempting: make the viewport report part of
> opening the channel, and let the first frame be correct. It would cost a handshake on a transport
> that deliberately has none — the data channel is negotiated precisely so that neither end has to
> announce itself — and it would make the slice a thing you agree once rather than a thing you can
> change, which is exactly wrong for a phone that rotates. Say the current state and let the stream
> close the gap: the same discipline as everything else here, applied to the viewport.

Attention is still not re-targetable on request the way a context window is, so *what* a human is
offered stays editorial. But *how much of it travels* is negotiated by anything that knows its own
capacity, and that is a property of the surface rather than of the species behind it.

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

> **Status: shipped, on the real gateway, on real enrolments, with real authorization.** warp runs
> inside `gateway-nostr.lisp` over its own `.glass-devices`, on a third negotiated data channel
> (stream 102) beside `rfb` and `control`, and the phone's client has a ▤ panel that lists the
> enrolled terminals and revokes one with a hold and a tap. Every bullet above is now a thing that
> happened rather than a thing that would.
>
> The claim it was making all along — *the DM interface, a CLI, the GUI and an agent become surfaces
> of one command set, with authorization written once* — is now checkable rather than argued: the
> DM path and the panel reach the same `revoke`, and the panel's write is picked up by the
> gateway's own `sync-devices`, so a terminal revoked from a phone is refused on its next
> connection with nothing restarted.
>
> **Three things it cost that the plan did not have a line for**, all of them at the boundary rather
> than in the protocol:
>
> - **A channel is not a sink.** The encoding's side really was a sink and a function, as promised.
>   The *host's* side is a clock, one lock over ticks and messages, a send that must not signal, and
>   a close that runs on every unwind path — four disciplines, identical for a WebSocket and for an
>   SCTP stream, and the local server had quietly written each of them out by hand. They are
>   `dom/channel.lisp` now, which is why the gateway's share is 29 lines.
> - **Being unrunnable is a design input.** The gateway carries a live session and may not be
>   started, so its code is verified by reading and by nothing else. That does not make testing
>   optional, it makes *how much code is in there* the thing under design — and it is a surprisingly
>   good forcing function, because "what is the smallest thing I could put in the place I cannot
>   check" is a better question than "how do I test this".
> - **A disabled feature must drop, not decline.** The new dispatch branch claims its stream id
>   whether or not the feature is on. Gated instead, a client that had the panel talking to a box
>   that did not would have fallen through to the next branch — which is the RFB stream, and would
>   have handed a desktop a JSON object as input.

## Client two: the file browser

Client one and the monitor are both **flat lists with no pixels**, so between them they left rule 9's
two named unknowns untested. A Miller-column file browser is the smallest thing that tests both at
once, and it costs nothing to source: [warren](../warren) is a working pixel file browser whose
`fs.lisp` is 198 lines of model with **no drawing in it at all**. `warp-files` projects that model.
warren is not modified, not ported, and not replaced — it keeps running, and the two are the *pixel*
and *data* facets of one app, which is rule 9 stated rather than argued.

- keyed identity — the pathname, parent-scoped; `eq` provably fails **harder** than for enrolments,
  because `list-dir` conses fresh `entry` structs on every read and no two reads share one
- query-shaped subscription — *the entries of the open columns*, re-read every epoch
- nesting — three columns, with the delta-scoping numbers in the rule 9 status above
- an opaque node — an image preview, blitted by one consumer and captioned for the other
- `tap` → drill-in / peek (safe defaults); `hold` → delete (destructive, confirmed, owner-only)
- authorization at invocation — a guest is not offered `delete`, and is refused when it names it
- view state — selection, scroll, **and which column has focus**, the third piece a flat list had
  no room for

**Three things it cost that the plan did not have a line for**, all of them in the same place: the
boundary between what is shared and what is the looker's.

- **The column stack is the query's argument, so it is shared — and therefore the safe default
  mutates shared state.** Rule 8's examples are all about *how* a seat looks at fixed data, so the
  obvious reading is that "where I have navigated to" is view state like scroll. It is not: a second
  column stack returns different rows, which is definitionally a second projection. So two consumers
  over one browser drill in **together**, and `open` — a non-destructive tap default — writes state
  its neighbour is reading. That is not a wart, it is the same shape as `revoke` writing the
  enrolment file every consumer reads. It is what "reads are projections, writes are commands" means
  when the write happens to be a navigation, and it is worth stating because the alternative reading
  is defensible right up until you implement it.
- **The preview splits the other way, on the same line.** *Whether* there is a preview depends on
  this consumer's selection, so the node is built in `lay-out`. *What the decoded pixels are* is a
  property of the file, so the decode is cached on the shared half. Paying for a decode per consumer
  would be the mixer bug in a slower coat.
- **A lagging consumer is handed the cache, not a fresh read.** `pull` re-runs the query only for a
  consumer whose epoch has *caught up* with the projection's; one that is an epoch behind is brought
  level against the cached objects and re-queries on its *next* tick. It converges, which is what
  rule 8 promises, but "a change is visible to every consumer on its next tick" is not true — it is
  the next tick for whoever was level and the one after for whoever was behind. Nothing to fix;
  something to know before someone debugs it as a missing delta.

One limit, recorded rather than discovered: **scroll is one offset for the whole browser, not one
per column.** Rule 7 keeps one scroll slot and `content-height` is what lands the clamp in the right
unit, so per-column offsets would need a slot core does not have.

`warp-files` depends on `warp` **and warren**, which drags gesso, glass, scribe and pigment — fine
for an optional client system, and the reason `:warp` itself still depends on bordeaux-threads and
nothing else, with `t/core.lisp` still the standing proof.

> **Status: on the phone, beside the device manager, on the one channel there is.** `warp-files`
> was gate-tested and served to nobody. It is now the second app on stream 102, and the shape of
> that answer was forced by a constraint outside warp entirely.
>
> **A second channel was not available, and the reason is worth stating because it inverts the
> obvious ranking.** A channel per app is simpler than a projection id on paper. But every data
> channel in this system is created before the offer — signalling is one-shot and non-trickle and
> nothing renegotiates — so channels are made in `shell.js`, which is **published to nsite**. A
> fifth channel is therefore a new tag, every login link minted against the old one dead, and a
> desktop restart for `LOGIN_URL_BASE`. A projection id is a file copy and a gateway restart. So:
> **a client message may carry `a`, the app it is for, and a frame carries `a` back — and the device
> manager is the app with no name.** Absent routes to it, its frames go back unlabelled, and a phone
> holding an older payload asks for one app and gets exactly the bytes it always got.
>
> That is also what a third app wants. Stream ids are a fixed resource negotiated once; app ids are
> not.
>
> Three things it cost that the plan did not have a line for:
>
> - **The multiplex belongs to the channel, not to the gateway.** It went into `warp-dom`
>   (`make-mux` / `mux-receive` / `message-app`), where a fake transport can drive it, because the
>   gateway is a thing we may not run. What that bought is measurable: `gateway-nostr.lisp` gained
>   **zero lines** — its state for this channel was already an opaque value handed back to
>   `warp-close`, and it is now a link with a mux in it.
> - **An app must be able to fail to load without taking the box with it.** `warp-files` depends on
>   warren, which drags gesso, scribe and pigment. So it loads at the first message *naming* it,
>   never at start, never at all with `WARP_FILES` unset — and a failed load is *remembered*, since
>   retrying a half-second of ASDF per message is its own outage. An app this box does not serve is
>   **dropped**, never quietly given the default one.
> - **Where it opens is a default and deliberately not a confinement.** The desktop next door has a
>   terminal in its root menu, so a credential that reaches this panel already reaches a shell, and
>   a root-confined browser beside an unconfined shell protects nobody while looking as though it
>   does. What the default is *for* is that `/` is useless to open at. It is `$HOME` — the answer
>   warren's pixel browser already gives, which is rule 9's two facets of one app agreeing about
>   something small — overridable with `WARP_FILES_ROOT`. `*writable-root*` is unchanged and still
>   enforced: deleting is a different question from looking.

> **What warren's model did and did not give up.** `fs.lisp` is genuinely a model — listing,
> sorting, sizing, kind-labelling and image decoding, with no drawing — and it projected without a
> fight. What it does not do is *export* any of it: warren's package exports four symbols (`run`,
> `render-to-png`, `desktop-surface`, `*show-hidden*`) and every one of the eleven readers and one
> decoder this client needs is internal. So `warp-files` reaches through `warren::`, in a single
> labelled block in `model.lisp` so the depth of the reach can be counted rather than sprinkled
> through four files. The one place it hurts is `entry-size`, which stats the file on every
> `present`; that is what makes a content change visible as a one-row delta, and it is also N file
> opens per pass.

## Extract under load

Layout, theming, pane composition (steal GToolkit's Miller columns), animation: **extract when a
second client needs them.** Three clients decide whether the core is right — device manager, loom's
chrome (retiring the flickering immediate-mode code), and the inspector (proving presentations are
real). Fewer than three and we are guessing.

> **Status: FIVE, and the count is the point.** This paragraph said *two* for a long time and the
> rule it serves — three clients decide whether the core is right — has now been met and passed.
> What each one cost is the honest record:
>
> | client | what it found |
> |---|---|
> | monitor / device manager | agreed with each other about everything; two flat lists cannot disagree with the core |
> | `warp-files` | nesting, and rule 1 claiming a reconciler feature that does not exist |
> | `warp-media` | the first controls — `button` and `meter` — which sat in one app for months before anyone noticed they were core's |
> | `warp-quire` | six row kinds and widths 1/2/5, which killed "infer the kind from cell three"; and that a chip must be a presentation |
> | `warp-catalogue` | that three declared widgets were unpainted by the client, silently, because an unrecognised type falls back rather than failing |
>
> The catalogue is the one worth keeping deliberately: it is the only client whose subject is warp,
> it renders through the real encoding rather than a fixture, and it is the arrangement that shows
> every widget at once — which is the only way an unpainted one is visible at all.
>
> **Status: two, and the second one paid.** The device manager and the monitor were both flat lists,
> so they agreed with each other about everything and could not disagree with the core. The file
> browser is the first client that is shaped differently, and it immediately found rule 1 claiming a
> reconciler feature that does not exist and rule 8 silent on where navigation lives. Miller columns
> did not need stealing — they are `lay-out` plus four generics for the positional claim, ~90 lines
> — which is itself the evidence for "extract under load": the composition that looked like it
> wanted a framework turned out to want a method.
>
> The third client should be shaped differently again. Both existing ones are read-mostly with a
> handful of commands; an **inspector** would be the first to make `present`'s MOP default
> load-bearing, and loom's chrome the first whose content is an opaque node rather than rows around
> one.

The failure mode is building a framework in the abstract. The presentation concept is tiny; the
gravity well around it is not.
