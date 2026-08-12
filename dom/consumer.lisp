;;;; dom/consumer.lisp — warp's DOM encoding.  Five methods, and no pixels anywhere.
;;;;
;;;; The four decisions this encoding had to make, and why:
;;;;
;;;; 1. WHAT REPLACES THE EXTENT.  Nothing geometric.  A browser does its own layout — that is the
;;;;    single most useful thing about it — so a server that shipped rectangles would be shipping a
;;;;    claim the client is entitled to ignore, and rule 3's 16px grid is a fact about a VP8 encoder
;;;;    that has no counterpart here at all.  But P-EXTENT cannot simply be NIL either, and finding
;;;;    out why is the sharpest thing this encoding taught us: the reconciler decides "nothing owed"
;;;;    with (equal (p-extent old) (p-extent new)), so with NIL extents everywhere a RE-SORT of the
;;;;    result set emits NOTHING and the browser keeps a stale order forever, silently.
;;;;
;;;;    So P-EXTENT here is the DOM's own positional fact: (parent . after) — the container this
;;;;    node belongs to, and the key of the sibling it follows, NIL meaning first child.  That is
;;;;    exactly the pair `insertBefore` takes, it compares with EQUAL like any extent, and it is
;;;;    rule 1's "keys are scoped to the parent" written as data.
;;;;
;;;; 2. WHAT :MOVED MEANS.  It does not collapse — it is the one encoding where rule 2 finally pays.
;;;;    A browser reorders nodes rather than translating pixels, so there is no (dx dy) and MOVED-P
;;;;    returns a bare T; the new place travels on the presentation.  And because a DOM has no
;;;;    absolute coordinates, the rows a scroll did not touch DO NOT MOVE: scrolling one row emits
;;;;    one :gone, one :appeared and exactly ONE :moved (the new first row, whose predecessor
;;;;    vanished), where the framebuffer emits a :moved for every surviving row.  Rule 2 promised
;;;;    "fifty rows moved, contents unchanged" as one assertion instead of fifty re-sends; here the
;;;;    same scroll is one assertion instead of fifty assertions.
;;;;
;;;; 3. WHAT THE BUDGET IS SPENT IN.  Bytes of the serialized delta — the number that actually
;;;;    travels.  This is what DELTA-COST was made generic for.
;;;;
;;;; 4. WHERE THE VIEWPORT COMES FROM.  The browser, which is the consumer-negotiated-slice case
;;;;    DESIGN.md reserves for agents: a framebuffer's viewport is a fact about hardware, but a
;;;;    browser knows how many rows it can show and says so.  It reports rows and a row offset, so
;;;;    this consumer's scroll axis is in ROWS — one scroll slot, rule 7 intact, CONTENT-HEIGHT
;;;;    specialised so the clamp is in the same unit.

(in-package #:warp-dom)

;;; ---- the consumer -----------------------------------------------------------

(defclass dom-consumer (consumer)
  ((sink :initarg :sink :initform nil :accessor dom-sink
         :documentation "(lambda (frame-string)) — where a pass's JSON goes.  A WebSocket write, a
data-channel send, or NIL: with no sink the frames pile up in OUTBOX and the encoding is fully
testable with no socket in the image, which is how every assertion in t/dom.lisp is made.")
   (outbox :initform '() :accessor dom-outbox)
   (rows :initarg :rows :initform 12 :accessor dom-rows
         :documentation "How many rows the browser says it can show.  It is the browser's number,
not ours — see the header's point 4.")
   (last-frame-bytes :initform 0 :accessor dom-last-frame-bytes)
   (sent-bytes :initform 0 :accessor dom-sent-bytes
               :documentation "Total bytes this consumer has actually put on its link.  The budget
is denominated in these, so this is the one counter that can check it."))
  (:documentation "One consumer whose encoding target is a DOM in somebody else's browser."))

(defun attach-dom (projection &rest initargs)
  "WARP:ATTACH with this file's encoding as the class.  Everything else about attaching — the empty
stream, the late-joiner discipline — is warp's and is not repeated here."
  (apply #'warp:attach projection :class 'dom-consumer initargs))

;;; The viewport and the scroll axis are in ROWS.  VIEWPORT-WIDTH is left alone deliberately: this
;;; encoding has no opinion about width, because the browser's stylesheet does.

(defmethod viewport-height ((c dom-consumer)) (dom-rows c))

(defmethod content-height ((c dom-consumer))
  (length (projection-objects (consumer-projection c))))

;;; ---- position, and what moving means ----------------------------------------

(defparameter +rows-container+ "rows")

(defun dom-container (p) (car (p-extent p)))
(defun dom-after (p) (cdr (p-extent p)))

(defmethod moved-p ((c dom-consumer) old new)
  "Same content, new sibling position.  Returns T rather than a (dx dy): a DOM translation vector
does not exist, and inventing a fake one would be a number a client could believe.

A change of CONTAINER returns NIL on purpose, so the diff falls through to :changed and the client
re-parents with the content in hand.  Rule 1 says re-parenting should read as :gone + :appeared, and
that it never happens anyway because keys are scoped to the parent; :changed is the safe answer for
the case rule 1 says cannot arise, rather than a third behaviour nobody will ever exercise."
  (declare (ignorable c))
  (let ((a (p-extent old)) (b (p-extent new)))
    (and (consp a) (consp b)
         (equal (car a) (car b))
         (not (equal (cdr a) (cdr b)))
         t)))

;;; ---- layout: keys, types, content, order — and no geometry -------------------

(defmethod lay-out ((c dom-consumer) objects as-of)
  "This consumer's slice, in sibling order, with no extents in the geometric sense at all.

The slice is the browser's: OBJECTS[scroll .. scroll+rows).  That is the same working-set discipline
as the framebuffer's — a view subscribes to a slice and the slice is what the consumer is told about
— arrived at from the other end, because the browser knows how many rows fit and a framebuffer has
to be measured."
  (let* ((all objects)
         (n (length all))
         (first (max 0 (min (consumer-scroll-y c) n)))
         (last (min n (+ first (viewport-height c))))
         (type-fn (projection-type-fn (consumer-projection c)))
         (sel (consumer-selected c))
         (prev nil))
    (loop for o in (subseq all first last)
          for ty = (row-type-of type-fn o)
          for key = (presentation-key ty o)
          collect (let ((p (make-presentation
                            :key key :type ty :object o
                            :extent (cons +rows-container+ prev)
                            :fingerprint (present o ty (consumer-view c))
                            :as-of as-of)))
                    ;; rule 7: this consumer's view state, on this consumer's own presentation
                    (when (equal sel key) (setf (p-state p) (list :selected t)))
                    (setf prev key)
                    p))))

;;; ---- the menu: the model is core's, the PLACE is ours ------------------------

(defmethod menu-presentations ((c dom-consumer))
  "The open menu's items, in order, parented on the row that was held.

Core's default gives them no extents because core has no geometry to claim; this encoding does have
a positional claim to make and it is not a rectangle either — it is `these nodes go in a list that
hangs off that row`.  Which commands are on it, and what tapping one does, are untouched: those are
rules 5 and 6 and reimplementing them here is the second enforcement point rule 6 refuses."
  (let ((m (consumer-menu c)))
    (when m
      (destructuring-bind (&key target items) m
        (let ((container (format nil "menu:~a" (if target (p-key target) "")))
              (prev nil))
          (loop for it in items
                for key = (presentation-key 'menu-item it)
                collect (prog1 (make-presentation
                                :key key :type 'menu-item :object it
                                :extent (cons container prev)
                                :fingerprint (present it 'menu-item (consumer-view c))
                                :as-of (now-tick))
                          (setf prev key))))))))

;;; ---- serialization, and therefore cost --------------------------------------

(defun %cells (fingerprint)
  "PRESENT's output, as a JSON array.  A fingerprint is a list of cells — strings, keyword tags like
:ok / :destructive / :gateway, numbers — and %JSON-WRITE already renders each of those the way a
client wants to read it."
  (if (listp fingerprint) fingerprint (list fingerprint)))

(defun %state (p)
  (let ((s (and p (p-state p))))
    (when s (cons :obj (loop for (k v) on s by #'cddr
                             collect (cons (string-downcase (string k)) (and v t)))))))

(defun delta-json (d)
  "One delta, as the object the client applies.  KEY and K are always present; everything else is
present only when it means something, because every field is charged to the budget.

  appeared  key type in after cells [state] as_of     a node to create
  changed   key type in after cells [state] as_of     the same node, new content and/or place
  moved     key in after as_of                        the same node, new place, content untouched
  gone      key                                       remove it"
  (let* ((p (delta-presentation d))
         (kind (delta-kind d))
         ;; :gone carries the place it USED to be, which is the framebuffer's repair rectangle and
         ;; is of no use to a client that removes by key.  So place travels only where it is acted on.
         (place (and (member kind '(:appeared :changed :moved)) (delta-extent d))))
    (to-json
     (cons :obj
           (append
            (list (cons "k" (string-downcase (symbol-name kind)))
                  (cons "key" (princ-to-string (delta-key d))))
            (when (and p (member kind '(:appeared :changed)))
              (list (cons "type" (string-downcase (symbol-name (p-type p))))))
            (when (consp place)
              (list (cons "in" (car place))
                    (cons "after" (and (cdr place) (princ-to-string (cdr place))))))
            (when (and p (member kind '(:appeared :changed)))
              (list (cons "cells" (%cells (p-fingerprint p)))))
            (let ((st (%state p))) (when st (list (cons "state" st))))
            ;; DESIGN.md: every presentation carries its AS-OF, and a budgeted stream is exactly
            ;; where that stops being decorative — a delta delivered three passes late is old news
            ;; and the client is entitled to know by how much.  It costs ~16 bytes of the budget and
            ;; dropping it to save them would be the wrong trade made silently.
            (when (and p (p-as-of p)) (list (cons "as_of" (p-as-of p)))))))))

(defmethod delta-cost ((c dom-consumer) d)
  "Bytes.  Not macroblocks, not deltas: the number that actually goes down the link, measured by
serializing the thing we are about to send.

It serializes twice per delivered delta — once to price it, once to ship it — and that is a
deliberate choice over caching the string on the delta: the delta struct is core's, the cost is this
encoding's, and a cache field on a shared struct for one encoding's benefit is precisely the kind of
leak rule 8 was carved to stop.  Two passes over a 120-byte string is not the expensive part of a
round that just ran a query."
  (declare (ignorable c))
  (length (sb-ext:string-to-octets (delta-json d) :external-format :utf-8)))

;;; ---- the encoding: deltas become a frame on somebody's link ------------------

(defun frame-for (c deltas)
  "One pass, as one JSON message.

GEN is rule 4's generation marker: a client must discard anything older than the newest snapshot it
has seen, and putting it on the frame rather than on every delta is the one place we spend the wire
on structure instead of content — a snapshot's chunks all carry it and it is per-pass by nature."
  (format nil "{\"gen\":~d,\"deltas\":[~{~a~^,~}]}"
          (ds-generation (consumer-stream c))
          (mapcar #'delta-json deltas)))

(defmethod apply-deltas ((c dom-consumer) deltas)
  (let* ((frame (frame-for c deltas))
         (bytes (length (sb-ext:string-to-octets frame :external-format :utf-8))))
    (setf (dom-last-frame-bytes c) bytes)
    (incf (dom-sent-bytes c) bytes)
    (incf (consumer-landed c) (length deltas))
    (if (dom-sink c)
        (funcall (dom-sink c) frame)
        (push frame (dom-outbox c)))
    frame))

(defun take-frames (c)
  "Hand over the frames this consumer has been landed and forget them — the flush a transport does,
and the only way to read a sink-less consumer."
  (prog1 (nreverse (dom-outbox c)) (setf (dom-outbox c) '())))

;;; ---- input: a key and a gesture, never a coordinate --------------------------
;;;
;;; Rule 5 puts recognition at the edge and carries semantics on the wire.  glass receives that in a
;;; lossy encoding (RFB pointer events) and has to hit-test pixels to get back to a presentation.  A
;;; browser has no such loss: it knows which node was clicked and the node carries its key, so the
;;; whole of glass's HIT is three lines here — which is what rule 5 was describing all along.
;;;
;;; The vocabulary is CLOSED and this file does not extend it.  The mapping is:
;;;
;;;   click                                -> tap
;;;   contextmenu / long-press (client-timed, 400ms, no movement)  -> hold
;;;   hold then click a menu item          -> hold-drag-release, decomposed
;;;   wheel / touch scroll (client-timed)  -> two-finger, carrying a row delta
;;;
;;; hold-drag-release is one continuous gesture on a phone and rule 5 says so, but the menu items
;;; ARE presentations: the browser paints them, the release lands on one, and it arrives as a tap on
;;; a menu-item.  That is the same decomposition glass makes, and it is why no new verb was needed.

(defun %visible-by-key (c key)
  (find key (consumer-visible c) :key #'p-key :test #'equal))

(defun on-message (c text)
  "Apply one client message.  Returns (values kind detail) for a caller that wants to log it.

Everything here is this consumer's — its scroll, its menu, its selection, its invoker.  A second
consumer over the same projection is not disturbed by any of it."
  (let* ((msg (handler-case (from-json text) (error () nil)))
         (type (and msg (json-get msg "t"))))
    (cond
      ((null type) (values :ignored text))

      ;; the browser tells us its own viewport — the consumer-negotiated slice
      ((string= type "viewport")
       (let ((rows (json-get msg "rows")) (scroll (json-get msg "scroll")))
         (when (and (integerp rows) (plusp rows)) (setf (dom-rows c) rows))
         (when (integerp scroll) (scroll-to c scroll))
         (values :viewport (list (dom-rows c) (consumer-scroll-y c)))))

      ;; a recognized gesture, against a key the client already holds
      ((string= type "gesture")
       (let* ((g (json-get msg "g"))
              (key (json-get msg "key"))
              (gesture (cond ((equal g "tap") :tap)
                             ((equal g "hold") :hold)
                             ((equal g "two-finger") :two-finger))))
         (cond
           ((null gesture) (values :ignored g))
           ;; rule 5: two-finger is pan, and panning is the encoding's to do — GESTURE-COMMAND
           ;; returns :pass for it precisely so the surface decides.  In rows, because that is
           ;; this consumer's axis.
           ((eq gesture :two-finger)
            (scroll-by c (or (json-get msg "dy") 0))
            (values :scrolled (consumer-scroll-y c)))
           (t
            (on-gesture c gesture (and key (%visible-by-key c key)))
            (values :gesture (list gesture key))))))

      ;; the direct-invocation path: a client naming a command rather than tapping a menu item.
      ;; It exists so the refusal is testable, and it goes through RUN-COMMAND like every other
      ;; surface — rule 6, enforcement at invocation.  A client that was never offered `revoke`
      ;; can send it, and gets nothing.
      ((string= type "cmd")
       (let* ((name (json-get msg "name"))
              (key (json-get msg "key"))
              (p (and key (%visible-by-key c key)))
              ;; resolved against everything DECLARED for that presentation's type, with
              ;; :authorized-only NIL — so a client can name a command it was never offered, which
              ;; is the whole point of the test this path exists for
              (cmd (and p name (find name (applicable-commands (p-type p) :authorized-only nil)
                                     :key (lambda (x) (symbol-name (cmd-name x)))
                                     :test #'string-equal))))
         (cond
           ((or (null cmd) (null p)) (values :refused (list name key)))
           (t (run-command c cmd (p-object p) :confirmed (eq t (json-get msg "confirmed")))
              (values :invoked (consumer-last-result c))))))

      (t (values :ignored type)))))
