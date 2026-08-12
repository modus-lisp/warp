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
;;;   PROJECTION   the result-set being looked at.  Computed ONCE per tick and fanned out.
;;;   CONSUMER     one seat: its own stream, budget, framebuffer, view state, invoker, counters.
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
            :documentation "() -> the current result-set, as presentations.")
   (view :initarg :view :initform nil :accessor projection-view
         :documentation "PRESENT dispatches on it, so the fingerprints were derived under it; a
consumer cannot hold a different one and still diff against these rows.  A second view is a second
projection.")
   (rows :initform '() :accessor projection-rows :documentation "The cached result-set.")
   (epoch :initform 0 :accessor projection-epoch)
   (queries :initform 0 :accessor projection-queries
            :documentation "How many times ROWS-FN has actually run.  The measurement rule 8 is
about: with N consumers ticking in a round, this advances once.")
   (consumers :initform '() :accessor projection-consumers)
   (lock :initform (bt:make-lock "warp-projection") :reader projection-lock))
  (:documentation "The shared half: the result-set being looked at."))

(defun make-projection (rows-fn &key view)
  (make-instance 'projection :rows-fn rows-fn :view view))

(defclass consumer ()
  ((projection :initarg :projection :accessor consumer-projection :accessor sf-projection)
   ;; where it lands, and how it is reached
   (fb :initarg :fb :initform nil :accessor consumer-fb :accessor sf-fb)
   (port :initarg :port :initform nil :accessor consumer-port :accessor sf-port)
   (name :initarg :name :initform nil :accessor consumer-name :accessor sf-name)
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
            :documentation "The set this consumer was last shown — shared rows plus its own menu —
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
;;; the single-consumer path is the same code path rather than an equivalent one.  VIEW and ROWS-FN
;;; now live on the projection, so those two delegate.

(deftype surface () 'consumer)
(defun consumer-view (c) (projection-view (consumer-projection c)))
(defun consumer-rows-fn (c) (projection-rows-fn (consumer-projection c)))
(defun sf-view (c) (consumer-view c))
(defun sf-rows-fn (c) (consumer-rows-fn c))

(defun attach (projection &key fb (budget 400) (invoker :allowlist) name port)
  "Seat a consumer at PROJECTION.  Its stream starts EMPTY — it cannot inherit anyone else's
high-water mark, which is the late-joiner bug — so its first pass announces the whole working set,
chunked and budgeted by exactly the path every other pass uses."
  (let ((c (make-instance 'consumer :projection projection :fb fb :budget budget
                                    :invoker invoker :name name :port port)))
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
  "The shared result-set, at an epoch CONSUMER has not been handed yet.

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
      (setf (projection-rows projection) (funcall (projection-rows-fn projection)))
      (incf (projection-epoch projection))
      (incf (projection-queries projection)))
    (setf (consumer-epoch consumer) (projection-epoch projection))
    (projection-rows projection)))

;;; ---- view state annotates the shared row, copy-on-write ---------------------

(defun view-state (c p)
  "What this consumer's view state adds to the shared presentation P — NIL when it has nothing to
say, which is every row but one."
  (let ((sel (consumer-selected c)))
    (when (and sel (equal sel (warp:p-key p))) (list :selected t))))

(defun consumer-presentation (c p)
  "The shared presentation as THIS consumer holds it.  Untouched unless its view state annotates it,
so the projection's work stays genuinely shared and only the selected row is ever copied."
  (let ((st (view-state c p)))
    (if (null st)
        p
        (let ((q (warp:copy-presentation p)))
          (setf (warp:p-state q) st)
          q))))

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

(defun apply-deltas (c deltas)
  "Paint exactly what the stream emitted, and nothing else."
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
  "One pass for one consumer: take the shared result-set, annotate it with this consumer's view
state, add this consumer's menu, advance this consumer's stream under this consumer's budget, and
paint only what that emitted.  EMITTER is WARP:EMIT or, for a resync, WARP:SNAPSHOT — the two differ
only in whether the delivered state is forgotten first and the generation bumped, which is why a
resync needs no path of its own."
  (let* ((shared (pull (consumer-projection c) c))
         (rows (append (if (consumer-selected c)
                           (mapcar (lambda (p) (consumer-presentation c p)) shared)
                           shared)
                       (menu-presentations c))))
    (multiple-value-bind (deltas deferred)
        (funcall emitter (consumer-stream c) rows :budget (consumer-budget c))
      (incf (consumer-passes c))
      (incf (consumer-emitted c) (length deltas))
      (setf (consumer-deferred c) deferred
            (consumer-visible c) rows)
      (when deltas (apply-deltas c deltas))
      deltas)))

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
  "Interim gesture mapping (see the file header): button 1 = tap, button 3 = hold.
Everything this touches — the menu, the selection, the invoker the gesture is resolved against — is
this consumer's.  Another seat over the same projection is not disturbed by any of it."
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

(defun make-surface (&key fb port name view rows-fn (budget 400) (invoker :allowlist))
  "One consumer over a projection of its own — the single-seat case.  Two windows over ONE
projection is ATTACH on a projection you already have."
  (attach (make-projection rows-fn :view view)
          :fb fb :port port :name name :budget budget :invoker invoker))

(defun make-surface-app (fb &key view rows-fn (budget 400) (invoker :allowlist) projection)
  "The WM surface contract: given a framebuffer, return (values ON-KEY ON-POINTER DIRTY-P CONSUMER).
DIRTY-P is a warp pass — take the current result-set, emit what is owed, paint only that, and report
whether anything changed.  This is how warp becomes a window in the glass desktop rather than a
separate server: the WM owns the framebuffer, decorates and composites it, and knows nothing about
presentations.

Pass PROJECTION to seat this window at a result-set that is already being looked at.  The WM polls
each window's DIRTY-P independently and in no particular order, which is exactly the fan-out rule 8
describes: the query runs for whichever window needs a fresher epoch, and the others read the cache."
  (let ((c (if projection
               (attach projection :fb fb :budget budget :invoker invoker)
               (make-surface :fb fb :view view :rows-fn rows-fn
                             :budget budget :invoker invoker))))
    (glass:with-fb-locked (fb) (glass:fb-fill fb +bg+))
    (values
     ;; on-key: Escape dismisses an open menu, which is the only key this surface needs yet
     (lambda (down keysym)
       (when (and down (= keysym #xff1b) (consumer-menu c)) (close-menu c) t))
     (lambda (mask x y) (on-pointer c mask x y))
     ;; dirty-p: the WM polls this; a pass returns non-nil exactly when it painted
     (lambda () (and (tick c) t))
     c)))

(defun run (&key (port 5910) (width 480) (height 448) (name "warp") view rows-fn projection
                 (hz 4) (budget 400) (invoker :allowlist))
  "Serve a warp surface over RFB on PORT.  Returns the CONSUMER; the paint loop and the RFB server
each run on their own thread.  Pass PROJECTION (and no ROWS-FN) to serve a second seat, on its own
port with its own budget, at a result-set already being looked at."
  (let* ((fb (glass:make-framebuffer width height +bg+))
         (c (if projection
                (attach projection :fb fb :budget budget :invoker invoker :name name :port port)
                (make-surface :fb fb :port port :name name :view view :rows-fn rows-fn
                              :budget budget :invoker invoker))))
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
