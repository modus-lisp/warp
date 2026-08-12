;;;; t/core.lisp — THE ACID TEST: the whole protocol, in an image where glass has never been loaded.
;;;;
;;;; Everything else in t/ can pass while the protocol is still shaped like a framebuffer.  This is
;;;; the one that cannot: it loads :warp and nothing else, asserts that no part of glass came with
;;;; it, and then does the entire round trip — construct a projection, attach consumers, pull, lay
;;;; out, emit deltas under a budget, defer and drain, open a menu, resolve a gesture, invoke a
;;;; command and be refused — with no framebuffer anywhere in the image.
;;;;
;;;; It is written for the encoding that comes next.  A DOM consumer receives deltas over a WebRTC
;;;; data channel and lays out in the browser's own viewport; it must be able to subclass WARP's
;;;; consumer, specialise three methods, and get the protocol.  If it had to subclass a class in
;;;; WARP-GLASS it would have to load glass to reach it — which is what this file is here to stop
;;;; from being true again.
;;;;
;;;; It fails on the build before the move at the very first assertion, because there is no
;;;; WARP:CONSUMER to attach.

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream))) (asdf:load-system :warp)))

(defpackage #:warp-core-test (:use #:cl #:warp)) (in-package #:warp-core-test)

(defvar *fails* 0)
(defun ok (n p) (format t "~&  ~:[FAIL~;ok  ~] ~a~%" p n) (unless p (incf *fails*)))
(defun kinds (ds) (mapcar #'delta-kind ds))

;;; ---- 1. the acid test proper: :warp loads, and glass did not come with it ----

(format t "~&== (asdf:load-system :warp) in an image that has never seen glass ==~%")
(ok "the GLASS package does not exist" (null (find-package "GLASS")))
(ok "neither does WARP-GLASS" (null (find-package "WARP-GLASS")))
(ok "and :warp does not depend on either, transitively or otherwise"
    (labels ((deps (sys &optional (seen (make-hash-table :test 'equal)))
               (let ((name (asdf:component-name (asdf:find-system sys))))
                 (unless (gethash name seen)
                   (setf (gethash name seen) t)
                   (dolist (d (asdf:system-depends-on (asdf:find-system sys)))
                     (when (stringp d) (deps d seen))))
                 seen)))
      (let ((all (deps "warp")))
        (and (not (gethash "glass" all)) (not (gethash "warp-glass" all))))))
(ok "the protocol is reachable under WARP: the class, the seam, and the pull"
    (and (find-class 'consumer nil) (find-class 'projection nil)
         (typep #'lay-out 'generic-function) (typep #'apply-deltas 'generic-function)
         (typep #'menu-presentations 'generic-function)
         (fboundp 'pull) (fboundp 'attach) (fboundp 'tick)))

;;; ---- 2. a consumer with no encoding target cannot be CONSTRUCTED -------------
;;; Not "crashes the moment it is owed a delta", which is what a default APPLY-DELTAS needing a
;;; framebuffer produced: reachable only on the pass where a budget happens to let something
;;; through, and indistinguishable from an intermittent reconciler bug.

(defclass forgot-the-encoding (consumer) ())

(format t "~&== a consumer is defined by having somewhere to put deltas ==~%")
(ok "WARP:CONSUMER itself is abstract and refuses to be instantiated"
    (handler-case (progn (make-instance 'consumer) nil) (error () t)))
(ok "so does a subclass that never said where its deltas land"
    (handler-case (progn (make-instance 'forgot-the-encoding) nil) (error () t)))
(ok "and the refusal names APPLY-DELTAS, so the fix is in the message"
    (handler-case (progn (make-instance 'forgot-the-encoding) nil)
      (error (e) (search "APPLY-DELTAS" (princ-to-string e)))))

;;; ---- 3. the domain, and a projection over it --------------------------------

(defclass enrolment ()
  ((pubkey :initarg :pubkey :accessor pubkey)
   (expires :initarg :expires :accessor expires)))
(define-presentation-key enrolment (e) (pubkey e))
(defun e* (pk exp) (make-instance 'enrolment :pubkey pk :expires exp))

(defmethod present ((o enrolment) (type (eql 'enrolment)) (view (eql 'wire-view)))
  (list (pubkey o) (format nil "expires ~a" (expires o))))

(define-command (inspect-enrolment :arg-type enrolment :cost :local :label "inspect") (o i)
  (list :inspected (pubkey o)))
(define-command (revoke-enrolment :arg-type enrolment :cost :gateway
                                  :destructive t :confirm t :label "revoke") (o i)
  (list :revoked (pubkey o)))
(define-command-authorization revoke-enrolment (i) (eq i :allowlist))
(define-default-command 'enrolment 'wire-view 'inspect-enrolment)

(defvar *rows* (loop for i below 20 collect (e* (format nil "k~2,'0d" i) (* 10 i))))
(defvar *queries* 0)
(defvar *proj* (make-projection (lambda () (incf *queries*) *rows*)
                                :type-fn (constantly 'enrolment)))

(format t "~&== a projection is a query over objects, and holds no picture of them ==~%")
(ok "no consumer has pulled yet, so no query has run" (zerop (projection-queries *proj*)))

;;; ---- 4. the whole round trip, with no framebuffer ---------------------------
;;; RECORDING-CONSUMER is core's own encoding: the deltas ARE the semantic wire format, and this is
;;; that shape with the serialization left out.

(defvar *a* (attach *proj* :view 'wire-view :budget 100000 :invoker :allowlist
                           :width 480 :viewport-h 320 :row-height 32))

(format t "~&== pull, lay out, emit, inspect — none of which needs a pixel ==~%")
(multiple-value-bind (objects as-of) (pull *proj* *a*)
  (ok "PULL returns the domain objects and the AS-OF of the read"
      (and (= 20 (length objects)) (integerp as-of)
           (every (lambda (o) (typep o 'enrolment)) objects)))
  (ok "and it ran the query exactly once" (= 1 *queries*))
  (let ((ps (lay-out *a* objects as-of)))
    (ok "LAY-OUT gives this consumer the slice its own viewport can hold"
        (and (= 10 (length ps)) (every (lambda (p) (typep p 'presentation)) ps)))
    (ok "fingerprints are PRESENT's output under THIS consumer's view"
        (equal (present (first *rows*) 'enrolment 'wire-view) (p-fingerprint (first ps))))))

(let ((d (tick *a*)))
  (ok "a tick emits deltas the caller can read"
      (and (= 10 (length d)) (every (lambda (k) (eq k :appeared)) (kinds d))))
  (ok "and the consumer's encoding landed exactly them"
      (and (= 10 (consumer-landed *a*)) (equal d (consumer-record *a*)))))
(ok "TAKE-RECORD is the flush a transport does" (and (= 10 (length (take-record *a*)))
                                                     (null (consumer-record *a*))))
(ok "an idle pass emits nothing" (null (tick *a*)))

(format t "~&== budget, deferral and idle drain, per consumer, with no fb to blame ==~%")
(defvar *b* (attach *proj* :view 'wire-view :budget 130 :invoker :device
                           :width 480 :viewport-h 320 :row-height 32))
(let ((d (tick *b*)))
  (ok "a slow link is given some and owed the rest"
      (and (plusp (length d)) (< (length d) 10) (plusp (consumer-deferred *b*)))))
(let ((rounds 0))
  (loop while (plusp (consumer-deferred *b*)) do (incf rounds) (tick *b*) (when (> rounds 50) (return)))
  (ok "it drains with nothing new arriving" (<= rounds 50))
  (ok "and was never told anything twice" (= 10 (consumer-emitted *b*))))
(ok "both consumers converged to the same held state"
    (flet ((memory (c) (let ((out '()))
                         (maphash (lambda (k p) (push (list k (p-fingerprint p) (p-extent p)) out))
                                  (warp::ds-delivered (consumer-stream c)))
                         (sort out #'string< :key (lambda (r) (princ-to-string (first r)))))))
      (equal (memory *a*) (memory *b*))))
(let ((q0 (projection-queries *proj*)))
  (dotimes (i 5) (tick-all *proj*))
  (ok "five rounds of two consumers cost five queries, not ten"
      (= 5 (- (projection-queries *proj*) q0))))

(format t "~&== two consumers, two viewports, two scroll offsets, one query ==~%")
(defvar *c* (attach *proj* :view 'wire-view :budget 100000
                           :width 480 :viewport-h 96 :row-height 32 :scroll-y 320))
(let ((q0 (projection-queries *proj*)))
  (let ((dc (tick *c*)) (da (tick *a*)))
    (declare (ignorable da))
    (ok "the narrow consumer is told three rows, ten down"
        (equal '("k10" "k11" "k12") (sort (mapcar #'delta-key dc) #'string<)))
    (ok "both filled from the CACHED epoch: joining ran no query at all"
        (= 0 (- (projection-queries *proj*) q0)))
    (ok "and its slice is disjoint from the wide one's"
        (null (intersection (mapcar #'delta-key dc)
                            (mapcar (lambda (p) (p-key p)) (consumer-visible *a*))
                            :test #'string=))))
  (let ((q1 (projection-queries *proj*)))
    (tick *c*) (tick *a*)
    (ok "and their next round costs ONE query between them, whatever their viewports"
        (= 1 (- (projection-queries *proj*) q1)))))
(ok "scroll clamps to this consumer's own content and viewport"
    (progn (scroll-by *c* 100000) (= (consumer-scroll-y *c*) (- (* 20 32) 96))))

;;; ---- 5. the menu and the gesture, without a finger ---------------------------

(format t "~&== menus are presentations, and core's have no extents at all ==~%")
(let* ((held (find "k00" (consumer-visible *a*) :key #'p-key :test #'string=)))
  (ok "a row is on screen to hold" (not (null held)))
  (multiple-value-bind (kind payload) (gesture-command :hold 'enrolment 'wire-view :invoker :allowlist)
    (declare (ignore kind))
    (on-gesture *a* :hold held)
    (ok "hold opened a menu of the applicable commands" (= 3 (length (getf (consumer-menu *a*) :items))))
    (ok "including revoke, for this invoker" (= 2 (length payload))))
  (let ((d (tick *a*)))
    (ok "its items arrive as ordinary :appeared deltas"
        (and (= 3 (length d)) (every (lambda (k) (eq k :appeared)) (kinds d))))
    (ok "typed MENU-ITEM, keyed like everything else"
        (every (lambda (x) (eq 'menu-item (p-type (delta-presentation x)))) d))
    (ok "and carrying NO extents — geometry is the encoding's, and core has none"
        (every (lambda (x) (null (p-extent (delta-presentation x)))) d))
    (ok "an extent-less presentation still costs a unit and can never be a :moved"
        (= 1 (warp::presentation-cost (delta-presentation (first d)))))))

(format t "~&== rule 6 holds with no surface in sight ==~%")
(let* ((rev (find-if (lambda (p) (and (eq (p-type p) 'menu-item)
                                      (eq :command (mi-kind (p-object p)))
                                      (cmd-destructive (mi-command (p-object p)))))
                     (consumer-visible *a*))))
  (on-gesture *a* :tap rev)
  (ok "tapping a destructive item confirms rather than acting" (null (consumer-last-result *a*)))
  (ok "and the menu became a confirmation"
      (let ((items (getf (consumer-menu *a*) :items)))
        (and (= 2 (length items)) (eq :confirm (mi-kind (first items)))))))
(tick *a*)
(let ((cf (find-if (lambda (p) (and (eq (p-type p) 'menu-item) (eq :confirm (mi-kind (p-object p)))))
                   (consumer-visible *a*))))
  (on-gesture *a* :tap cf)
  (ok "confirming runs it" (equal '(:revoked "k00") (consumer-last-result *a*)))
  (ok "and the menu closed" (null (consumer-menu *a*))))
(ok "closing emits :gone for exactly its items" (= 2 (count :gone (kinds (tick *a*)))))

(format t "~&== invocation is still the one enforcement point ==~%")
(setf (consumer-last-result *b*) nil)
(let ((*error-output* (make-broadcast-stream)))
  (run-command *b* (find-command 'revoke-enrolment) (first *rows*) :confirmed t))
(ok "the guest consumer is refused" (eq :refused (first (consumer-last-result *b*))))
(ok "and the refusal did not leak into its neighbour's state"
    (equal '(:revoked "k00") (consumer-last-result *a*)))

;;; ---- 6. a second encoding, built here, using nothing but core ----------------
;;; This is the shape the DOM consumer will have: its own LAY-OUT (the browser places rows, so the
;;; presentations carry no extents at all) and its own APPLY-DELTAS (serialise and ship).  It is 12
;;; lines, it subclasses WARP:CONSUMER, and it loads no encoding but its own.

(defclass wire-consumer (consumer)
  ((sent :initform '() :accessor sent)))

(defmethod lay-out ((c wire-consumer) objects as-of)
  (loop for o in objects
        collect (make-presentation :key (presentation-key 'enrolment o) :type 'enrolment :object o
                                   :extent nil :as-of as-of
                                   :fingerprint (present o 'enrolment (consumer-view c)))))

(defmethod apply-deltas ((c wire-consumer) deltas)
  (dolist (d deltas)
    (push (list (delta-kind d) (delta-key d)
                (and (delta-presentation d) (p-fingerprint (delta-presentation d))))
          (sent c))
    (incf (consumer-landed c))))

(format t "~&== a second encoding is three methods, not a second architecture ==~%")
(defvar *w* (attach *proj* :class 'wire-consumer :view 'wire-view :budget 6))
(ok "it constructs, because it said where its deltas land" (typep *w* 'consumer))
(let ((d (tick *w*)))
  (ok "it is told rows under its own budget, in its own units"
      (and (= 6 (length d)) (plusp (consumer-deferred *w*)))))
(loop repeat 20 while (plusp (consumer-deferred *w*)) do (tick *w*))
(ok "it converges to the WHOLE result-set — it has no viewport clipping its slice"
    (= 20 (length (sent *w*))))
(ok "with no extents anywhere in what it was sent"
    (every (lambda (p) (null (p-extent p)))
           (let ((out '()))
             (maphash (lambda (k p) (declare (ignore k)) (push p out))
                      (warp::ds-delivered (consumer-stream *w*)))
             out)))
(ok "and a change still reaches it as one :changed, keyed"
    (progn (setf (expires (nth 5 *rows*)) 999)
           (let ((d (tick *w*)))
             (and (equal '(:changed) (kinds d)) (string= "k05" (delta-key (first d)))))))
(ok "one query still served every consumer in the round"
    (let ((q0 (projection-queries *proj*)))
      (tick-all *proj*)
      (= 1 (- (projection-queries *proj*) q0))))
(ok "and the projection still holds objects, never presentations"
    (notany (lambda (o) (typep o 'presentation)) (projection-objects *proj*)))

;;; ---- 7. and the BUDGET is spent in that encoding's unit ----------------------
;;; The seam above stops short if a delta's price is still a rectangle: a consumer whose
;;; presentations have no extents pays a flat 1 for everything, so `budget` quietly means "N deltas
;;; per pass" — usable, but it is not the consumer's unit.  A browser's budget is BYTES on a data
;;; channel.  So DELTA-COST is generic on the consumer, exactly like LAY-OUT and APPLY-DELTAS.

(defclass measured-consumer (wire-consumer) ())

(defmethod delta-cost ((c measured-consumer) d)
  "This encoding is billed by the length of what it would actually put on the wire."
  (length (format nil "~a ~a ~a" (delta-kind d) (delta-key d)
                  (and (delta-presentation d) (p-fingerprint (delta-presentation d))))))

(format t "~&== a budget is denominated in the CONSUMER's unit, not in macroblocks ==~%")
(defvar *m* (attach *proj* :class 'measured-consumer :view 'wire-view :budget 200))
(let ((d (tick *m*)))
  (ok "core prices an extent-less delta at a flat 1 — the macroblock default, with no rectangle"
      (and (null (p-extent (delta-presentation (first d)))) (= 1 (delta-cost nil (first d)))))
  (ok "the SAME delta costs this encoding something else entirely, because it said so"
      (> (delta-cost *m* (first d)) 1))
  (ok "so a 200-unit budget buys a number of rows the delta count cannot explain"
      (and (plusp (length d)) (< (length d) 20) (plusp (consumer-deferred *m*))))
  (ok "and what it was given fits the budget it was given, measured in that unit"
      (<= (reduce #'+ (mapcar (lambda (x) (delta-cost *m* x)) d)) 200)))
(loop repeat 30 while (plusp (consumer-deferred *m*)) do (tick *m*))
(ok "a byte-priced consumer still drains to convergence with nothing new arriving"
    (and (zerop (consumer-deferred *m*)) (= 20 (length (sent *m*)))))
(ok "rule 4 is untouched by the reprice: nothing was ever sent twice"
    (= 20 (consumer-emitted *m*)))

(format t "~&== still no glass, after all of that ==~%")
(ok "the GLASS package still does not exist" (null (find-package "GLASS")))
(ok "and neither does WARP-GLASS" (null (find-package "WARP-GLASS")))

(format t "~&~:[~a TEST(S) FAILED~;ALL TESTS PASSED~]~%" (zerop *fails*) *fails*)
