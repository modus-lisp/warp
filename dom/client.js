// warp/dom/client.js — the DOM encoding's client.  ONE copy, two hosts, no transport.
//
// This file is loaded verbatim by two pages that have nothing else in common:
//
//   warp/dom/client.html                                a standalone page over a WebSocket
//   webrtc-data/demo/glass-webrtc/index-nostr.html      a panel over a WebRTC data channel
//
// and it is the same file in both because the client's job does not vary with the link.  A frame
// is a frame; MAKE-WARP-CLIENT takes a SEND and hands back an APPLY, which is the browser half of
// the same statement the server half makes by taking a SEND function and nothing else.
//
// It is deliberately small, and the smallness is the argument.  The client holds a Map from key to
// node and does four things with a delta: create, replace content, re-anchor, remove.  It does not
// diff, does not reconcile, does not keep a shadow tree and does not know what a projection is —
// all of that happened on the server, which is what "the stream carries state, not events" buys.
//
// It also does not decide anything about safety.  The menu it draws is whatever the server sent
// it; it cannot invent a command, and if it tried, the server would refuse it at invocation
// (DESIGN.md rule 6).
//
// THE HOST OWNS THE ELEMENTS AND THE STYLESHEET.  This file writes exactly these class names and
// nothing else, so a page can look however it likes without touching the logic:
//
//   on a row       selected | warn | bad     and cells .v (value) .l (label) .stale (as-of)
//   on a menu item destructive              and cells .t (label)  .c (cost class)
//   on an opaque node  opaque               and cells .cap (the caption) .dim (its size)
//   on a container container                and data-container="<the name the wire used>"
//
// GESTURES ARE SCOPED TO A ROOT ELEMENT, which is the one thing the standalone page did not need
// and the panel absolutely does: a listener on `document` inside a remote-desktop client would eat
// the pointer events the trackpad lives on.  ATTACHGESTURES(root) listens on root only.
//
// ONE LINK MAY CARRY SEVERAL PROJECTIONS.  A frame names the app it belongs to in `a`, and this
// client applies only the frames addressed to the app it was made for — OPTS.APP, which is null for
// the host's default one.  That is how a phone shows the device manager and the file browser at the
// same time over the one negotiated data channel it was able to open before the offer.

"use strict";
function makeWarpClient(opts) {
  const rowsEl = opts.rows;
  const menuEl = opts.menu;
  const out    = opts.send;                 // (object) -> void.  The whole of the transport.
  const onStat = opts.onStat || function () {};
  const ROWS   = opts.viewportRows || 14;   // what this viewport can show; reported to the server
  const APP    = opts.app == null ? null : opts.app;   // which projection this client is a surface for

  // Every message we send carries the app, so the host can route it back to the right consumer.  A
  // client of the default app stamps nothing, which is what keeps a one-app link byte-for-byte what
  // it was before any of this existed.
  function send(o) { if (APP != null) o.a = APP; return out(o); }

  // key -> {key, node, in, after}.  This is the client's ENTIRE model.  The server holds the
  // memory of what we have been told; we hold the nodes it named and the anchor each one was given.
  const nodes = new Map();

  // Anchor key -> the records waiting for it.  THIS IS NOT DEFENSIVE PADDING, it is load-bearing,
  // and it is the one thing an anchor-based encoding needs that a rectangle-based one does not.
  //
  // A rectangle is absolute: deltas carrying rectangles can be applied in any order at all.  An
  // anchor is RELATIVE, so "insert X after Y" is unappliable until Y exists — and two independent
  // things make that happen:
  //
  //   * the reconciler emits within a priority band in reverse layout order, so a pass that
  //     appends two rows sends `r05 after r04` before it sends `r04`;
  //   * and even in layout order, the BUDGET can defer the anchor to a later pass entirely, which
  //     no ordering rule on the server could fix.
  //
  // So a node whose place we do not know yet is held OUT of the document rather than dropped into
  // a place we invented, and it is inserted the moment its anchor lands.  Guessing would put a row
  // in the wrong place and leave it there, which is exactly the silent-wrong-order failure this
  // encoding's positions exist to prevent.
  const waiting = new Map();
  let gen = 0, frames = 0, bytes = 0, deltas = 0;
  let scroll = 0;

  // ---- containers: the wire has always named one, and only "rows" was ever real ----------------
  //
  // A delta's `in` is the NAME of the container the node belongs to.  Two of those names are the
  // encoding's own and the HOST owns an element for each: "rows" and "menu:<key>".  Every other
  // name is the APP's — "col:/tmp/foo/", "preview" — and a container for it is created here on
  // demand, inside the rows element, and removed when its last child leaves.  Until a client
  // nested, this function was `name === "rows" ? rowsEl : menuEl` and every app container in
  // existence rendered into the hold-menu, silently, because no app had ever named one.
  //
  // WHERE A CONTAINER GOES IS NOT DERIVABLE FROM THE DELTAS, and that is the whole reason `cs`
  // exists.  `after` orders siblings WITHIN a container and says nothing at all across them, and a
  // pass emits within a priority band in reverse layout order — so the rightmost Miller column's
  // rows arrive FIRST, and ordering containers by first appearance would draw the columns right to
  // left.  So the frame carries `cs`: the app's containers, in layout order, as state rather than
  // as an event.  It is the same obligation rule 4 already puts on an anchor, one level up: never
  // put a thing in a position you invented.
  //
  // Containers do not nest in containers.  `in` is a flat name and a frame says nothing about a
  // container's own parent, so `cs` is a sequence, not a tree — Miller columns want exactly that,
  // and a client that wanted a tree would need the wire to say so.
  const containers = new Map();     // name -> element, for the app's containers only
  let order = [];                   // `cs`, as the server last stated it

  function container(name) {
    if (name == null || name === "rows") return rowsEl;
    if (name.lastIndexOf("menu:", 0) === 0) return menuEl;
    let el = containers.get(name);
    if (!el) {
      el = document.createElement("ul");
      el.className = "container";
      el.dataset.container = name;
      containers.set(name, el);
      orderContainers();
    }
    return el;
  }

  // The app's containers, in the order the server last stated.  One left-to-right pass with
  // insertBefore: a container already in its place is not touched, so re-stating an unchanged
  // order costs nothing and moves nothing.  A container we hold that `cs` does not mention keeps
  // its relative place at the end rather than being guessed at.
  function orderContainers() {
    if (!containers.size || !rowsEl) return;
    const seq = order.filter((n) => containers.has(n));
    for (const n of containers.keys()) if (seq.indexOf(n) < 0) seq.push(n);
    let prev = null;
    for (const n of seq) {
      const el = containers.get(n);
      const want = prev ? prev.nextSibling : rowsEl.firstChild;
      if (el !== want) rowsEl.insertBefore(el, want);
      prev = el;
    }
  }

  // A container is the app's claim that a group EXISTS, and the only evidence it still does is that
  // something is in it.  Emptied — the column closed, the preview cleared — it goes, so the host's
  // stylesheet never has to reason about a box with nothing in it.  Anything else the client made
  // is left alone: a node parked waiting for its anchor is out of the document, and dropping the
  // container it named would be inventing an answer to a question nobody asked.
  function dropIfEmpty(el) {
    if (!el || !el.dataset || !el.dataset.container || el.firstChild) return;
    containers.delete(el.dataset.container);
    el.remove();
  }

  // The four kinds, and nothing else.  Note what is NOT here: no re-render, no keyed list diff, no
  // virtual DOM.  A :moved does not touch the node's content, which is the entire point of rule 2.
  function applyDelta(d) {
    const rec = nodes.get(d.key);
    switch (d.k) {
      case "appeared": {
        const li = document.createElement("li");
        li.dataset.key = d.key;
        paint(li, d);
        const r = {key: d.key, node: li, in: d.in, after: d.after};
        nodes.set(d.key, r);
        place(r);
        break;
      }
      case "changed": {
        if (!rec) return;
        paint(rec.node, d);
        rec.in = d.in; rec.after = d.after;
        place(rec);
        break;
      }
      case "moved": {
        if (!rec) return;
        rec.in = d.in; rec.after = d.after;
        place(rec);                   // content untouched: the node is re-anchored, not rebuilt
        break;
      }
      case "gone": {
        if (!rec) return;
        const from = rec.node.parentNode;
        rec.node.remove();
        nodes.delete(d.key);
        dropIfEmpty(from);
        break;
      }
    }
  }

  // `after` is the key of the sibling this node follows, null meaning first child.  That is the
  // whole of the DOM's positional vocabulary and it is exactly what the server sends.
  function place(rec) {
    const parent = container(rec.in);
    if (!parent) return;
    const from = rec.node.parentNode;         // where it was, so an emptied container can go
    if (rec.after == null) {
      if (rec.node.parentNode !== parent || parent.firstChild !== rec.node) {
        parent.insertBefore(rec.node, parent.firstChild);
      }
    } else {
      const a = nodes.get(rec.after);
      if (!a || a.node.parentNode !== parent) {   // the anchor has not arrived, or is itself parked
        let w = waiting.get(rec.after);
        if (!w) waiting.set(rec.after, w = []);
        if (!w.includes(rec)) w.push(rec);
        if (rec.node.parentNode) rec.node.remove();
        if (from !== parent) dropIfEmpty(from);
        return;
      }
      if (rec.node.parentNode !== parent || rec.node.previousSibling !== a.node) {
        parent.insertBefore(rec.node, a.node.nextSibling);
      }
    }
    if (from && from !== parent) dropIfEmpty(from);
    const w = waiting.get(rec.key);               // anything that was waiting on us can go in now
    if (w) { waiting.delete(rec.key); for (const r of w) place(r); }
  }

  function paint(li, d) {
    const cells = d.cells || [];
    if (d.type === "menu-item") {
      li.className = cells[2] === "destructive" ? "destructive" : "";
      li.innerHTML = "";
      li.append(cell("t", cells[0]));
      if (cells[1]) li.append(cell("c", cells[1]));
    } else if (cells[2] === "opaque") {
      // AN OPAQUE NODE IS A HOLE, AND THE CAPTION IS THE WHOLE OF WHAT WE GET (DESIGN.md rule 9).
      // The app offers this region as pixels; this client cannot blit and is not going to be given
      // a way to — the wire is JSON cells, "binary payloads" is an open design question, and
      // sneaking the bytes through here would answer it by accident.  What arrives is a caption the
      // app chose and a size, so what we draw is a labelled placeholder saying what is not shown.
      // It is not a row and must not look like one, which is why it gets its own class and cells.
      li.className = "opaque";
      li.innerHTML = "";
      li.append(cell("cap", cells[0]));
      if (cells[1]) li.append(cell("dim", cells[1]));
      if (d.as_of) { li.append(cell("stale", "as of " + d.as_of)); }
    } else {
      li.className = (d.state && d.state.selected) ? "selected " + trend(cells[2]) : trend(cells[2]);
      li.innerHTML = "";
      li.append(cell("v", cells[0]), cell("l", cells[1]));
      // as_of is on every delta because DESIGN.md makes staleness first-class: under a budget a
      // delta can arrive several passes late, and the consumer is entitled to see it.
      if (d.as_of) { li.append(cell("stale", "as of " + d.as_of)); }
    }
  }
  function trend(t) { return t === "bad" ? "bad" : t === "warn" ? "warn" : ""; }
  function cell(cls, text) {
    const s = document.createElement("span");
    s.className = cls; s.textContent = text == null ? "" : String(text);
    return s;
  }

  // One frame, as it arrived on whatever the link is.  Takes the raw string so the byte count is
  // the real one; a host that already parsed it can pass the object instead.
  function apply(data) {
    let frame = data, raw = null;
    if (typeof data === "string") { raw = data; try { frame = JSON.parse(data); } catch (_) { return null; } }
    if (!frame) return null;
    // A frame addressed to another projection on this link is not ours to apply, and not ours to
    // count either: BYTES is what THIS surface cost, which is the number a panel reports and the
    // number a budget is checked against.
    if ((frame.a == null ? null : frame.a) !== APP) return null;
    if (raw !== null) bytes += raw.length;
    frames++;
    if (!frame.deltas) return null;
    // rule 4: snapshot chunks carry a generation, and anything older than the newest is discarded.
    if (frame.gen < gen) return frame;
    if (frame.gen > gen) { gen = frame.gen; }
    // The container order comes FIRST, so a container created by the deltas below already knows
    // where it belongs and no column is ever briefly drawn in the wrong place.
    if (frame.cs) { order = frame.cs; orderContainers(); }
    for (const d of frame.deltas) { deltas++; applyDelta(d); }
    onStat(stats());
    return frame;
  }

  // A LINK THAT WENT AWAY TAKES THE SERVER'S MEMORY WITH IT.  The server detaches the consumer on
  // close, so a reconnecting client is a NEW consumer with an empty stream and will be sent a full
  // snapshot (rule 8: attaching is not a resync).  Holding our old nodes across that would leave
  // rows on screen that the new stream never mentions and can therefore never remove.
  function reset() {
    for (const r of nodes.values()) r.node.remove();
    nodes.clear(); waiting.clear();
    for (const el of containers.values()) el.remove();
    containers.clear(); order = [];
    rowsEl.innerHTML = ""; if (menuEl) menuEl.innerHTML = "";
    gen = 0; deltas = 0;
  }

  function stats() {
    return {gen, frames, bytes, deltas, nodes: nodes.size, parked: waiting.size, scroll,
            containers: containers.size};
  }

  // ---- gestures: recognized HERE, sent as semantics.  Rule 5's vocabulary is closed and this
  // file does not extend it — every browser event below lands on tap / hold / two-finger.

  let holdTimer = null, held = null, listeners = null;

  function keyAt(ev) {
    const li = ev.target.closest ? ev.target.closest("li[data-key]") : null;
    return li ? li.dataset.key : null;
  }

  function attachGestures(root) {
    detachGestures();
    const onDown = (ev) => {
      held = keyAt(ev);
      if (!held) return;
      // press-hold is a TIMING discrimination and it is timed locally, on purpose: 100-300ms of
      // jittery link would make a hold read as a tap if the server tried to time it.
      holdTimer = setTimeout(() => { holdTimer = null; send({t: "gesture", g: "hold", key: held}); },
                             400);
    };
    const onUp = () => {
      if (holdTimer) {
        clearTimeout(holdTimer); holdTimer = null;
        // A release inside the hold window is a tap.  A release AFTER it lands on whatever is under
        // the finger, which for an open menu is a menu item — that is rule 5's hold-drag-release,
        // and it needs no verb of its own because menu items are presentations you can tap.
        if (held) send({t: "gesture", g: "tap", key: held});
      }
      held = null;
    };
    const onCtx = (ev) => {                                    // right-click is a hold
      const k = keyAt(ev);
      if (k) { ev.preventDefault(); send({t: "gesture", g: "hold", key: k}); }
    };
    const onWheel = (ev) => {                                  // wheel is the two-finger pan
      const dy = ev.deltaY > 0 ? 1 : -1;
      scroll = Math.max(0, scroll + dy);
      send({t: "gesture", g: "two-finger", dy: dy});
    };
    root.addEventListener("pointerdown", onDown);
    root.addEventListener("pointerup", onUp);
    root.addEventListener("contextmenu", onCtx);
    root.addEventListener("wheel", onWheel, {passive: true});
    listeners = {root, onDown, onUp, onCtx, onWheel};
  }

  function detachGestures() {
    if (!listeners) return;
    const l = listeners; listeners = null;
    l.root.removeEventListener("pointerdown", l.onDown);
    l.root.removeEventListener("pointerup", l.onUp);
    l.root.removeEventListener("contextmenu", l.onCtx);
    l.root.removeEventListener("wheel", l.onWheel);
    if (holdTimer) { clearTimeout(holdTimer); holdTimer = null; }
    held = null;
  }

  return {
    apply, reset, stats, attachGestures, detachGestures,
    // the viewport report: the consumer-negotiated slice, in ROWS, which is this encoding's axis
    hello: (rows, sc) => send({t: "viewport", rows: rows || ROWS, scroll: sc == null ? scroll : sc}),
    // the test harness drives these; a human uses the mouse
    tap: (k) => send({t: "gesture", g: "tap", key: k}),
    hold: (k) => send({t: "gesture", g: "hold", key: k}),
    cmd: (name, key, confirmed) => send({t: "cmd", name, key, confirmed: !!confirmed}),
    viewport: (rows, sc) => send({t: "viewport", rows, scroll: sc}),
    // every row this client holds, in document order — which for a flat app is the rows element's
    // own children and for a nesting one reads across its containers, left to right
    keys: () => [...rowsEl.querySelectorAll("li[data-key]")].map((li) => li.dataset.key),
    menu: () => (menuEl ? [...menuEl.children].map((li) => li.dataset.key) : []),
    // the nesting as it was RENDERED: container name -> the keys in it, in document order.  A test
    // that checks this is checking the DOM, not the client's own idea of the DOM.
    containers: () => [...rowsEl.children]
      .filter((el) => el.dataset && el.dataset.container)
      .map((el) => [el.dataset.container,
                    [...el.children].map((li) => li.dataset.key)]),
    // the anchor chain as the client believes it, so a test can check the DOM against the WIRE
    // rather than against the client's own idea of the DOM
    anchors: () => Object.fromEntries([...nodes].map(([k, r]) => [k, r.after])),
    parked: () => [...waiting.keys()]
  };
}
if (typeof window !== "undefined") window.makeWarpClient = makeWarpClient;
