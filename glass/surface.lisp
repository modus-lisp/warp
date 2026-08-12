;;;; glass/surface.lisp — warp's framebuffer encoding: deltas become framebuffer writes.
;;;;
;;;; THE PROTOCOL IS NOT IN THIS FILE.  The projection, the consumer, layout, budget, the stream, the
;;;; menu model and what a gesture means all live in WARP, where a consumer with no pixels can reach
;;;; them.  What is here is one encoding: a CONSUMER subclass whose target is a glass framebuffer,
;;;; the three methods that make it one (APPLY-DELTAS, VIEWPORT-WIDTH/HEIGHT, MENU-PRESENTATIONS),
;;;; pixel hit-testing, and the RFB input mapping.  A DOM consumer over a data channel is the same
;;;; three methods against a different target and does not load this file or glass at all.
;;;;
;;;; The important discipline is that a pass paints ONLY the extents the stream emitted — never the
;;;; whole view — because glass discovers damage by diffing tiles against its snapshot and ships the
;;;; dirty ones.  So glass independently CHECKS warp: if the reconciler is right, the tiles glass
;;;; finds dirty are the extents warp emitted, and nothing else.
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


;;; ---- a consumer whose encoding target is a framebuffer ----------------------
;;; DESIGN.md rule 8: a consumer is whatever owns an encoding target, and under glass's seat model
;;; the content framebuffer belongs to the WINDOW — so two glass seats at one window are ONE warp
;;; consumer.  That is what this class is: the window's framebuffer, plus the port it is served on.
;;;
;;; It adds no protocol.  Everything above it — pull, lay out, diff, budget, defer, drain — is
;;; WARP's and is shared with every other encoding.

(defclass fb-consumer (warp:consumer)
  ((fb :initarg :fb :initform nil :accessor consumer-fb)
   (port :initarg :port :initform nil :accessor consumer-port))
  (:documentation "One seat: a glass window's framebuffer, and the RFB port it is reached on."))

(deftype surface () 'fb-consumer)

(defun attach (projection &rest initargs &key (class 'fb-consumer) &allow-other-keys)
  "Seat a framebuffer consumer at PROJECTION.  This is WARP:ATTACH with this file's encoding as the
default class; everything else about attaching — the empty stream, the late-joiner discipline — is
warp's and is not repeated here."
  (apply #'warp:attach projection :class class initargs))

;;; The viewport used to be READ OFF the framebuffer, which quietly made "how big is the view" a
;;; pixel question for every consumer.  It is an ordinary slot in core now; this is the encoding that
;;; happens to have a better answer, and an explicit width still wins over the framebuffer's.

(defmethod viewport-width ((c fb-consumer))
  (or (consumer-width c) (and (consumer-fb c) (glass:fb-width (consumer-fb c))) (call-next-method)))

(defmethod viewport-height ((c fb-consumer))
  (or (consumer-viewport-h c) (and (consumer-fb c) (glass:fb-height (consumer-fb c)))
      (call-next-method)))

;;; ---- the encoding: deltas become framebuffer writes -------------------------

(defmethod apply-deltas ((c fb-consumer) deltas)
  "Paint exactly what the stream emitted, and nothing else."
  (let ((fb (consumer-fb c)) (view (consumer-view c)))
    (glass:with-fb-locked (fb)
      (dolist (d deltas)
        (ecase (warp:delta-kind d)
          ((:appeared :changed)
           (paint fb (warp:delta-presentation d) view)
           (incf (consumer-landed c)))
          (:moved
           ;; No blit yet: repaint at the new extent and clear where it came from.  The :moved KIND
           ;; is still the right thing to carry — it is what a CopyRect or a motion vector will use
           ;; once the encoder can see a translation (DESIGN.md rule 2).
           (let* ((p (warp:delta-presentation d)) (e (warp:p-extent p)))
             (clear-extent fb (list (- (warp::extent-x e) (warp:delta-dx d))
                                    (- (warp::extent-y e) (warp:delta-dy d))
                                    (warp::extent-w e) (warp::extent-h e)))
             (paint fb p view)
             (incf (consumer-landed c))))
          (:gone
           (clear-extent fb (warp:delta-extent d))
           (incf (consumer-landed c))))))))

;;; ---- menu geometry ----------------------------------------------------------
;;; The menu MODEL is warp's (rules 5 and 6, menu.lisp): what a menu is, what is on it, and what
;;; tapping an item does are the same for every consumer, and core's default emits the items with no
;;; extents.  What is this encoding's is MEASUREMENT and PLACEMENT — how wide a menu is in pixels,
;;; and where it sits relative to the row that was held.

(defparameter +menu-w+ 224)
(defparameter +menu-row+ 32)

(defmethod menu-presentations ((c fb-consumer))
  "Lay this consumer's open menu out beneath its target row, as ordinary presentations."
  (let ((m (consumer-menu c)))
    (when m
      (destructuring-bind (&key target items) m
        ;; This encoding places the menu relative to the row that was held, so unlike core's
        ;; extent-less default it genuinely needs that row's geometry.  Say so.
        (check-type target warp:presentation)
        (let* ((te (warp:p-extent target))
               (x (min (warp::extent-x te) (max 0 (- (viewport-width c) +menu-w+))))
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

;;; ---- input: pixels back to presentations ------------------------------------
;;; Rule 5 puts recognition at the edge and carries (gesture, x, y).  Turning (x, y) into a
;;; presentation is the encoding's half of that, because only the encoding knows what its coordinates
;;; mean — this one hit-tests extents.  What the gesture MEANS once it has landed is WARP:ON-GESTURE,
;;; shared with every other consumer.

(defun hit (c x y)
  "The presentation under (X,Y), or NIL.  Reverse order so the topmost wins."
  (find-if (lambda (p)
             (let ((e (warp:p-extent p)))
               (and e (<= (warp::extent-x e) x (+ (warp::extent-x e) (warp::extent-w e) -1))
                    (<= (warp::extent-y e) y (+ (warp::extent-y e) (warp::extent-h e) -1)))))
           (reverse (consumer-visible c))))

(defun on-pointer (c mask x y)
  "Interim gesture mapping (see the file header): button 1 = tap, button 3 = hold, wheel = the
two-finger pan of rule 5 arriving in the client's lossy encoding.
Everything this touches — the scroll offset, the menu, the selection, the invoker the gesture is
resolved against — is this consumer's.  Another seat over the same projection is not disturbed by
any of it, which is what the fused boundary could not do: scrolling one seat moved both."
  (when (or (logtest mask 8) (logtest mask 16))                ; buttons 4/5: wheel up/down
    (scroll-by c (if (logtest mask 8) (- (consumer-row-height c)) (consumer-row-height c)))
    (return-from on-pointer t))
  (let ((gesture (cond ((logtest mask 1) :tap) ((logtest mask 4) :hold) (t nil))))
    (on-gesture c gesture (and gesture (hit c x y)))))

;;; ---- the names this package used to own --------------------------------------
;;; SF- was the single-seat surface's accessor prefix and CONSUMER-PAINTED counted paints.  The
;;; slots behind them are warp's now (a consumer LANDS deltas; only this encoding paints them), so
;;; these are aliases rather than slots.  Kept because every existing call site says them, and the
;;; single-consumer path must stay the same code path rather than an equivalent one.

(macrolet ((alias (name real &key setf)
             `(progn (declaim (inline ,name))
                     (defun ,name (c) (,real c))
                     ,@(when setf `((defun (setf ,name) (v c) (setf (,real c) v)))))))
  (alias consumer-painted warp:consumer-landed :setf t)
  (alias sf-projection consumer-projection :setf t)
  (alias sf-fb consumer-fb :setf t)
  (alias sf-port consumer-port :setf t)
  (alias sf-name warp:consumer-name :setf t)
  (alias sf-view consumer-view :setf t)
  (alias sf-scroll-y consumer-scroll-y :setf t)
  (alias sf-stream consumer-stream :setf t)
  (alias sf-budget consumer-budget :setf t)
  (alias sf-invoker consumer-invoker :setf t)
  (alias sf-selected consumer-selected :setf t)
  (alias sf-menu consumer-menu :setf t)
  (alias sf-visible consumer-visible :setf t)
  (alias sf-last-result consumer-last-result :setf t)
  (alias sf-painted warp:consumer-landed :setf t)
  (alias sf-emitted consumer-emitted :setf t)
  (alias sf-passes consumer-passes :setf t)
  (alias sf-deferred consumer-deferred :setf t)
  (alias sf-stop consumer-stop :setf t)
  (alias sf-rows-fn consumer-rows-fn)
  (alias sf-lock consumer-lock))

;;; ---- constructing one ---------------------------------------------------------

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
