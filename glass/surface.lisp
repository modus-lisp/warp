;;;; glass/surface.lisp — warp's glass surface: deltas become framebuffer writes.
;;;;
;;;; This is the encoding half.  The delta stream decides WHAT travels; this decides how it lands in
;;;; pixels.  The important discipline is that a pass paints ONLY the extents the stream emitted —
;;;; never the whole view — because glass discovers damage by diffing tiles against its snapshot and
;;;; ships the dirty ones.  So glass independently CHECKS warp: if the reconciler is right, the tiles
;;;; glass finds dirty are the extents warp emitted, and nothing else.
;;;;
;;;; There are two objects here, and DESIGN.md rule 8 is the whole reason: a PROJECTION is the thing
;;;; being looked at, a CONSUMER is one of the ones looking.  See the section comment above them.
;;;;
;;;; Input is the interim mapping.  DESIGN.md rule 5 wants semantic gestures recognized on the phone
;;;; and carried on the wire; today the client flattens them into RFB pointer events, so until that
;;;; protocol change lands: button 1 = tap, button 3 = hold (the menu).  Recognition still happens at
;;;; the edge — we are just receiving it in a lossy encoding.

(in-package #:warp-glass)

(defparameter +bg+     #x0c0e12)
(defparameter +row-bg+ #x161a20)
(defparameter +row-sel+ #x26303c)
(defparameter +fg+     #xdce4ec)
(defparameter +dim+    #x8a949c)
(defparameter +ok+     #x5abe82)
(defparameter +warn+   #xfabe3c)
(defparameter +bad+    #xf04646)

(defun trend-colour (trend)
  (case trend (:bad +bad+) (:warn +warn+) (t +ok+)))

;;; ---- text on a baseline -----------------------------------------------------
;;; GLASS:FB-TEXT positions a string by its TOP-LEFT, so a SIZE-px line drawn at Y occupies
;;; Y..Y+SIZE.  Two consequences bit the monitor, and the second is not cosmetic:
;;;
;;;   * two different sizes positioned by their tops do NOT share a baseline, which reads as the
;;;     smaller label floating above the value it labels;
;;;   * a line whose box is taller than the room left in the row OVERFLOWS INTO THE NEIGHBOUR — and
;;;     that is warp painting outside the extent it declared.  The reconciler told the consumer which
;;;     rectangles changed; glass then finds dirty tiles outside every one of them.  The invariant
;;;     this file's header claims (glass independently checks warp) is exactly what breaks.  The
;;;     visible symptom is the descender vanishing when the row below is next painted over it.
;;;
;;; So: position by baseline, and derive the baseline from the row.

(defun text-ascent (size &optional (font (glass:default-font)))
  "Pixels from the top of a SIZE-px text box down to its baseline."
  (round (* (scribe:font-ascent font) size) (scribe:font-units-per-em font)))

(defun fb-text-baseline (fb x baseline string &key (size 13) (color +fg+))
  "Draw STRING with its BASELINE at that y.  Use this, not FB-TEXT, wherever text shares a line."
  (glass:fb-text fb x (- baseline (text-ascent size)) string :size size :color color))

(defun row-baseline (y h size)
  "A baseline that vertically centres a SIZE-px line in the row of height H starting at Y.
Centres the em box, which keeps the whole line inside the row — the point being that the row, not
the glyph, owns the space."
  (+ y (floor (- h size) 2) (text-ascent size)))

;;; ---- painting --------------------------------------------------------------
;;; PAINT is the counterpart of PRESENT: present decides what a thing says, paint decides how it
;;; looks.  Keeping them apart is what lets the content double as the fingerprint.

(defgeneric paint (fb presentation view)
  (:documentation "Draw PRESENTATION into FB.  Called only for extents the delta stream emitted."))

(defmethod paint (fb p view)
  "Default: the content lines, small and plain — the visual counterpart of the MOP slot walk."
  (declare (ignorable view))
  (let* ((e (warp:p-extent p)) (x (warp::extent-x e)) (y (warp::extent-y e))
         (w (warp::extent-w e)) (h (warp::extent-h e)))
    (glass:fb-rect fb x y w h +row-bg+)
    ;; stop when the NEXT line would not fit entirely, so the default never paints past the extent
    (loop for line in (warp:p-fingerprint p)
          for i from 0
          for top = (+ 2 (* i 12))
          while (<= (+ top 11) h)
          do (fb-text-baseline fb (+ x 8) (+ y top (text-ascent 11)) (princ-to-string line)
                               :size 11 :color +fg+))))

(defun clear-extent (fb e)
  (glass:fb-rect fb (warp::extent-x e) (warp::extent-y e)
                 (warp::extent-w e) (warp::extent-h e) +bg+))


;;; ---- the projection, and the consumers of it --------------------------------
;;; DESIGN.md rule 8.  One field of the old SURFACE was the thing being looked at; every other one
;;; was a property of the one looking, and with a single consumer nothing forced the distinction.
;;;
;;;   PROJECTION   the QUERY, and the domain objects it returns.  Pulled once per epoch, shared.
;;;   CONSUMER     one seat: present, layout, diff, encode — and therefore view, scroll, viewport,
;;;                extents, stream, budget, framebuffer, view state, invoker, counters.
;;;
;;; The boundary sits BELOW layout, and that is the second half of rule 8.  ROWS-FN used to return
;;; laid-out presentations, which meant sharing a projection necessarily shared scroll AND window
;;; size — a fusion that contradicted "views subscribe to result-sets" and present.lisp's own header.
;;; The forcing argument is the one that motivates the whole rule: ENCODINGS PER CONSUMER.  A DOM
;;; consumer lays out in a browser with its own viewport; a token consumer has no extents at all.
;;; Neither can share a macroblock consumer's laid-out rows, so per-consumer layout is not a
;;; refinement of "encodings per consumer" — it is what that phrase MEANS once there is a second
;;; encoding.  LAY-OUT and APPLY-DELTAS are therefore generic on the consumer: a new encoding is a
;;; subclass with two methods, not a second architecture.
;;;
;;; The efficiency argument (N consumers should not run N copies of one query) is the weak one.  The
;;; correctness argument is that STREAM is the consumer's MEMORY of what it has already been told.
;;; Shared between two consumers, a change is emitted once, painted to whichever ticked first, and
;;; the other is never told — not stale, WRONG, and it looks correct because the delta was emitted
;;; exactly once as designed.  So a consumer allocates its own stream in its own INITFORM and there
;;; is no argument by which it could receive somebody else's: a late joiner's memory starts empty
;;; and is filled by an ordinary budgeted pass, which is what "connected late" means in rule 4.

(defclass projection ()
  ((rows-fn :initarg :rows-fn :accessor projection-rows-fn
            :documentation "() -> the current result-set, as DOMAIN OBJECTS.  Not presentations:
present, layout and extents are the consumer's.")
   (type-fn :initarg :type-fn :accessor projection-type-fn
            :initform (lambda (o) (class-name (class-of o)))
            :documentation "object -> presentation type.  What a row IS belongs to the result-set,
not to the seat: a DOM consumer and a token consumer must agree that a row is a STAT even though
they agree on nothing about how it looks.  The default is the object's class name, which is the same
zero-UI-code default PRESENT itself has.")
   (objects :initform '() :accessor projection-objects
            :documentation "The cached result-set — objects, carrying no extents at all.")
   (as-of :initform nil :accessor projection-as-of
          :documentation "When the cached result-set was READ.  Staleness is a property of the read,
so it is stamped here once and copied onto each presentation at layout time; a consumer laying out
an epoch-old cache reports the age of the DATA, not of its own pass.")
   (epoch :initform 0 :accessor projection-epoch)
   (queries :initform 0 :accessor projection-queries
            :documentation "How many times ROWS-FN has actually run.  The measurement rule 8 is
about: with N consumers ticking in a round, this advances once.")
   (consumers :initform '() :accessor projection-consumers)
   (lock :initform (bt:make-lock "warp-projection") :reader projection-lock))
  (:documentation "The shared half: the query, and the objects it returns."))

(defun make-projection (rows-fn &key (type-fn nil type-fn-p))
  (if type-fn-p
      (make-instance 'projection :rows-fn rows-fn :type-fn type-fn)
      (make-instance 'projection :rows-fn rows-fn)))

(defclass consumer ()
  ((projection :initarg :projection :accessor consumer-projection :accessor sf-projection)
   ;; where it lands, and how it is reached
   (fb :initarg :fb :initform nil :accessor consumer-fb :accessor sf-fb)
   (port :initarg :port :initform nil :accessor consumer-port :accessor sf-port)
   (name :initarg :name :initform nil :accessor consumer-name :accessor sf-name)
   ;; how THIS consumer sees: present dispatches on VIEW, and layout is its own
   (view :initarg :view :initform nil :accessor consumer-view :accessor sf-view
         :documentation "PRESENT dispatches on it.  It lives here, not on the projection, because
the fingerprints are this consumer's own — derived under its view, at its scroll, in its viewport.")
   (scroll-y :initarg :scroll-y :initform 0 :accessor consumer-scroll-y :accessor sf-scroll-y)
   (width :initarg :width :initform nil :accessor consumer-width)
   (viewport-h :initarg :viewport-h :initform nil :accessor consumer-viewport-h)
   (row-height :initarg :row-height :initform 32 :accessor consumer-row-height)
   ;; what this consumer has been told, and what its link can carry
   (stream :initform (warp:make-delta-stream) :accessor consumer-stream :accessor sf-stream)
   (budget :initarg :budget :initform 400 :accessor consumer-budget :accessor sf-budget)
   (epoch :initform 0 :accessor consumer-epoch
          :documentation "The projection epoch this consumer has already been handed.")
   ;; who is asking
   (invoker :initarg :invoker :initform :allowlist :accessor consumer-invoker :accessor sf-invoker)
   ;; rule 7 view state, per consumer per view
   (selected :initform nil :accessor consumer-selected :accessor sf-selected)
   (menu :initform nil :accessor consumer-menu :accessor sf-menu)
   (visible :initform '() :accessor consumer-visible :accessor sf-visible
            :documentation "The set this consumer was last shown — its own rows plus its own menu —
kept for hit-testing.")
   (last-result :initform nil :accessor consumer-last-result :accessor sf-last-result)
   ;; this consumer's numbers, not the projection's
   (painted :initform 0 :accessor consumer-painted :accessor sf-painted)
   (emitted :initform 0 :accessor consumer-emitted :accessor sf-emitted)
   (passes :initform 0 :accessor consumer-passes :accessor sf-passes)
   (deferred :initform 0 :accessor consumer-deferred :accessor sf-deferred)
   (lock :initform (bt:make-lock "warp-consumer") :reader consumer-lock :reader sf-lock)
   (stop :initform nil :accessor consumer-stop :accessor sf-stop))
  (:documentation "One seat: a glass seat and a warp consumer are the same object."))

;;; The SF- accessors are the compatibility surface, so every existing call site keeps working and
;;; the single-consumer path is the same code path rather than an equivalent one.  ROWS-FN is the
;;; projection's; everything else is the seat's.

(deftype surface () 'consumer)
(defun consumer-rows-fn (c) (projection-rows-fn (consumer-projection c)))
(defun sf-rows-fn (c) (consumer-rows-fn c))

(defun viewport-width (c)
  "The width this consumer lays out into — its own, defaulting to its framebuffer's."
  (or (consumer-width c) (and (consumer-fb c) (glass:fb-width (consumer-fb c))) 640))

(defun viewport-height (c)
  (or (consumer-viewport-h c) (and (consumer-fb c) (glass:fb-height (consumer-fb c))) 480))

(defun attach (projection &key fb view (budget 400) (invoker :allowlist) name port
                               (scroll-y 0) width viewport-h (row-height 32))
  "Seat a consumer at PROJECTION.  Its stream starts EMPTY — it cannot inherit anyone else's
high-water mark, which is the late-joiner bug — so its first pass announces the whole working set,
chunked and budgeted by exactly the path every other pass uses.

VIEW, SCROLL-Y and the viewport are arguments HERE and not on the projection: two seats at one
result-set may look at it through different views, at different offsets, in different-sized windows,
and none of that is a property of the data."
  (let ((c (make-instance 'consumer :projection projection :fb fb :budget budget :view view
                                    :invoker invoker :name name :port port
                                    :scroll-y scroll-y :width width :viewport-h viewport-h
                                    :row-height row-height)))
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
            (projection-as-of projection) (warp:now-tick))
      (incf (projection-epoch projection))
      (incf (projection-queries projection)))
    (setf (consumer-epoch consumer) (projection-epoch projection))
    (values (projection-objects projection) (projection-as-of projection))))

;;; ---- layout is the consumer's ----------------------------------------------
;;; The second half of rule 8.  PRESENT and LAYOUT run per consumer, over shared objects, so scroll
;;; offset, viewport size and view are this seat's and nobody else's.  It is also the extension
;;; point for a second encoding: a DOM consumer specialises LAY-OUT to produce extent-less
;;; presentations the browser will place, a token consumer to produce presentations with no extents
;;; at all (the reconciler already tolerates a NIL extent — it costs one unit and can never be a
;;; :moved), and both keep every other line of the protocol.

(defgeneric lay-out (consumer objects as-of)
  (:documentation "Project OBJECTS for CONSUMER and give the visible ones extents.  Returns this
consumer's presentations, stamped with the AS-OF of the read they came from."))

(defmethod lay-out ((c consumer) objects as-of)
  "The macroblock encoding's layout: a vertical list, clipped to this consumer's own viewport at its
own scroll offset, grid-snapped (rule 3).

This is also where rule 7's view state lands.  The consumer BUILT these presentations, so it simply
annotates its own selected row — there is nothing shared left to copy on write.  P-STATE stays a
separate slot from FINGERPRINT because they are different kinds of thing and an encoding needs to
tell them apart: the fingerprint is PRESENT's output, and P-STATE is what this seat adds to it."
  (let ((ps (warp:layout-list objects (projection-type-fn (consumer-projection c)) (consumer-view c)
                              :width (viewport-width c)
                              :viewport-h (viewport-height c)
                              :row-height (consumer-row-height c)
                              :scroll-y (consumer-scroll-y c)
                              :as-of as-of))
        (sel (consumer-selected c)))
    (when sel
      (dolist (p ps)
        (when (equal sel (warp:p-key p)) (setf (warp:p-state p) (list :selected t)))))
    ps))

;;; ---- scroll is per consumer, which is the point ----------------------------

(defun content-height (c)
  (warp:list-content-height (projection-objects (consumer-projection c))
                            :row-height (consumer-row-height c)))

(defun scroll-to (c y)
  "Set this consumer's scroll offset, clamped to its own content and its own viewport.  Its
neighbours over the same projection are not moved: that is the capability the fused boundary could
not express."
  (setf (consumer-scroll-y c)
        (max 0 (min y (max 0 (- (content-height c) (viewport-height c)))))))

(defun scroll-by (c dy) (scroll-to c (+ (consumer-scroll-y c) dy)))

;;; ---- menus are presentations too --------------------------------------------
;;; Rule 7 says view state is presentations, keyed like everything else.  A menu is exactly that: a
;;; transient overlay whose rows are commands.  Which means it needs no special painting path, no
;;; separate damage accounting, and no extra code in the reconciler — opening a menu emits :appeared
;;; for its items, closing emits :gone, and the damage is bounded to the menu itself.

(defstruct (menu-item (:conc-name mi-))
  kind        ; :command | :confirm | :cancel
  command     ; the COMMAND object (nil for :cancel)
  target)     ; the domain object it would act on

(warp:define-presentation-key menu-item (m)
  (format nil "menu:~(~a~):~a" (mi-kind m)
          (if (mi-command m) (warp:cmd-name (mi-command m)) "cancel")))

(defmethod warp:present ((m menu-item) (type (eql 'menu-item)) view)
  (declare (ignorable view))
  (let ((c (mi-command m)))
    (ecase (mi-kind m)
      (:command (list (warp:cmd-label c) (warp:cmd-cost c)
                      (if (warp:cmd-destructive c) :destructive :safe)))
      (:confirm (list (format nil "really ~a?" (warp:cmd-label c)) :confirm :destructive))
      (:cancel  (list "cancel" nil :safe)))))

(defparameter +menu-w+ 224)
(defparameter +menu-row+ 32)

;;; A menu belongs to the CONSUMER, not the projection: it is the hold gesture of one particular
;;; finger, laid out over one particular framebuffer, listing what one particular invoker may run.
;;; Two people looking at the same list can have two menus open on two different rows.

(defun menu-presentations (c)
  "Lay this consumer's open menu out beneath its target row, as ordinary presentations."
  (let ((m (consumer-menu c)))
    (when m
      (destructuring-bind (&key target items) m
        (let* ((te (warp:p-extent target))
               (x (min (warp::extent-x te)
                       (max 0 (- (glass:fb-width (consumer-fb c)) +menu-w+))))
               (y0 (+ (warp::extent-y te) (warp::extent-h te))))
          (loop for it in items
                for i from 0
                for y = (+ y0 (* i +menu-row+))
                collect (warp:make-presentation
                         :key (warp:presentation-key 'menu-item it)
                         :type 'menu-item :object it
                         :extent (warp:snap-extent x y +menu-w+ +menu-row+)
                         :fingerprint (warp:present it 'menu-item (consumer-view c))
                         :as-of (warp:now-tick))))))))

(defun open-menu (c target commands)
  (setf (consumer-menu c)
        (list :target target
              :items (append (mapcar (lambda (cmd) (make-menu-item :kind :command :command cmd
                                                                   :target (warp:p-object target)))
                                     commands)
                             (list (make-menu-item :kind :cancel))))))

(defun confirm-menu (c target command)
  "Replace the menu with a confirmation.  Rule 6: irreversible commands do not run on one tap."
  (setf (consumer-menu c)
        (list :target target
              :items (list (make-menu-item :kind :confirm :command command
                                           :target (warp:p-object target))
                           (make-menu-item :kind :cancel)))))

(defun close-menu (c) (setf (consumer-menu c) nil))

;;; ---- a pass ----------------------------------------------------------------

(defun hit (c x y)
  "The presentation under (X,Y), or NIL.  Reverse order so the topmost wins."
  (find-if (lambda (p)
             (let ((e (warp:p-extent p)))
               (and e (<= (warp::extent-x e) x (+ (warp::extent-x e) (warp::extent-w e) -1))
                    (<= (warp::extent-y e) y (+ (warp::extent-y e) (warp::extent-h e) -1)))))
           (reverse (consumer-visible c))))

(defgeneric apply-deltas (consumer deltas)
  (:documentation "Land DELTAS in whatever this consumer's encoding is.  Macroblocks for a retina,
DOM for a browser, tokens for a model — the delta stream above it does not change."))

(defmethod apply-deltas ((c consumer) deltas)
  "The framebuffer encoding: paint exactly what the stream emitted, and nothing else."
  (let ((fb (consumer-fb c)) (view (consumer-view c)))
    (glass:with-fb-locked (fb)
      (dolist (d deltas)
        (ecase (warp:delta-kind d)
          ((:appeared :changed)
           (paint fb (warp:delta-presentation d) view)
           (incf (consumer-painted c)))
          (:moved
           ;; No blit yet: repaint at the new extent and clear where it came from.  The :moved KIND
           ;; is still the right thing to carry — it is what a CopyRect or a motion vector will use
           ;; once the encoder can see a translation (DESIGN.md rule 2).
           (let* ((p (warp:delta-presentation d)) (e (warp:p-extent p)))
             (clear-extent fb (list (- (warp::extent-x e) (warp:delta-dx d))
                                    (- (warp::extent-y e) (warp:delta-dy d))
                                    (warp::extent-w e) (warp::extent-h e)))
             (paint fb p view)
             (incf (consumer-painted c))))
          (:gone
           (clear-extent fb (warp:delta-extent d))
           (incf (consumer-painted c))))))))

(defun %pass (c emitter)
  "One pass for one consumer: take the shared OBJECTS, lay them out for this consumer (its view, its
scroll, its viewport, its selection), add this consumer's menu, advance this consumer's stream under
this consumer's budget, and land only what that emitted.  EMITTER is WARP:EMIT or, for a resync,
WARP:SNAPSHOT — the two differ only in whether the delivered state is forgotten first and the
generation bumped, which is why a resync needs no path of its own.

The layout is re-derived every pass rather than cached.  A cache could only ever hit when the query
did NOT re-run, and PULL re-runs it whenever this consumer needs a newer epoch — which is every
tick — so it would buy nothing and cost the one thing that must not be lost: an object MUTATED IN
PLACE keeps its key and its identity, and it is re-presenting it that turns the mutation into a
changed fingerprint and therefore a :changed delta."
  (multiple-value-bind (objects as-of) (pull (consumer-projection c) c)
    (let ((rows (append (lay-out c objects as-of) (menu-presentations c))))
      (multiple-value-bind (deltas deferred)
          (funcall emitter (consumer-stream c) rows :budget (consumer-budget c))
        (incf (consumer-passes c))
        (incf (consumer-emitted c) (length deltas))
        (setf (consumer-deferred c) deferred
              (consumer-visible c) rows)
        (when deltas (apply-deltas c deltas))
        deltas))))

(defun tick (c)
  "One pass: take the current result-set, emit what is owed under budget, paint only that."
  (bt:with-lock-held ((consumer-lock c)) (%pass c #'warp:emit)))

(defun resync (c)
  "Rule 4: connected late, fell too far behind, lost state.  Forget what this consumer was believed
to hold and re-announce the whole working set at a new generation, chunked by the same budget.  Only
this consumer's memory is affected; its neighbours are not told anything."
  (bt:with-lock-held ((consumer-lock c)) (%pass c #'warp:snapshot)))

(defun tick-all (projection)
  "Every seat, one round.  The query runs once; each consumer diffs it against its own stream."
  (mapcar #'tick (projection-consumers projection)))

(defun on-pointer (c mask x y)
  "Interim gesture mapping (see the file header): button 1 = tap, button 3 = hold, wheel = the
two-finger pan of rule 5 arriving in the client's lossy encoding.
Everything this touches — the scroll offset, the menu, the selection, the invoker the gesture is
resolved against — is this consumer's.  Another seat over the same projection is not disturbed by
any of it, which is what the fused boundary could not do: scrolling one seat moved both."
  (when (or (logtest mask 8) (logtest mask 16))                ; buttons 4/5: wheel up/down
    (scroll-by c (if (logtest mask 8) (- (consumer-row-height c)) (consumer-row-height c)))
    (return-from on-pointer t))
  (let* ((gesture (cond ((logtest mask 1) :tap) ((logtest mask 4) :hold) (t nil)))
         (p (and gesture (hit c x y))))
    (when gesture
      (cond
        ;; nothing under the finger: a tap dismisses any open menu
        ((null p) (when (eq gesture :tap) (close-menu c)))
        ;; a tap on a menu row
        ((eq (warp:p-type p) 'menu-item)
         (when (eq gesture :tap)
           (let ((it (warp:p-object p)))
             (ecase (mi-kind it)
               (:cancel (close-menu c))
               (:command
                (let ((cmd (mi-command it)))
                  ;; destructive commands get a confirmation step rather than running
                  (if (warp:cmd-confirm cmd)
                      (confirm-menu c (getf (consumer-menu c) :target) cmd)
                      (progn (run-command c cmd (mi-target it)) (close-menu c)))))
               (:confirm
                (run-command c (mi-command it) (mi-target it) :confirmed t)
                (close-menu c))))))
        ;; a tap or hold on content
        (t
         (multiple-value-bind (kind payload)
             (warp:gesture-command gesture (warp:p-type p) (consumer-view c)
                                   :invoker (consumer-invoker c))
           (case kind
             (:invoke
              (close-menu c)
              (setf (consumer-selected c) (warp:p-key p))
              (run-command c payload (warp:p-object p)))
             (:menu (open-menu c p payload))
             (t nil))))))))

(defun run-command (c command object &key confirmed)
  "Invoke, and let warp refuse.  The surface never second-guesses the policy — it only reports.
The invoker is the CONSUMER's, so an owner and a guest over one projection get different answers
here, and rule 6 is unchanged: this is the enforcement point, the menu was courtesy."
  (handler-case
      (let ((r (warp:invoke (warp:cmd-name command) object (consumer-invoker c)
                            :confirmed confirmed)))
        (setf (consumer-last-result c) r)
        r)
    (warp:command-refused (e)
      (setf (consumer-last-result c) (list :refused (warp:refused-reason e)))
      (format *error-output* "~&[warp] ~a~%" e)
      (finish-output *error-output*)
      nil)))

(defun make-surface (&key fb port name view rows-fn (type-fn nil type-fn-p) (budget 400)
                          (invoker :allowlist) (scroll-y 0) width viewport-h (row-height 32))
  "One consumer over a projection of its own — the single-seat case.  Two windows over ONE
projection is ATTACH on a projection you already have."
  (attach (if type-fn-p (make-projection rows-fn :type-fn type-fn) (make-projection rows-fn))
          :fb fb :port port :name name :view view :budget budget :invoker invoker
          :scroll-y scroll-y :width width :viewport-h viewport-h :row-height row-height))

(defun make-surface-app (fb &key view rows-fn (type-fn nil type-fn-p) (budget 400)
                              (invoker :allowlist) projection)
  "The WM surface contract: given a framebuffer, return (values ON-KEY ON-POINTER DIRTY-P CONSUMER).
DIRTY-P is a warp pass — take the current result-set, emit what is owed, paint only that, and report
whether anything changed.  This is how warp becomes a window in the glass desktop rather than a
separate server: the WM owns the framebuffer, decorates and composites it, and knows nothing about
presentations.

Pass PROJECTION to seat this window at a result-set that is already being looked at.  The WM polls
each window's DIRTY-P independently and in no particular order, which is exactly the fan-out rule 8
describes: the query runs for whichever window needs a fresher epoch, and the others read the cache.
The window's SIZE is not part of that: this consumer lays the objects out to its own framebuffer, so
a window the WM resizes follows its own viewport and the other seats do not move."
  (let ((c (if projection
               (attach projection :fb fb :view view :budget budget :invoker invoker)
               (if type-fn-p
                   (make-surface :fb fb :view view :rows-fn rows-fn :type-fn type-fn
                                 :budget budget :invoker invoker)
                   (make-surface :fb fb :view view :rows-fn rows-fn
                                 :budget budget :invoker invoker)))))
    (glass:with-fb-locked (fb) (glass:fb-fill fb +bg+))
    (values
     ;; on-key: Escape dismisses an open menu, which is the only key this surface needs yet
     (lambda (down keysym)
       (when (and down (= keysym #xff1b) (consumer-menu c)) (close-menu c) t))
     (lambda (mask x y) (on-pointer c mask x y))
     ;; dirty-p: the WM polls this; a pass returns non-nil exactly when it painted
     (lambda () (and (tick c) t))
     c)))

(defun run (&key (port 5910) (width 480) (height 448) (name "warp") view rows-fn
                 (type-fn nil type-fn-p) projection (scroll-y 0)
                 (hz 4) (budget 400) (invoker :allowlist))
  "Serve a warp surface over RFB on PORT.  Returns the CONSUMER; the paint loop and the RFB server
each run on their own thread.  Pass PROJECTION (and no ROWS-FN) to serve a second seat, on its own
port, with its own budget, its own window size and its own scroll offset, at a result-set already
being looked at."
  (let* ((fb (glass:make-framebuffer width height +bg+))
         (c (if projection
                (attach projection :fb fb :view view :budget budget :invoker invoker
                                   :name name :port port :scroll-y scroll-y)
                (if type-fn-p
                    (make-surface :fb fb :port port :name name :view view :rows-fn rows-fn
                                  :type-fn type-fn :budget budget :invoker invoker
                                  :scroll-y scroll-y)
                    (make-surface :fb fb :port port :name name :view view :rows-fn rows-fn
                                  :budget budget :invoker invoker :scroll-y scroll-y)))))
    (bt:make-thread
     (lambda ()
       (handler-case
           (glass:serve fb port :name name
                        :on-pointer (lambda (mask x y) (on-pointer c mask x y)))
         (error (e) (format *error-output* "~&[warp] serve: ~a~%" e))))
     :name "warp-rfb")
    (bt:make-thread
     (lambda ()
       (loop until (consumer-stop c) do
         (handler-case (tick c)
           (error (e) (format *error-output* "~&[warp] tick: ~a~%" e)))
         (sleep (/ 1.0 hz))))
     :name "warp-paint")
    c))
