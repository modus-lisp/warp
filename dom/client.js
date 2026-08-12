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
//
// GESTURES ARE SCOPED TO A ROOT ELEMENT, which is the one thing the standalone page did not need
// and the panel absolutely does: a listener on `document` inside a remote-desktop client would eat
// the pointer events the trackpad lives on.  ATTACHGESTURES(root) listens on root only.

"use strict";
function makeWarpClient(opts) {
  const rowsEl = opts.rows;
  const menuEl = opts.menu;
  const send   = opts.send;                 // (object) -> void.  The whole of the transport.
  const onStat = opts.onStat || function () {};
  const ROWS   = opts.viewportRows || 14;   // what this viewport can show; reported to the server

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

  function container(name) {
    return name === "rows" ? rowsEl : menuEl;
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
        rec.node.remove();
        nodes.delete(d.key);
        break;
      }
    }
  }

  // `after` is the key of the sibling this node follows, null meaning first child.  That is the
  // whole of the DOM's positional vocabulary and it is exactly what the server sends.
  function place(rec) {
    const parent = container(rec.in);
    if (!parent) return;
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
        return;
      }
      if (rec.node.parentNode !== parent || rec.node.previousSibling !== a.node) {
        parent.insertBefore(rec.node, a.node.nextSibling);
      }
    }
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
    let frame = data;
    if (typeof data === "string") { bytes += data.length; try { frame = JSON.parse(data); } catch (_) { return null; } }
    frames++;
    if (!frame || !frame.deltas) return null;
    // rule 4: snapshot chunks carry a generation, and anything older than the newest is discarded.
    if (frame.gen < gen) return frame;
    if (frame.gen > gen) { gen = frame.gen; }
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
    rowsEl.innerHTML = ""; if (menuEl) menuEl.innerHTML = "";
    gen = 0; deltas = 0;
  }

  function stats() {
    return {gen, frames, bytes, deltas, nodes: nodes.size, parked: waiting.size, scroll};
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
    keys: () => [...rowsEl.children].map((li) => li.dataset.key),
    menu: () => (menuEl ? [...menuEl.children].map((li) => li.dataset.key) : []),
    // the anchor chain as the client believes it, so a test can check the DOM against the WIRE
    // rather than against the client's own idea of the DOM
    anchors: () => Object.fromEntries([...nodes].map(([k, r]) => [k, r.after])),
    parked: () => [...waiting.keys()]
  };
}
if (typeof window !== "undefined") window.makeWarpClient = makeWarpClient;
