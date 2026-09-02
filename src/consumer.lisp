;;;; consumer.lisp — the per-consumer half of DESIGN.md rule 8, and the seam a second encoding
;;;; subclasses.
;;;;
;;;; A CONSUMER is whatever owns an encoding target.  For a browser that is a person, for a token
;;;; stream a session, for glass a *window* — glass seats deliberately share window content, so two
;;;; seats at one window are one warp consumer.  What the consumer owns is everything that is a
;;;; property of the one looking: PRESENT, layout, diff and encode, and therefore view, scroll,
;;;; viewport, extents, stream, budget, view state, invoker and counters.
;;;;
;;;; THE CLASS HERE HAS NO ENCODING TARGET, AND THAT IS THE POINT.  It has no framebuffer, no
;;;; pixels, and no way to reach any: LAY-OUT, APPLY-DELTAS and MENU-PRESENTATIONS are generic on
;;;; it, and a new encoding is three methods rather than a second architecture.  warp-glass supplies
;;;; the framebuffer encoding; a DOM consumer over a data channel supplies its own and needs nothing
;;;; from glass to do it.
;;;;
;;;; The correctness argument for the split is not economy.  STREAM is the consumer's MEMORY of what
;;;; it has already been told.  Share one between two consumers and a change is emitted once, landed
;;;; on whichever ticked first, and the other is never told — it is not stale, it is WRONG, and it
;;;; looks correct because the delta was emitted exactly once as designed.  So a consumer allocates
;;;; its own stream in its own INITFORM and there is no argument by which it could receive somebody
;;;; else's: a late joiner's memory starts empty and is filled by an ordinary budgeted pass, which is
;;;; what "connected late" means in rule 4.

(in-package #:warp)

;;; ---- the encoding seam ------------------------------------------------------
;;; Declared before the class, because a CONSUMER is DEFINED as something that can land deltas: the
;;; class checks at construction that the encoding exists (see below).

(defgeneric apply-deltas (consumer deltas)
  (:documentation "Land DELTAS in whatever this consumer's encoding is.  Macroblocks for a retina,
DOM for a browser, tokens for a model — the delta stream above it does not change.

Core deliberately supplies NO default method.  A consumer with no encoding target is not a consumer
that fails late, when it first happens to be owed a delta; it is a type that cannot be constructed,
which is what the check in INITIALIZE-INSTANCE below enforces."))

(defgeneric lay-out (consumer objects as-of)
  (:documentation "Project OBJECTS for CONSUMER and give the visible ones extents.  Returns this
consumer's presentations, stamped with the AS-OF of the read they came from."))

(defgeneric menu-presentations (consumer)
  (:documentation "This consumer's open menu, laid out in its own encoding.  Menus are presentations
too (rule 7), so this is layout, not a special path — the default is in menu.lisp."))

;;; ---- the consumer ------------------------------------------------------------

(defclass consumer ()
  ((projection :initarg :projection :accessor consumer-projection)
   (name :initarg :name :initform nil :accessor consumer-name)
   ;; how THIS consumer sees: present dispatches on VIEW, and layout is its own
   (view :initarg :view :initform nil :accessor consumer-view
         :documentation "PRESENT dispatches on it.  It lives here, not on the projection, because
the fingerprints are this consumer's own — derived under its view, at its scroll, in its viewport.")
   (scroll-y :initarg :scroll-y :initform 0 :accessor consumer-scroll-y)
   ;; The viewport is ORDINARY SLOTS, not a question asked of an encoding target.  It used to
   ;; default off the framebuffer, which quietly made "how big is the view" a pixel question; a DOM
   ;; consumer is sized by a browser and a token consumer by a context window.  An encoding that has
   ;; a better answer specialises VIEWPORT-WIDTH / VIEWPORT-HEIGHT.
   (width :initarg :width :initform nil :accessor consumer-width)
   (viewport-h :initarg :viewport-h :initform nil :accessor consumer-viewport-h)
   (row-height :initarg :row-height :initform 32 :accessor consumer-row-height)
   ;; what this consumer has been told, and what its link can carry
   (stream :initform (make-delta-stream) :accessor consumer-stream)
   (budget :initarg :budget :initform 400 :accessor consumer-budget)
   (epoch :initform 0 :accessor consumer-epoch
          :documentation "The projection epoch this consumer has already been handed.")
   ;; who is asking
   (invoker :initarg :invoker :initform :allowlist :accessor consumer-invoker)
   ;; rule 7 view state, per consumer per view
   (selected :initform nil :accessor consumer-selected)
   (menu :initform nil :accessor consumer-menu)
   (visible :initform '() :accessor consumer-visible
            :documentation "The set this consumer was last shown — its own rows plus its own menu.
An encoding resolves an incoming gesture against it: glass hit-tests it by pixel, a browser would
look a key up in it.")
   (last-result :initform nil :accessor consumer-last-result)
   ;; this consumer's numbers, not the projection's
   (landed :initform 0 :accessor consumer-landed
           :documentation "Deltas this consumer's encoding actually landed.  Not 'painted': what
landing means is the encoding's business, and only one encoding paints.")
   (emitted :initform 0 :accessor consumer-emitted)
   (passes :initform 0 :accessor consumer-passes)
   (deferred :initform 0 :accessor consumer-deferred)
   (lock :initform (bt:make-lock "warp-consumer") :reader consumer-lock)
   (stop :initform nil :accessor consumer-stop))
  (:documentation "One consumer: whatever owns an encoding target.  ABSTRACT — see APPLY-DELTAS."))

(defmethod initialize-instance :after ((c consumer) &key)
  "A consumer is defined by having somewhere to put deltas, so refuse to make one that has not said
where.  The alternative — construct it and signal NO-APPLICABLE-METHOD the first time it is owed
anything — makes a missing encoding look like an intermittent bug in the reconciler, and it is
reachable only on the pass where a budget happens to let something through."
  ;; COMPUTE-APPLICABLE-METHODS is ANSI, not MOP: SB-MOP merely re-exports CL's symbol, and the two
  ;; are EQ.  Spelling it `sb-mop:' cost nothing here and made the file unreadable on a host with no
  ;; SB-MOP package — a READ error, which is before any runtime test could soften it.
  (unless (compute-applicable-methods #'apply-deltas (list c '()))
    (error "warp: ~s has no APPLY-DELTAS method, so it has no encoding target and cannot be a~@
            consumer.  Specialise APPLY-DELTAS (and usually LAY-OUT) on it, or use~@
            RECORDING-CONSUMER — see DESIGN.md rule 8."
           (class-name (class-of c)))))

(defun consumer-rows-fn (c) (projection-rows-fn (consumer-projection c)))

;;; ---- the viewport is the consumer's, in its own units ------------------------

(defgeneric viewport-width (consumer)
  (:documentation "The width this consumer lays out into.")
  (:method ((c consumer)) (or (consumer-width c) 640)))

(defgeneric viewport-height (consumer)
  (:documentation "The height this consumer lays out into.")
  (:method ((c consumer)) (or (consumer-viewport-h c) 480)))

;;; ---- seating and unseating ---------------------------------------------------

(defun attach (projection &rest initargs &key (class 'recording-consumer) &allow-other-keys)
  "Seat a consumer at PROJECTION.  CLASS is the encoding — the thing that owns where deltas land —
and it defaults to RECORDING-CONSUMER, which keeps them.  Remaining INITARGS go to the instance.

Its stream starts EMPTY — it cannot inherit anyone else's high-water mark, which is the late-joiner
bug — so its first pass announces the whole working set, chunked and budgeted by exactly the path
every other pass uses.

VIEW, SCROLL-Y and the viewport are arguments HERE and not on the projection: two seats at one
result-set may look at it through different views, at different offsets, in different-sized
viewports, and none of that is a property of the data."
  (let* ((rest (loop for (k v) on initargs by #'cddr
                     unless (eq k :class) append (list k v)))
         (c (apply #'make-instance class :projection projection rest)))
    (bt:with-lock-held ((projection-lock projection))
      (setf (projection-consumers projection)
            (append (projection-consumers projection) (list c))))
    c))

(defun detach (c)
  (let ((p (consumer-projection c)))
    (bt:with-lock-held ((projection-lock p))
      (setf (projection-consumers p) (remove c (projection-consumers p))))
    (setf (consumer-stop c) t)
    c))

;;; ---- pulling: one query, N consumers -----------------------------------------

(defun pull (projection consumer)
  "The shared result-set — objects, and the AS-OF of the read that produced them — at an epoch
CONSUMER has not been handed yet.

The query runs only when the caller needs a newer epoch than the one it already holds.  One consumer
therefore queries once per tick — the behaviour before rule 8, unchanged — and N consumers ticking in
a round cost ONE query between them, because the first to arrive advances the epoch and the rest read
the cache.  A consumer ticking faster than its neighbours drives the refresh rate and is not held
back by them.

The important negative: pulling is IDEMPOTENT per consumer within an epoch, so this is a cached read
and not a destructive one.  Two clocks pulling one mixer source take alternate frames and both
listeners hear half of it; that is the same hazard, and it is the one rule 8 exists to prevent."
  (bt:with-lock-held ((projection-lock projection))
    (when (eql (consumer-epoch consumer) (projection-epoch projection))
      (setf (projection-objects projection) (funcall (projection-rows-fn projection))
            ;; AS-OF is a property of the READ, stamped once here.  Quantized like every other clock
            ;; the protocol reads (rule: time is an input to queries, and it ticks).
            (projection-as-of projection) (now-tick))
      (incf (projection-epoch projection))
      (incf (projection-queries projection)))
    (setf (consumer-epoch consumer) (projection-epoch projection))
    (values (projection-objects projection) (projection-as-of projection))))

;;; ---- layout is the consumer's ------------------------------------------------
;;; PRESENT and LAYOUT run per consumer, over shared objects, so scroll offset, viewport size and
;;; view are this seat's and nobody else's.  It is also the extension point for a second encoding: a
;;; DOM consumer specialises LAY-OUT to produce presentations the browser will place, a token
;;; consumer to produce presentations with no extents at all (the reconciler already tolerates a NIL
;;; extent — it costs one unit and can never be a :moved), and both keep every other line of the
;;; protocol.

(defmethod lay-out ((c consumer) objects as-of)
  "The default layout: a vertical list, clipped to this consumer's own viewport at its own scroll
offset, grid-snapped (rule 3).

This is also where rule 7's view state lands.  The consumer BUILT these presentations, so it simply
annotates its own selected row — there is nothing shared left to copy on write.  P-STATE stays a
separate slot from FINGERPRINT because they are different kinds of thing and an encoding needs to
tell them apart: the fingerprint is PRESENT's output, and P-STATE is what this seat adds to it."
  (let ((ps (layout-list objects (projection-type-fn (consumer-projection c)) (consumer-view c)
                         :width (viewport-width c)
                         :viewport-h (viewport-height c)
                         :row-height (consumer-row-height c)
                         :scroll-y (consumer-scroll-y c)
                         :as-of as-of))
        (sel (consumer-selected c)))
    (when sel
      (dolist (p ps)
        (when (equal sel (p-key p)) (setf (p-state p) (list :selected t)))))
    ps))

;;; ---- scroll is per consumer, which is the point ------------------------------
;;; And it is in the consumer's OWN UNITS.  A framebuffer scrolls in pixels; a browser reports "I
;;; can show 12 rows and I am 3 rows down" and scrolls in rows, because a DOM list has no pixel
;;; offset the server could know.  SCROLL-TO clamps against CONTENT-HEIGHT and VIEWPORT-HEIGHT, so
;;; making CONTENT-HEIGHT generic is the whole of what an encoding needs to change the axis — rule 7
;;; keeps ONE scroll slot and the clamp keeps working.

(defgeneric content-height (consumer)
  (:documentation "How far this consumer could scroll, in whatever unit its scroll offset is in.")
  (:method ((c consumer))
    (list-content-height (projection-objects (consumer-projection c))
                         :row-height (consumer-row-height c))))

(defun scroll-to (c y)
  "Set this consumer's scroll offset, clamped to its own content and its own viewport.  Its
neighbours over the same projection are not moved: that is the capability the fused boundary could
not express."
  (setf (consumer-scroll-y c)
        (max 0 (min y (max 0 (- (content-height c) (viewport-height c)))))))

(defun scroll-by (c dy) (scroll-to c (+ (consumer-scroll-y c) dy)))

;;; ---- a pass -------------------------------------------------------------------

(defun %pass (c emitter)
  "One pass for one consumer: take the shared OBJECTS, lay them out for this consumer (its view, its
scroll, its viewport, its selection), add this consumer's menu, advance this consumer's stream under
this consumer's budget, and land only what that emitted.  EMITTER is EMIT or, for a resync,
SNAPSHOT — the two differ only in whether the delivered state is forgotten first and the generation
bumped, which is why a resync needs no path of its own.

The layout is re-derived every pass rather than cached.  A cache could only ever hit when the query
did NOT re-run, and PULL re-runs it whenever this consumer needs a newer epoch — which is every
tick — so it would buy nothing and cost the one thing that must not be lost: an object MUTATED IN
PLACE keeps its key and its identity, and it is re-presenting it that turns the mutation into a
changed fingerprint and therefore a :changed delta."
  (multiple-value-bind (objects as-of) (pull (consumer-projection c) c)
    (let ((rows (append (lay-out c objects as-of) (menu-presentations c))))
      (multiple-value-bind (deltas deferred)
          ;; the budget is THIS consumer's, and so is the unit it is spent in: DELTA-COST is
          ;; dispatched on C, so a framebuffer spends macroblocks and a browser spends bytes
          ;; without either of them knowing the other exists.
          (funcall emitter (consumer-stream c) rows
                   :budget (consumer-budget c) :consumer c)
        (incf (consumer-passes c))
        (incf (consumer-emitted c) (length deltas))
        (setf (consumer-deferred c) deferred
              (consumer-visible c) rows)
        (when deltas (apply-deltas c deltas))
        deltas))))

(defun tick (c)
  "One pass: take the current result-set, emit what is owed under budget, land only that."
  (bt:with-lock-held ((consumer-lock c)) (%pass c #'emit)))

(defun resync (c)
  "Rule 4: connected late, fell too far behind, lost state.  Forget what this consumer was believed
to hold and re-announce the whole working set at a new generation, chunked by the same budget.  Only
this consumer's memory is affected; its neighbours are not told anything."
  (bt:with-lock-held ((consumer-lock c)) (%pass c #'snapshot)))

(defun tick-all (projection)
  "Every seat, one round.  The query runs once; each consumer diffs it against its own stream."
  (mapcar #'tick (projection-consumers projection)))

;;; ---- the identity encoding ----------------------------------------------------
;;; The deltas ARE the semantic wire format; a transport encoding is a serialization of them plus
;;; somewhere to put the bytes.  RECORDING-CONSUMER is that shape with the serialization left out:
;;; it keeps what it was handed until something takes it.  It is what a consumer over a data channel
;;; looks like before it picks a framing, and it is what makes the core testable — and usable — with
;;; no framebuffer anywhere in the image.

(defclass recording-consumer (consumer)
  ((record :initform '() :accessor consumer-record
           :documentation "Deltas landed since the last TAKE-RECORD, in the order they arrived."))
  (:documentation "A consumer whose encoding target is a list: it keeps its deltas."))

(defmethod apply-deltas ((c recording-consumer) deltas)
  (setf (consumer-record c) (nconc (consumer-record c) (copy-list deltas)))
  (incf (consumer-landed c) (length deltas)))

(defun take-record (c)
  "Hand over everything this consumer has been landed and forget it — the flush a transport does."
  (prog1 (consumer-record c) (setf (consumer-record c) '())))
