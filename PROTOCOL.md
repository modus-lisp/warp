# warp — the wire protocol

This is the specification a consumer is written from. `DESIGN.md` says *why* and states the rules;
this says what is on the wire, field by field, and what each end is obliged to do about it. Rules
are referenced by number and not restated.

Everything here is derived from the code, and every non-obvious claim cites the file and function
that makes it true. Where a behaviour is an artefact of the one implementation rather than a
guarantee, it says so. Where the two shipped encodings disagree, that disagreement is the boundary
between the protocol and an encoding, and it is marked.

**Reading order for an implementer:** §1–§9 are the protocol proper and are encoding-independent.
§10 is the concrete JSON wire. §11 is the transports. §14 is what is *not* specified — read it
before you assume a gap is an omission in this document.

---

## 1. The shape of the thing

    projection ──pull──▶ objects ──lay-out──▶ presentations ──%diff──▶ deltas ──apply-deltas──▶ target
      (shared)            (shared)              (per consumer)          (budgeted)     (an encoding)

| | owns | file |
|---|---|---|
| **projection** | the query (`rows-fn : () -> objects`), the objects it returned, `as-of`, the epoch | `src/projection.lisp` |
| **consumer** | `present`, layout, view, scroll, viewport, extents, stream, budget, invoker, selection, menu, counters | `src/consumer.lisp` |
| **encoding** | what a delta *costs*, what *moving* looks like, what *position* is, and where deltas land | `glass/surface.lisp`, `dom/consumer.lisp` |

A **pass** (`src/consumer.lisp:%pass`) is the unit of work and the unit of framing:

1. `pull` the projection (runs the query only if this consumer needs a newer epoch);
2. `lay-out` those objects for *this* consumer, and append `menu-presentations`;
3. `emit` (or `snapshot`) against this consumer's stream under this consumer's budget;
4. `apply-deltas` with exactly what emitted — and only if something did.

Step 4 is guarded: `(when deltas (apply-deltas c deltas))`. **A pass that owes nothing puts nothing
on the link.** There is no keepalive, no heartbeat and no empty frame at the warp layer.

`consumer-visible` is set to the full laid-out set in step 3, *before* step 4. It is the set an
incoming gesture is resolved against, and it is the set the frame's container list is derived from.

### What is a consumer

A consumer is whatever owns an encoding target (Rule 8). Constructing one with no applicable
`apply-deltas` method is refused at `initialize-instance` (`src/consumer.lisp`), so "no encoding"
is a type error and never an intermittent reconciler bug.

Three encodings exist:

| system | target | budget spent in | position is |
|---|---|---|---|
| `warp-glass` | a glass framebuffer over RFB | 16px macroblocks | `(x y w h)`, grid-snapped |
| `warp-dom` | a DOM in a browser over JSON | serialized bytes | `(container . after-key)` |
| `warp` core | `recording-consumer` — a list | a flat 1 per delta | whatever it was handed |

---

## 2. Identity: the key

**Rule 1.** A key is derived by a **per-type key function**, declared with
`define-presentation-key` and looked up by `presentation-key (type object)`
(`src/presentation.lisp`).

- The signature is `(type object)`. **A key function cannot see the parent.**
- If no key function is declared, `presentation-key` falls back to the object *only* for things
  that are their own identity — symbol, string, number, character — and otherwise **signals**. It
  never falls back to `eq`. An unkeyed type fails loudly on the first pass
  (`t/reconcile.lisp`: "unkeyed type signals rather than defaulting to eq").
- A key is any `equal`-comparable Lisp value. In practice: a string (a pubkey), or a cons of
  values (`warp-files` uses `(column-path . entry-path)`, `files/model.lisp`).

### Scope, and what DESIGN.md's Rule 1 opening line does not mean

`%diff` (`src/reconcile.lisp`) holds **one** `delivered` hash table, keyed by `p-key` under
`equal`, and there is no parent anywhere in it. "Reconcile matches on `(parent, key)`" is false of
the code; DESIGN.md records this itself in Rule 1's status block, and `files/columns.lisp`'s header
is the finding.

Consequences an implementer must know:

- **A key's scope is the consumer's whole stream.** Two presentations with `equal` keys collide in
  `delivered` no matter what containers they claim.
- **Parent scoping, where wanted, is done in the key function** by giving the domain object its
  parent and consing the two together. `warp-files` does exactly this; `t/files.lisp` asserts that
  a name-only key collides across two columns and the parent-scoped one does not.
- **Re-parenting is not `moved`.** In the DOM encoding a change of container returns `NIL` from
  `moved-p`, so the diff falls through to `:changed` and the client re-parents with content in
  hand (`dom/consumer.lisp:moved-p`). Rule 1 says re-parenting reads as `gone` + `appeared`; the
  code's answer for the case Rule 1 says cannot arise is `:changed`.
- **`p-children` is dead.** The slot exists and is exported and is read by no line of code. A
  projection that put its nesting there would ship its roots and silently drop every descendant.
  Asserted in `t/files.lisp`.

### The print-distinguishability constraint

The DOM wire carries a key as `(princ-to-string (p-key p))`, because JSON has no conses. A client
can only ever send that string back, and `%visible-by-key` (`dom/consumer.lisp`) compares in the
wire's unit.

> **Any key used with the DOM encoding must `princ` distinguishably.** Two keys that print alike
> are one key to that encoding, where the reconciler keeps them apart. Pathnames, pubkeys and
> conses of them do. Display names do not.

Nothing enforces this. See §14.

---

## 3. The presentation

`src/presentation.lisp`. A presentation is what one consumer built for one object on one pass.

| slot | meaning | reaches the wire? |
|---|---|---|
| `key` | identity (§2) | yes, as a string |
| `type` | a symbol; commands are declared against it | yes, lowercased |
| `object` | the domain object | **no** — server side only |
| `extent` | *this encoding's positional claim* (§5) | encoding-dependent |
| `as-of` | when the underlying data was read | yes |
| `fingerprint` | `present`'s output: a list of cells | yes, as `cells` |
| `state` | this consumer's view state (selected, focused) | yes, when non-nil |
| `cost` | optional cost override | no |
| `children` | **unused** | no |

`fingerprint` and `state` are compared identically by the diff and kept apart deliberately:
`present`'s signature is `(object type view)` and has no room for a seat's state, and an encoding
needs the two halves apart — one tints a row, another writes "(selected)".

**`present`** (`src/present.lisp`) dispatches on `(object type view)` and returns **content, not
pixels**: a list of cells, each a string, a keyword tag, or a number. The default method is a MOP
slot walk, so any type is browsable with no UI code.

**The slot discipline that matters:** what travels is the fingerprint, so anything only one
consumer can use must not be in it. `warp-files`' image preview keeps decoded pixels on the domain
object and puts only a caption in the fingerprint (`files/model.lisp:present fs-preview`), which is
why a DOM consumer is charged 168 bytes for a node it cannot draw instead of a thumbnail it would
discard.

---

## 4. The delta kinds

Four, and the enum is closed: `:appeared`, `:changed`, `:moved`, `:gone`
(`src/reconcile.lisp`, `delta-kind`; `%priority` is an `ecase` over exactly these).

A delta struct carries `kind`, `key`, `presentation`, `extent`, `dx`, `dy`.

### When each is emitted

`%diff (consumer delivered current)` walks `current` in layout order:

| condition | delta |
|---|---|
| key not in `delivered` | `:appeared` |
| fingerprint **or** state differs, or the position differs and `moved-p` said no | `:changed` |
| fingerprint **and** state both `equal`, and `moved-p` returns non-NIL | `:moved` |
| fingerprint, state and extent all `equal` | *nothing owed* |
| in `delivered`, absent from `current` | `:gone` |

Two orderings inside that are load-bearing:

- **`moved-p` is asked only when the content held.** An encoding is never questioned about a move
  that a content change has already superseded.
- **`moved-p` returning NIL is always safe.** The diff falls through to `:changed`, which resends
  the content *along with the new place*. An encoding that cannot recognise a reposition loses
  bandwidth, never correctness.

### What each means to a consumer

**`:appeared`** — a presentation this consumer has never been told about, or has been told is
`:gone`. Carries key, type, position, cells, optional state, `as-of`. **Create it.**

An `:appeared` for a key the consumer already holds is reachable: `snapshot` (§7) clears
`delivered` and re-announces everything. A correct client must **replace, not duplicate**. The
reference client does not do this — see §14.

**`:changed`** — same identity, new content and/or new place. Carries everything `:appeared` does.
**Repaint in place and re-anchor.** Note it is also the delta for a *state-only* change: selecting
a row emits `:changed` with an unchanged `cells` and a new `state`, because from the reconciler's
side "the selection moved" and "the value changed" are the same event — this row no longer looks
the way you were told it looks.

**`:moved`** (Rule 2) — same identity, same content, new place. Carries key, position, optional
state, `as-of`. **It carries no content, and the consumer must not rebuild the node.** That is the
whole of Rule 2: a reposition asserts, it does not re-send.

- Whether a translation vector exists is the **encoding's** claim. The framebuffer's `moved-p`
  returns `(dx dy)`; the DOM's returns a bare `T` and the new place travels on the presentation
  (`dom/consumer.lisp:moved-p`). `delta-dx` / `delta-dy` are `0` when `moved-p` did not answer a
  cons.
- Cost is 1 unit under core's default (`src/reconcile.lisp:delta-cost`), regardless of size. In
  `t/files.lisp` an opaque image pane moving one column across costs **1 unit** against the **154
  macroblocks** a re-send would cost.
- The payoff differs sharply by encoding, which is the clearest evidence that position is not
  protocol. Scrolling one row: the framebuffer emits 1 `:gone` + 1 `:appeared` + **13** `:moved`;
  the DOM emits 1 + 1 + **1**, because a DOM has no coordinates and the rows a scroll did not touch
  genuinely did not move (`demo/two-encodings.lisp`, `t/dom.lisp`).

**`:gone`** — this key is no longer in the working set. `delta-presentation` is `NIL`;
`delta-extent` is the position it *used* to hold, which is the framebuffer's repair rectangle and
is of no use to an encoding that removes by key. **Remove it.**

`:gone` does not mean deleted. It means *out of this consumer's slice* — scrolled past, filtered
out, viewport shrunk. A consumer must not infer anything about the domain from it.

### Resync is not a fifth kind

DESIGN.md Rule 4 says "resync is a delta kind". **In the code it is not.** `snapshot`
(`src/reconcile.lisp`) is a *mode of emission*: it clears `delivered`, increments the generation,
and then calls `emit`. On the wire a resync is indistinguishable from a first fill except by the
**generation**, which is one higher. See §7. Reported as a divergence, not papered over.

---

## 5. Position, and why `extent` is over-named

`p-extent` is **this encoding's positional claim**. It is not geometry, and only one encoding's is
a rectangle.

| encoding | `p-extent` | what it means |
|---|---|---|
| `warp-glass` | `(x y w h)`, ints, grid-snapped to 16 | a framebuffer rectangle (Rule 3) |
| `warp-dom` | `(container . after-key)` — a **dotted** pair | exactly what `insertBefore` takes; `after` NIL means first child |
| core default / `recording-consumer` | whatever it was handed, including `NIL` | nothing |

The slot is compared with `equal` either way, so "same place" needs no generic. What does need one
is recognising a *reposition*, because only the encoding knows what moving looks like — hence
`moved-p`.

Three rules fall out, and each is a place a pixel assumption was found and removed:

1. **Anything in core that reads an extent as geometry must ask first.** `rect-p`
   (`src/presentation.lisp`) is spelled out cons by cons because a DOM's position is an *improper*
   list and `list-length` signals on one. `p-macroblocks` prices a non-rectangle at one unit rather
   than crashing.
2. **A `NIL` extent is legal.** It costs one unit and can never be a `:moved`. Core's default
   `menu-presentations` (`src/menu.lisp`) emits menu items with no extents at all, because geometry
   is a claim only an encoding can make.
3. **`NIL` extents everywhere are a trap, and this is the sharpest thing the DOM encoding taught.**
   The diff decides "nothing owed" with `(equal (p-extent old) (p-extent new))`. With no position
   on the presentation at all, a **re-sort of the result set emits nothing** and the consumer holds
   a stale order forever, silently. `t/dom.lisp` pins this: "a RE-SORT is the case a NIL extent
   would have silently lost."

So: an encoding with an order must put *something* order-bearing in `p-extent`. An encoding with
neither geometry nor order (a token stream) may use `NIL` and accept that it cannot see a re-sort.

**Rule 3's 16px grid is the framebuffer's alone.** `snap`, `snap-extent` and `+grid+` are core's
default *layout*'s unit, not the protocol's. The DOM consumer never sees them; `t/dom.lisp` asserts
"no presentation carries a rectangle; rule 3's grid never reaches this consumer."

---

## 6. Ordering, and the obligation it creates

### What is guaranteed

Deltas within a pass are sorted by **priority only** (`src/reconcile.lisp`, `%priority`):

| band | kind | why |
|---|---|---|
| 0 | `:gone` | a stale row still on screen is actively misleading, and repairing it is cheap |
| 1 | `:appeared` | Rule 4: unseen before prettier — content never seen outranks refinement |
| 2 | `:moved` | cheap, and it keeps navigation responsive |
| 3 | `:changed` | refinement of something already held |

`t/reconcile.lisp` pins the band order: "`:gone` first, then `:appeared`, then `:changed`."

### What is *not* guaranteed

**Order within a band is unspecified.** In the current implementation it is *reverse layout order*
for `:appeared`/`:moved`/`:changed` — an artefact of `%diff` building its result with `push` and
`sort` happening to be stable — and *hash-table iteration order* for `:gone`, which is unspecified
by the language. Do not depend on either.

This is not a defect to be fixed, and a consumer must not be written as though it will be:

> **A relative-position encoding must tolerate an anchor it has not been told about.**

Two independent causes, and only the first could ever be repaired on the server:

- the emitter goes in reverse layout order within a band, so appending two rows sends
  `r05 after r04` **before** `r04` (`t/channel.lisp`: "the anchors arrive BEFORE their anchor does,
  which is why the client must park"; `t/dom.lisp`: "at least one names an anchor that is later in
  the SAME pass");
- and **the budget can defer the anchor to a later pass entirely**, which no server-side ordering
  rule can repair.

### The consumer's obligation

> **Park an unplaceable node *out of the document* until its anchor arrives. Never put it in a
> position you invented.**

The reference client keeps a `waiting` map from anchor key to the records blocked on it, removes
the node from the DOM while it waits, and inserts it the moment its anchor lands
(`dom/client.js:place`). Guessing would put a row in the wrong place and leave it there, which is
exactly the silent-wrong-order failure this encoding's positions exist to prevent. A framebuffer
never noticed, because absolute coordinates have no anchors.

The same obligation applies one level up to **containers**, whose own position no delta can state.
See §10.4.

### The budget loop does not stop at the first refusal

`emit` walks the sorted list and tries *every* delta; one that does not fit increments `deferred`
and the loop continues. A cheap delta later in the list can be delivered on a pass where an
expensive earlier one was deferred. Priority is a preference, not a prefix.

---

## 7. Budget, deferral, idle drain, generation

### The mechanism

Deferral is **not a queue of unsent deltas**. It is expressed as *acknowledged state lagging*: the
stream keeps `delivered`, the last state the consumer was actually told, and every pass diffs
current against delivered. Emitting advances `delivered`; skipping does not
(`src/reconcile.lisp:emit`).

Three properties fall out and none of them is code:

- **Coalescing.** Three changes to one key between passes are one delta, at the newest value —
  because states are compared, not events replayed.
- **Idle drain.** A deferred delta is re-derived on the next pass even when nothing new happens,
  because `delivered` still differs. It **cannot** be stranded; there is no representation for a
  stranded delta.
- **Supersession.** A delta deferred and then changed again is emitted once, newest-only, never as
  stale intermediates. `t/reconcile.lisp` asserts both: "no row is sent an intermediate value" and
  "all ten arrive".

### What the producer promises

- Every delta owed is eventually delivered, given passes.
- No delta is delivered twice for one change (`t/dom.lisp`: "was never told anything twice";
  `demo/two-encodings.lisp`: "delivered all 20 rows exactly once, never an intermediate").
- Pacing costs envelopes, not content. `demo/two-encodings.lisp` asserts that a consumer converging
  under a 256-byte budget and one with no budget at all put the **same delta bytes** on the wire.

### What it does not promise

- **Nothing about latency.** How many passes convergence takes is a function of budget and clock.
- **Nothing about the first delta.** `emit` always emits the first delta of a pass, whatever it
  costs: `(or (null emitted) (<= (+ spent cost) budget))`. This is not slack. A 64-hex key with its
  anchor and cells is ~230 bytes, so a budget below one delta would otherwise defer forever while
  the link looked perfectly healthy. `t/channel.lisp` pins the rule that exists rather than the
  tidier one that does not: "everything **after the first delta** fits the budget."
- **Nothing about the envelope.** The budget is spent on `delta-cost` only. The frame's `gen`, `a`
  and `cs` fields are overhead on top of it (`t/dom.lisp` allows `+ 320 200` for exactly this).

### The unit is the consumer's

`delta-cost (consumer delta)` is generic (`src/reconcile.lisp`). Core's default counts macroblocks
of the delta's extent, which is what core's own default layout produces — so the default cost and
the default layout agree with each other. An encoding whose layout is not pixels owes a method.

| consumer | unit | typical budget |
|---|---|---|
| `fb-consumer` | 16px macroblocks (deliberately **not** specialised — its unit *is* the default's) | 400 |
| `dom-consumer` | UTF-8 bytes of the serialized delta | 4096 (channel), 1024 (gateway), 100000 (localhost) |
| extent-less core consumer | a flat 1 — which degenerates `budget` into "N deltas per pass" | — |

`t/core.lisp` pins the degeneracy explicitly, and then a twelve-line encoding overriding it.

### Generation

`ds-generation` starts at 0 and is incremented **only** by `snapshot`. Every frame carries the
current generation, not just snapshot frames.

- **Attaching is not a resync** (Rule 8). A new consumer's stream starts empty at generation 0, and
  that emptiness *is* its initial snapshot: there is nothing older to discard. `t/channel.lisp`:
  "the generation is still 0 — attaching is not a resync."
- **`resync` bumps it.** `resync` (`src/consumer.lisp`) is `%pass` with `snapshot` instead of
  `emit`: forget what this consumer was believed to hold, re-announce the whole working set at a
  new generation, chunked by the same budget. Only this consumer is affected; its neighbours are
  told nothing.
- **The discard rule:** a consumer must discard anything carrying a generation older than the
  newest it has seen. Otherwise a live change arriving mid-snapshot can be applied on top of a
  chunk that already reflects it, or under one that supersedes it. `dom/client.js:apply`:
  `if (frame.gen < gen) return frame;`.
- Resync bumps the generation **once**, at the start. The passes that drain the resulting backlog
  are ordinary `emit` passes carrying the same (new) generation.
- `resync` clears the **one** `delivered` table. There is no per-subtree resync; `t/files.lisp`
  asserts "RESYNC clears the ONE delivered table, so a single column cannot be resynced alone."

---

## 8. Staleness and cost class

**`as-of`** is a property of the *read*, not of the pass. `pull` stamps `projection-as-of` once,
with `now-tick`, and layout copies it onto every presentation — so a consumer laying out an
epoch-old cache reports the age of the **data**, not of its own pass (`src/projection.lisp`,
`src/consumer.lisp:pull`).

`now-tick` (`src/presentation.lisp`) is:

> **Common Lisp universal time** — seconds since 1900-01-01 UTC — **floored to 60 seconds.**

Two reasons for the quantization, and the second is the one that matters here: `exp > now` changes
when nothing changes, so a quantized clock is a subscribable tick that can emit ordinary
`gone`/`changed` deltas; and an un-quantized clock would make every row's fingerprint differ on
every pass and defeat the whole diff.

A consumer may do what it likes with `as-of`. A human surface renders a stale tint or an "as of"
label (`dom/client.js:paint` appends `<span class="stale">`); an agent reads it as scheduling data.
It costs ~16 bytes of budget per delta and dropping it to save them would be the wrong trade made
silently (`dom/consumer.lisp:delta-json`).

**Cost class** is a property of a *command*, not a presentation: `cmd-cost` is `:local`,
`:gateway` or `:network` (`src/command.lisp`). It reaches the wire **only inside a menu item's
cells**, as cell 1 (`src/menu.lisp:present menu-item`). There is no cost annotation on a row.

---

## 9. The stream is a memory, not an event log

Rule 8. This is a correctness constraint on hosts, not an efficiency argument, and it is the single
easiest thing to get wrong when adding a second consumer.

`stream` is **this consumer's memory of what it has already been told.** A consumer allocates its
own in its own initform (`src/consumer.lisp`) and there is no argument by which it could receive
somebody else's.

> Share one stream between two consumers and a change is emitted **once**, landed on whichever
> ticked first, and the other is **never told**. It is not stale — it is *wrong*, and it looks
> correct, because the delta was emitted exactly once as designed.

A late joiner is the same bug wearing a different hat: its memory must start empty and be filled by
an ordinary budgeted pass, never inherit a high-water mark. This is why `channel-close` **detaches**
the consumer (`dom/channel.lisp`): a peer that comes back is a peer holding nothing, and keeping
the old consumer would hand it somebody else's memory.

The reference client honours the mirror image: on channel close it calls `reset()`, dropping every
node, because the server's memory went with the link and whatever comes back is a fresh snapshot
from an empty stream (`dom/client.js`, and `payload.js`'s `close` handler).

### What is shared and what is not

| shared, once per epoch | per consumer |
|---|---|
| `rows-fn` and the objects it returns | `stream`, `budget`, `invoker` |
| `as-of` of that read | `view`, `scroll-y`, viewport, `row-height` |
| `type-fn` | `selected`, `menu`, `focus` (Rule 7 view state) |
| the query count | `visible`, counters, the encoding target |

`pull` (`src/consumer.lisp`) runs `rows-fn` only when the caller's epoch equals the projection's;
otherwise it hands over the cache. N consumers ticking in a round cost **one** query between them
(`demo/two-encodings.lisp`: "a whole round — framebuffer, browser, phone, control — costs ONE
query"; `t/files.lisp` and `t/dom.lisp` assert the same).

**The lagging-consumer consequence, which is not a bug and will be debugged as one:** `pull`
re-runs the query only for a consumer whose epoch has *caught up*. One that is an epoch behind is
brought level against the **cached** objects and re-queries on its *next* tick. It converges, but
"a change is visible to every consumer on its next tick" is not true — it is the next tick for
whoever was level and the one after for whoever was behind (`t/files.lisp` states and relies on
this).

### There is no shared clock

`tick` takes the consumer's own lock; each channel runs its own thread at its own `hz`
(`dom/channel.lisp:%channel-loop`); glass's WM polls each window's `dirty-p` independently. A fast
consumer and a slow one have different ticks and neither may block the other. Query count is the
**max** of the consumers' tick counts, never the sum.

---

## 10. The DOM encoding — the concrete wire

`dom/consumer.lisp` (the encoding), `dom/json.lisp` (the serializer), `dom/client.js` (the
reference consumer).

JSON, because the consumer at the far end is JavaScript and `JSON.parse` is the one decoder it has
without asking anyone's permission; because it is self-describing, so version skew fails loudly on
a missing key rather than silently on a shifted offset — and this stream carries a `revoke` menu;
and because the budget is bytes, and a framing whose size you cannot read in devtools makes the
budget unauditable.

Everything is UTF-8. Both directions are single JSON values, one per transport message. There is no
framing of warp's own.

### 10.1 Server → client: the frame

One pass, one frame, produced by `dom/consumer.lisp:frame-for`:

```
{"gen":<int>[,"a":<string>][,"cs":[<string>,...]],"deltas":[<delta>,...]}
```

| field | presence | meaning |
|---|---|---|
| `gen` | **always**, and always first | §7's generation marker. Discard a frame whose `gen` is lower than the highest seen. |
| `a` | only when this consumer has an app label | which projection on this link the frame belongs to (§11.3). **Absent** — not null, not empty — for the default app. |
| `cs` | only when the app names containers of its own | the app's containers, **in this consumer's layout order** (§10.4). |
| `deltas` | always | the pass's deltas, in emission order (§6). |

A flat, unlabelled app's frame is byte-for-byte what it was before either `a` or `cs` existed.
`t/dom.lisp` asserts this on the frame's **text**: "the frame's text still begins with the
generation and nothing else", `(null (search "\"a\":" s))`, `(null (search "\"cs\":" s))`.

### 10.2 Server → client: a delta

`dom/consumer.lisp:delta-json`. Fields appear in exactly this order and **only when they mean
something**, because every field is charged to the budget.

| field | `appeared` | `changed` | `moved` | `gone` | value |
|---|---|---|---|---|---|
| `k` | ✔ | ✔ | ✔ | ✔ | the kind, lowercased: `"appeared"` `"changed"` `"moved"` `"gone"` |
| `key` | ✔ | ✔ | ✔ | ✔ | `princ-to-string` of the key (§2) |
| `type` | ✔ | ✔ | — | — | the presentation type, lowercased symbol name |
| `in` | ✔ | ✔ | ✔ | — | container name (string) |
| `after` | ✔ | ✔ | ✔ | — | key of the sibling this follows, or `null` for first child |
| `cells` | ✔ | ✔ | — | — | the fingerprint, as an array (§10.3) |
| `state` | if non-nil | if non-nil | if non-nil | — | `{"selected":true, ...}` |
| `as_of` | ✔ | ✔ | ✔ | — | universal time, quantized to 60s (§8) |

Notes that are easy to get wrong:

- **`in` and `after` travel together or not at all**, and only where they are acted on. `:gone`
  carries the place it *used* to be in the delta struct, and that is the framebuffer's repair
  rectangle — of no use to a client that removes by key. So a `gone` delta on this wire is
  **exactly** `{"k":"gone","key":"..."}` and nothing else.
- **`moved` carries no `type` and no `cells`.** `t/dom.lisp`: "it re-sends no content at all — key,
  place, staleness."
- **`moved` *does* carry `state` and `as_of`.** `state` is redundant on a `:moved` by construction
  (a `:moved` requires `state` to have compared `equal`), and it is sent anyway: `%state` is not
  gated on kind. Recorded as an implementation fact, not a guarantee.
- **`after` is `null`, never absent, when a node is first child**, because the field is emitted as
  a pair with `in`.

### 10.3 Cells

`cells` is `present`'s output, serialized by `dom/json.lisp:%json-write`:

| Lisp | JSON | why |
|---|---|---|
| string | string | |
| keyword or symbol | **lowercased string** | tags like `:ok` `:warn` `:bad` `:destructive` `:opaque` `:gateway` are enums; a client comparing `cell === 'destructive'` is doing what the painter does when it picks a colour |
| integer | number | |
| other real | number (`~f`) | |
| `NIL` | **`null`**, never `[]` | in a fingerprint it means "this cell has no value"; an empty array would read as a cell present but blank |
| `T` | `true` | |
| list | array | |

There is **no schema for cells.** Their meaning is a contract between one app's `present` methods
and one page's stylesheet. The reference client hardcodes three shapes
(`dom/client.js:paint`), and this is the closest thing to a convention that exists:

| shape | detected by | cells |
|---|---|---|
| a row | default | `[value, label, trend]` — `trend` ∈ `"ok"`/`"warn"`/`"bad"` |
| a menu item | `type === "menu-item"` | `[label, cost-class, "destructive"\|"safe"]` |
| an opaque node | `cells[2] === "opaque"` | `[caption, dimensions, "opaque"]` |

The menu-item shape *is* fixed by core (`src/menu.lisp:present menu-item`) and is the one cell
layout an encoding may rely on. The other two are app conventions
(`app/monitor.lisp`, `files/model.lisp`).

**The opaque node** (Rule 9) is the app declaring a region it offers only as pixels. The `"opaque"`
tag is the whole of what a non-blitting consumer needs: draw a labelled placeholder, not a row.
`t/files.lisp` asserts the negative — that the frame contains no `base64`, no `data:`, and nothing
of type `img` in the fingerprint — because that is the claim under test: *a consumer that cannot
blit still knows what the region is, because the app said so.*

### 10.4 Containers

A delta's `in` **names** a container. **Nothing on the wire says where a container goes, and no
delta could** — `after` orders siblings *within* one container and says nothing across them.

Two container names are the **encoding's own**, and a host is expected to own an element for each
(`dom/consumer.lisp:%own-container-p`):

| name | contents |
|---|---|
| `"rows"` | the row list — `+rows-container+` |
| `"menu:<key>"` | the open hold-menu, hanging off the row whose key follows the colon (`""` if there is no target) |

**Every other name is the app's.** `warp-files` uses `col:<namestring>` per open column and
`preview` for the preview pane (`files/dom.lisp`). A client must create app containers on demand
and drop them when the last child leaves. Two constraints follow:

> An app container's name must not be `"rows"` and must not begin with `"menu:"`.

Because a container's place is underivable, the frame states it:

- **`cs` is the app's containers in this consumer's layout order, as *state*.** Every frame that
  has any carries all of them; they supersede by nature. Derived from `consumer-visible`, deduped,
  with the encoding's own two excluded (`dom/consumer.lisp:app-containers`).
- Putting it on the frame costs it once per pass; putting it on every delta would repeat ~30 bytes
  per row. `t/files.lisp` asserts both that `cs` is on the frame and that no delta carries it.
- A client must apply `cs` **before** the frame's deltas, so a container the deltas create already
  knows where it belongs and no column is ever briefly drawn in the wrong place
  (`dom/client.js:apply`).
- **`cs` is a sequence, not a tree.** `in` is a flat name and nothing says a container's own parent.
  Containers do not nest in containers. A client wanting a tree would need the wire to say so.
- A container the client holds that `cs` does not mention keeps its relative place at the end rather
  than being guessed at (`dom/client.js:orderContainers`).

Without `cs`, first-appearance ordering draws Miller columns **right to left**, because `emit`
orders a priority band in reverse layout order. This is the frame-level twin of §6's obligation:
never put a thing in a position you invented.

### 10.5 Client → server: messages

`dom/consumer.lisp:on-message`. Dispatch is on `"t"`. Anything else — including a message that does
not parse — is ignored and returns `:ignored`. A malformed message from a peer is **data, not a
bug**; `channel-receive` never signals (`dom/channel.lisp`).

Any message may carry `"a"` to route it to an app (§11.3). `on-message` itself ignores `"a"`.

**Viewport report** — the consumer-negotiated slice (§12):

```json
{"t":"viewport","rows":12,"scroll":0}
```

`rows` is applied only if it is an integer and positive; `scroll` only if an integer, and it is
passed through `scroll-to`, which clamps against this consumer's `content-height` and
`viewport-height`. Either may be omitted.

**Gesture** — Rule 5's closed enum, recognized at the edge:

```json
{"t":"gesture","g":"tap","key":"<key>"}
{"t":"gesture","g":"hold","key":"<key>"}
{"t":"gesture","g":"two-finger","dy":1}
```

- `g` must be exactly `"tap"`, `"hold"` or `"two-finger"`; anything else is ignored.
- `key` is the string the client was given in a delta. A key the consumer cannot currently see
  resolves to `NIL` and the gesture does nothing (`t/dom.lisp`: "a tap on a key this consumer
  cannot see does nothing at all").
- `two-finger` is pan and is handled by the *encoding*, not by `gesture-command`, which returns
  `:pass` for it precisely so the surface decides. `dy` is **in rows**, this consumer's scroll axis,
  and defaults to 0.
- **There are no coordinates on this wire.** A browser knows which node was clicked and the node
  carries its key, so the whole of glass's pixel hit-test is three lines here
  (`dom/consumer.lisp:%visible-by-key`).

**Direct command invocation:**

```json
{"t":"cmd","name":"revoke-terminal","key":"<key>","confirmed":true}
```

`name` is matched case-insensitively against everything **declared** for that presentation's type,
with `:authorized-only NIL` — so a client can name a command it was never offered, which is the
point (§13). `confirmed` is honoured only when it is literally `true`.

### 10.6 What a gesture means, server side

`src/menu.lisp:on-gesture`, shared by every encoding. Resolving `(x,y)` or a key to a presentation
is the encoding's; what the gesture *means* once it has landed is one rule for everyone.

| landed on | gesture | effect |
|---|---|---|
| nothing | `tap` | close any open menu |
| a `menu-item` of kind `:cancel` | `tap` | close the menu |
| a `menu-item` of kind `:command` | `tap` | if the command confirms → replace the menu with a confirmation; else run it and close |
| a `menu-item` of kind `:confirm` | `tap` | run it with `:confirmed t`, close the menu |
| content | `tap` | resolve the **declared default** for `(type, view)`; close the menu, set `selected`, run it |
| content | `hold` | open a menu of `applicable-commands` filtered by this consumer's invoker |
| content | `two-finger` | `:pass` — the encoding decides |

**Menus are presentations.** Opening one emits `:appeared` per item, closing emits `:gone`, and the
reconciler has no special case. `hold-drag-release` decomposes into a `hold` plus a `tap` on a menu
item, which is why Rule 5's vocabulary needed no new verb.

A menu item's key is `menu:<kind>:<command-name|cancel>` (`src/menu.lisp`). Note it does **not**
include the target, which is sound only because a consumer has at most one open menu.

---

## 11. Transports

A transport is **a function of one string**. `dom/channel.lisp` reduces the link to
`(lambda (frame-string) ...)` and owns the four things a host would otherwise write by hand:

1. a clock, which stops when the peer goes away;
2. **one lock** over ticks and messages — a gesture that opens a menu and a pass that would emit it
   cannot interleave, and neither can two messages back to back;
3. a send that **must not signal** — a transport that has gone away is an ordinary event on a link,
   counted (`channel-send-errors`) and logged **once**, not once per frame at 8 Hz;
4. a close that runs on every unwind path, is idempotent, and detaches the consumer.

What is left for a host is three calls, none of which can signal: `open-channel`,
`channel-receive`, `channel-close` (plus `mux-receive`/`mux-close` when a link carries several
apps).

`invoker` arrives from whoever opened the channel and is **never** derived from anything the client
said. Its default is `:device`, the narrower of the two, because a host that forgets to say who is
asking should get the guest.

### 11.1 WebSocket (`dom/serve.lisp`, `dom/ws.lisp`)

Development and demonstration only; deliberately a subset.

| | |
|---|---|
| bind | `127.0.0.1`, port 8787 by default |
| `GET /warp[?...]` | WebSocket upgrade; the query string may **narrow** the invoker (`?as=device`) and can never widen it |
| `GET /client.js` | the reference client, served rather than inlined because it is shared |
| `GET` anything else | `client.html` |
| frames | unfragmented text only; server→client unmasked; **an unmasked client frame drops the connection** |
| not implemented | extensions, `permessage-deflate`, fragmentation, ping/pong |
| defaults | `rows` 14, `budget` 100000 bytes, `hz` 8 |

One connection, **one consumer per app**. A per-connection lock guards the socket, because two
ticking threads interleaving WebSocket frames on one stream is a framing bug and only the thing
that owns the stream knows that.

`invoker-for` exists so the demo can seat an owner and a guest from one browser. **It does not
exist on the deployed path** — there the invoker comes from an authenticated identity, and a
browser is not trusted more for having a nicer client.

### 11.2 WebRTC data channel — the deployed path

`/home/claude/webrtc-data/demo/glass-webrtc/warp-channel.lisp` (gateway),
`shell.js` (channel creation), `payload.js` (the panels).

| | |
|---|---|
| channel | label `warp`, `negotiated: true`, **id 102**, `ordered: true` |
| created | in `shell.js`, **before `createOffer`** — signalling is one-shot and non-trickle and nothing renegotiates, so a channel that does not exist by the offer can never exist |
| handshake | **none.** A negotiated channel costs zero bytes to open, so the gateway learns it exists the only way it can: a message arrives on 102. **The first client message *is* the open.** |
| payload | the JSON strings of §10, one per SCTP message, via `sctp-send-string` |
| defaults | `rows` 12 (`WARP_ROWS`), `budget` **1024 bytes/pass** (`WARP_BUDGET`), `hz` 4 (`WARP_HZ`) |
| gate | the whole feature is off unless `WARP_CHANNEL` is set |

Two disciplines here are protocol-relevant and were learned the hard way:

- **The stream id claims its traffic unconditionally.** `warp-sid-p` is deliberately *not* gated on
  the feature flag. Gated, a phone whose page has the panel talking to a box that does not have the
  channel would fall past the clause into the **RFB** branch, and `{"t":"viewport",...}` would be
  handed to a remote desktop as input. Disabled means the bytes are **dropped**, not that the
  clause is skipped.
- **A disabled or unknown app drops, it does not decline.** There is no error frame. See §14.

**The invoker is `authorized-p`, asked of the desktop, and never the session's `via`**
(`warp-channel.lisp:warp-invoker-for`). The gateway already classifies a connection
`code`/`allowlist`/`device`, first match wins — and reusing that string is wrong in *both*
directions: an owner arriving on a magic link classifies as `code` (demoting the owner), and a
guest sent the same link also classifies as `code` (promoting the guest). One string, two opposite
authorities, because it was computed to answer *may this connection open at all* and not *who is
this*. A desktop that cannot be reached makes everybody a guest, which is the safe direction.

### 11.3 The multiplex: several apps, one link

A second data channel was not available — channels are made in `shell.js`, which is published to
nsite, so a fifth channel is a new tag, every login link minted against the old one dead, and a
desktop restart. A projection id is a file copy. And app ids are not a fixed resource the way
stream ids are.

So the routing is `dom/channel.lisp`'s, not the gateway's:

- A client message may carry **`"a"`**, the app id, a non-empty string. `message-app` reads it and
  never signals; malformed input routes to the default app, where `on-message` ignores it as
  always.
- A frame carries **`"a"`** back, present only when the consumer has a label.
- **The default app is the one with no name.** No `a` on the way in routes to it; its frames go
  back unlabelled. A client that has never heard of any of this sends and receives exactly the bytes
  it always did. Naming the default instead would have been tidier and would have changed every
  frame the device manager has ever sent.
- `mux-open-fn` is called **at most once per app**, on the first message naming it — the same
  discipline the negotiated channel already forces on the link. A failed or refused open is
  remembered, so a client that keeps asking costs one answer rather than one load attempt per
  message.
- **An app this host does not serve is dropped**, never quietly given the default one.
- A client applies only the frames addressed to *its* app and does not count the others' bytes
  (`dom/client.js:apply`).

Deployed app ids (`warp-channel.lisp:warp-app`): `NIL` → the device manager; `"files"` → the Miller
file browser, gated on `WARP_FILES`; `"chat"` → operandi-gui, gated on `WARP_CHAT`. Note that
`payload.js`'s app-menu ids (`'devices'`, `'files'`) are the menu registry's, not the wire's — the
device manager's client is constructed with no `app` option, so its wire label is absent.

### 11.4 What differs between the two bindings

| | WebSocket | WebRTC 102 |
|---|---|---|
| budget | ~100 KB (localhost) | ~1 KB (cellular, sharing a link with VP8) |
| `hz` | 8 | 4 |
| invoker | a query string may narrow it | an authenticated Nostr pubkey, checked against the desktop's allowlist |
| open | HTTP upgrade | the first message on the stream |
| close | close frame | the session's unwind path |
| non-warp traffic | none | see below |

**The one thing that is not true of both:** in the deployed gateway's *uncommitted* working tree,
stream 102 also carries messages that are **not** warp frames. `warp-on-message` calls
operandi-gui's `HANDLE-CONTROL` first and only falls through to `mux-receive` if it returns NIL.
So on that build, "everything on stream 102 is a warp frame" is false. See the divergence note at
the end of §14.

---

## 12. Viewport and capability negotiation

The line is **not** human versus agent. It is **whether the consumer can measure itself.**

- A **framebuffer cannot.** It is handed a size and lays out into it; `viewport-width`/`-height`
  read the framebuffer (`glass/surface.lisp`). Its slice is curated — someone chose it in advance.
- A **browser can**, and says so, in **rows**. So can a model.

### What a consumer reports

`{"t":"viewport","rows":<int>,"scroll":<int>}` — §10.5. Nothing else. There is no capability
string, no feature list, no version.

`rows` sets `dom-rows`, which is `viewport-height` for a `dom-consumer`
(`dom/consumer.lisp`). `content-height` is specialised to the object count, so the scroll clamp
lands in the same unit — **one scroll slot, Rule 7 intact, and the axis is the consumer's**.

`warp-files`' DOM consumer applies the same number **per column**, not to a flat list: the working
set is depth × rows (`files/dom.lisp:visible-rows`).

### When

- On first open. Because a negotiated channel has no handshake, **the viewport report is the
  hello** — the first byte on the link, and what tells the box a consumer exists at all
  (`payload.js`).
- On every later open, and on `resize` — a phone rotates.

### What the producer does with it

Slices `objects[scroll .. scroll+rows)` on the next pass (`dom/consumer.lisp:lay-out`). The surplus
comes back as ordinary `:gone` deltas.

> **The negotiation is a convergence, not a handshake.**

The server seats a consumer at *its own* default row count and its clock is already running, so the
first frame carries that default; the client's report then trims it and the difference arrives as
ordinary deltas. **Nobody waits for anybody.** Making the report part of opening the channel would
cost a handshake on a transport that deliberately has none, and would make the slice a thing you
agree once rather than a thing you can change — exactly wrong for a phone that rotates.

A consumer that never reports gets the host's default forever, and that is a working consumer.

---

## 13. Commands and writes

Reads are projections; **writes are commands** (`src/command.lisp`). Commands are declared against
presentation **types**, never wired to widgets, which is what lets one command set serve a DM
interface, a CLI, a GUI and an agent with the authorization written once.

A command carries: `name`, `arg-type`, `handler (object invoker)`, `authorize (invoker)`,
`destructive`, `confirm`, `cost`, `label`.

### Applicability

One flat rule: a command applies to a presentation whose type is `eq` to its `arg-type`. **No
translators, no nested input contexts, no chained matching** — that machinery is where CLIM's size
lives and the gesture vocabulary cannot express it anyway. `applicable-commands` sorts by name so a
menu does not reshuffle under the finger between renders.

### Defaults are declared, never derived

`define-default-command (type view name)` registers what `tap` invokes. Deriving from "most
specific applicable" is the seed of translator-creep, and a derived default can become destructive
without anyone editing a UI. So:

> `define-default-command` **signals** if the command is `destructive`.

Rejected at declaration rather than trusted to a reviewer (`t/files.lisp` asserts the refusal).
Destructive commands are hold-menu only, and `confirm` ones refuse to run without `:confirmed t`.

### Authorization is enforced at invocation

`invoke (name object invoker &key confirmed)` checks `authorize` and then `confirm`, and signals
`command-refused` — regardless of which surface asked and regardless of what any menu displayed.

> **Menu filtering is courtesy, not security.**

`applicable-commands` with `:authorized-only t` is for display. `on-message`'s `cmd` path
deliberately resolves with `:authorized-only NIL`, so a client can name a command it was never
offered — which is the whole point of the path existing. `t/dom.lisp` and `t/channel.lisp` both pin
it end to end: a guest's `revoke` reaches the enforcement point, is refused there, **nothing is
written**, and the owner over the same projection at the same instant may.

The GUI must not become a second enforcement point someone later trusts. This is also why the menu
*model* — what a menu is, what is on it, what tapping an item does — is core's and not an
encoding's: a consumer that reimplemented "destructive commands confirm first" would be that second
point.

### Where the invoker comes from

> **The invoker is the output of the same predicate the policy is written against — never a nearby
> value computed for a different question.**

See §11.2 for the concrete failure this rule was written from. `invoker` is set at
`open-channel` time by the host and is never touched by anything on the wire.

### What a client learns about the outcome

**Nothing directly.** `run-command` stores the result (or `(:refused reason)`) in
`consumer-last-result`, which is server-side state and is **never serialized**. A client observes a
command only through its effect on the next pass's deltas. See §14.

---

## 14. Not specified

Each of these is a real gap, recorded as its honest shape rather than designed around. An
implementer should read this as the list of things not to assume.

**Binary payloads.** The DOM wire is JSON cells and cannot say "this is a picture". The opaque node
(§10.3) is the answer for *captioning* a region a consumer cannot render, and it is deliberately
not a smuggling route: `files/dom.lisp` refuses to invent a side channel because doing so would
answer an unasked question and destroy the only test of Rule 9's actual claim. There is no agreed
way to move an image, a font, or an audio buffer to a DOM consumer.

**Input into an opaque node.** Rule 5's gesture enum is closed and deliberately semantic; a pixel
region wants raw keys and coordinates. No escape hatch is defined, and one added carelessly becomes
a hole.

**Discovery — nothing on the wire says which apps or facets exist.** A host that does not serve an
app returns `NIL` and the mux **drops** the message, so the answer is *silence*, which is
indistinguishable from a slow link. Deliberately not fixed by a `hello` that enumerates the bundle,
because **asking costs whatever the app costs to load** (`:warp-files` drags warren → gesso,
scribe, pigment into the image at first mention), so an enumeration is either a lie about what would
load or a reason to load everything. Clients guess with a timeout: `payload.js` waits 5 s for a
frame and then says "no answer — this box is not serving …". That heuristic is a client convention,
not protocol.

**There is no error, nack, or refusal message of any kind.** A refused command, an unknown app, a
malformed message and a dead app are all *silence*. A client cannot distinguish "refused" from
"not delivered" from "not implemented".

**A client cannot request a resync.** `resync` is server-initiated only; no message type reaches
it. A client that believes it has lost state can only drop the link and reconnect — which works,
because attaching allocates a fresh empty stream, but it is a heavier answer than the protocol
implies.

**`:appeared` for a key the client already holds.** Reachable via `resync`. A correct client must
replace. **The reference client does not:** `dom/client.js:applyDelta`'s `appeared` case creates a
new element and overwrites the map entry without removing the old node, so a resync on a live DOM
consumer duplicates every row it re-announces. Latent — nothing in the deployed gateway calls
`resync` — but it is a client bug, not a wire ambiguity.

**Ordering within a priority band is unspecified** (§6), and `:gone` ordering is hash-table
iteration order. Consumers must not depend on either.

**Independent diff scopes do not exist.** There is one `delivered` table per consumer. A subtree
cannot be diffed, budgeted, or resynced without touching its siblings; nesting works only because
keys are composite and no column-shaped thing exists that could have been re-sent. Cost is O(all
rows) per pass either way. A session that wants one scope per window needs a reconciler change.

**Container trees.** `cs` is a sequence; `in` is a flat name; containers do not nest.

**Frame size.** The budget bounds `deltas` only. Nothing bounds the envelope, and `cs` grows with
the number of open containers. There is no fragmentation and no maximum message size at the warp
layer; a frame is one transport message.

**Versioning.** No frame or message carries a protocol version. Skew is expected to fail on a
missing JSON key.

**Key uniqueness under `princ`** (§2) is a constraint on key functions that nothing checks.

**`false` in a client message.** `dom/json.lisp` reads JSON `false` as the keyword `:false`, which
is **generalized-true in Lisp**. Only `confirmed` is compared safely (`(eq t ...)`). Any future
boolean field read with a bare truth test would misread `false` as true.

**`as_of`'s epoch is undocumented on the wire.** It is CL universal time (1900), not Unix (1970);
the reference client just concatenates it into a string. A client that treats it as Unix is off by
2208988800 seconds.

**Cost class does not travel on rows** (§8), only inside menu items.

**Two-finger `dy` is unbounded and unvalidated** beyond `scroll-to`'s clamp; there is no unit
declared other than "this consumer's axis", which for the DOM encoding is rows and for the
framebuffer is pixels.

### Divergences found between DESIGN.md and the code

1. **"Resync is a delta kind" (Rule 4) is not true of the code.** `delta-kind` is a closed set of
   four; resync is a *mode* of emission observable only as a generation bump plus a full
   re-announcement (§4, §7).
2. **"Reconcile matches on `(parent, key)`" (Rule 1) is false** — one flat table keyed by `p-key`.
   DESIGN.md already records this in its own status block; repeated here because the opening line
   still reads the other way.
3. **Client one no longer runs "over the enrolment file that gateway writes."** The deployed
   `warp-channel.lisp` queries the desktop's admission service over a socket
   (`glass:admission-records`) and replaces `warp-monitor:revoke-in-file` at load time with a
   service call. DESIGN.md's Client-one status describes the file-backed arrangement.
4. **DESIGN.md does not mention the first-delta budget exception** (§7), which is load-bearing:
   without it a budget smaller than one delta defers forever on a link that looks healthy.

### Notes on the sources

- `/home/claude/webrtc-data/demo/glass-webrtc/warp-channel.lisp` and `payload.js` both have
  **uncommitted changes from another context**, read but not modified here. The changes add a third
  app (`"chat"`, operandi-gui, gated on `WARP_CHAT`), move the admission host parameter from
  `*glass-host*` to `*admission-host*`, and — protocol-relevantly — make `warp-on-message` offer
  each message to operandi-gui's `HANDLE-CONTROL` **before** the mux, so stream 102 on that build
  carries messages that are not warp frames. §11.2 and §11.4 describe the committed behaviour and
  flag the working-tree behaviour explicitly.
- Claims taken from **comments rather than executable code** are marked where they matter. The two
  that are load-bearing and unasserted anywhere: warp-glass's invariant that "a pass paints only the
  extents the stream emitted, so the tiles glass finds dirty are exactly those extents"
  (`glass/surface.lisp` header), and the gateway's "the steady-state cost of this channel is zero"
  (`warp-channel.lisp`). Neither is checked by a test in this tree.

---

## 15. Conformance checklist for a consumer

A consumer of the DOM encoding is correct if it:

1. Parses each transport message as one JSON frame; ignores frames whose `a` is not its app.
2. Discards any frame whose `gen` is **lower** than the highest it has seen; records higher ones.
3. Applies `cs` **before** the frame's deltas, ordering app containers by it, keeping unmentioned
   ones at the end.
4. Creates app containers on demand and removes them when empty; routes `"rows"` and `"menu:*"` to
   host-owned elements.
5. Handles exactly four kinds; treats an unknown `k` as a no-op rather than an error.
6. On `appeared`: creates, **replacing any node it already holds for that key**.
7. On `changed`: repaints content *and* re-anchors.
8. On `moved`: re-anchors **without touching content**.
9. On `gone`: removes by key; expects no other field.
10. **Parks a node whose `after` anchor it does not yet hold, out of the document**, and places it
    when the anchor lands. Never invents a position.
11. Sends `{"t":"viewport",...}` on open and on resize, in **rows**.
12. Recognizes gestures locally — press-hold is a *timing* discrimination and timing it across
    100–300 ms of jittery link makes holds read as taps — and sends `tap` / `hold` / `two-finger`
    with the key it was given.
13. Never invents a command, never filters for safety, and never treats the absence of a menu entry
    as a guarantee.
14. On link close: forgets every node, because the server's memory went with the link.
15. Stamps `a` on every outbound message if and only if it is a client of a named app.
