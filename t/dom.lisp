;;;; t/dom.lisp — the third encoding, asserted in an image that has never seen a framebuffer.
;;;;
;;;; t/core.lisp proves the protocol is reachable without glass.  This proves something narrower and
;;;; more useful: that an encoding written from OUTSIDE — by someone who never had pixels — gets the
;;;; whole of rules 1 through 8 by supplying five methods, and that the three places the protocol
;;;; had a pixel assumption baked in (cost, position, the scroll axis) now bend to it.

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream))) (asdf:load-system :warp-dom)))

(defpackage #:warp-dom-test (:use #:cl #:warp #:warp-dom)
  (:shadowing-import-from #:warp-dom #:attach))
(in-package #:warp-dom-test)

(defvar *fails* 0)
(defun ok (n p) (format t "~&  ~:[FAIL~;ok  ~] ~a~%" p n) (unless p (incf *fails*)))
(defun kinds (ds) (mapcar #'delta-kind ds))
(defun keys-of (ds) (mapcar #'delta-key ds))

;;; ---- 1. warp-dom needs :warp, and nothing that can see a pixel ---------------

(format t "~&== an encoding written from outside the framebuffer ==~%")
(ok "the GLASS package does not exist" (null (find-package "GLASS")))
(ok "neither does WARP-GLASS" (null (find-package "WARP-GLASS")))
(ok "and :warp-dom does not depend on either, transitively or otherwise"
    (labels ((deps (sys &optional (seen (make-hash-table :test 'equal)))
               (let ((name (asdf:component-name (asdf:find-system sys))))
                 (unless (gethash name seen)
                   (setf (gethash name seen) t)
                   (dolist (d (asdf:system-depends-on (asdf:find-system sys)))
                     (when (stringp d) (deps d seen))))
                 seen)))
      (let ((all (deps "warp-dom")))
        (and (not (gethash "glass" all)) (not (gethash "warp-glass" all))))))
(ok "it is five methods on core's generics, not a second protocol"
    (every (lambda (g)
             (find-if (lambda (m) (find (find-class 'dom-consumer)
                                        (sb-mop:method-specializers m)))
                      (sb-mop:generic-function-methods (fdefinition g))))
           '(lay-out apply-deltas menu-presentations delta-cost moved-p)))

;;; ---- 2. the domain ----------------------------------------------------------

(defclass enrolment ()
  ((pubkey :initarg :pubkey :accessor pubkey)
   (expires :initarg :expires :accessor expires)))
(define-presentation-key enrolment (e) (pubkey e))
(defun e* (pk exp) (make-instance 'enrolment :pubkey pk :expires exp))

(defmethod present ((o enrolment) (type (eql 'enrolment)) (view (eql 'dom-view)))
  (list (pubkey o) (format nil "expires ~a" (expires o)) :ok))

(define-command (inspect-enrolment :arg-type enrolment :cost :local :label "inspect") (o i)
  (list :inspected (pubkey o)))
(define-command (revoke-enrolment :arg-type enrolment :cost :gateway
                                  :destructive t :confirm t :label "revoke") (o i)
  (list :revoked (pubkey o)))
(define-command-authorization revoke-enrolment (i) (eq i :allowlist))
(define-default-command 'enrolment 'dom-view 'inspect-enrolment)

(defvar *rows* (loop for i below 20 collect (e* (format nil "k~2,'0d" i) (* 10 i))))
(defvar *queries* 0)
(defvar *proj* (make-projection (lambda () (incf *queries*) *rows*)
                                :type-fn (constantly 'enrolment)))

(defun jframe (c) (from-json (first (last (take-frames c)))))
(defun jdeltas (frame) (json-get frame "deltas"))

;;; ---- 3. layout: keys, types, content, order — no rectangles anywhere ---------

(defvar *d* (attach-dom *proj* :view 'dom-view :rows 6 :budget 100000 :invoker :allowlist))

(format t "~&== what a browser is told: keys, types, cells and ORDER ==~%")
(let ((ds (tick *d*)))
  (ok "the slice is the browser's own — six rows, because it said six"
      (and (= 6 (length ds))
           (equal '("k00" "k01" "k02" "k03" "k04" "k05") (sort (keys-of ds) #'string<))))
  (ok "no presentation carries a rectangle; rule 3's grid never reaches this consumer"
      (every (lambda (p) (let ((e (p-extent p)))
                           (and (consp e) (not (ignore-errors (and (= 4 (list-length e))
                                                                   (every #'integerp e)))))))
             (consumer-visible *d*)))
  (ok "what replaces it is (parent . after) — exactly what insertBefore takes"
      (let ((v (consumer-visible *d*)))
        (and (equal (cons "rows" nil) (p-extent (first v)))
             (equal (cons "rows" "k00") (p-extent (second v)))))))

(format t "~&== the wire, in full, for one delta ==~%")
(defun jfind (ds key) (find key ds :key (lambda (x) (json-get x "key")) :test #'equal))
(let* ((f (jframe *d*)) (ds (jdeltas f)) (first-row (jfind ds "k00")))
  (format t "     ~a~%" (to-json first-row))
  (ok "a frame carries the generation (rule 4) and its deltas"
      (and (integerp (json-get f "gen")) (= 6 (length ds))))
  (ok "an :appeared carries key, type, container, anchor, cells and as-of"
      (and (equal "appeared" (json-get first-row "k"))
           (equal "k00" (json-get first-row "key"))
           (equal "enrolment" (json-get first-row "type"))
           (equal "rows" (json-get first-row "in"))
           (null (json-get first-row "after"))
           (equal '("k00" "expires 0" "ok") (json-get first-row "cells"))
           (integerp (json-get first-row "as_of"))))
  (ok "the second row's anchor is the first row's key"
      (equal "k00" (json-get (jfind ds "k01") "after"))))
(ok "an idle pass emits nothing" (null (tick *d*)))

;;; ---- 4. :moved does not collapse — it gets CHEAPER ---------------------------
;;; This is the assertion the whole encoding is worth writing for.  Rule 2 exists because scroll
;;; translates every row; a DOM has no coordinates, so the rows a scroll did not touch genuinely do
;;; not move, and only the new first row's anchor changes.

(format t "~&== scrolling one row: one leaves, one arrives, and exactly ONE moves ==~%")
(scroll-by *d* 1)
(let ((ds (tick *d*)))
  (format t "     ~{~(~a~)~^ ~}~%" (kinds ds))
  (ok "one :gone, one :appeared, one :moved — not five :moved"
      (and (= 1 (count :gone (kinds ds))) (= 1 (count :appeared (kinds ds)))
           (= 1 (count :moved (kinds ds))) (zerop (count :changed (kinds ds)))))
  (ok "and the one that moved is the new first row, now anchored to nothing"
      (let ((m (find :moved ds :key #'delta-kind)))
        (and (equal "k01" (delta-key m)) (equal (cons "rows" nil) (delta-extent m)))))
  (ok "a DOM :moved carries no translation vector, because a DOM has none"
      (let ((m (find :moved ds :key #'delta-kind)))
        (and (zerop (delta-dx m)) (zerop (delta-dy m))))))
(let* ((f (jframe *d*)) (m (find "moved" (jdeltas f) :key (lambda (x) (json-get x "k"))
                                                     :test #'equal)))
  (format t "     ~a~%" (to-json m))
  (ok "and it re-sends no content at all — key, place, staleness"
      (and (null (json-get m "cells")) (null (json-get m "type")))))

(format t "~&== a RE-SORT is the case a NIL extent would have silently lost ==~%")
;; With no position on the presentation at all, "same content, different order" compares EQUAL and
;; the reconciler emits NOTHING — the browser holds a stale order forever and the code looks right.
(let ((original (copy-list *rows*)))
  (setf *rows* (append (subseq original 0 1) (reverse (subseq original 1 7)) (subseq original 7)))
  (let ((ds (tick *d*)))
    (format t "     ~{~(~a~)~^ ~} over ~{~a~^ ~}~%" (kinds ds) (keys-of ds))
    (ok "the reorder is seen, and seen as :moved rather than as re-sent content"
        (and (plusp (count :moved (kinds ds))) (zerop (count :changed (kinds ds)))))
    (ok "every moved row's new anchor is its new predecessor"
        (let ((order (mapcar #'p-key (consumer-visible *d*))))
          (every (lambda (p) (equal (cdr (p-extent p))
                                    (let ((i (position (p-key p) order :test #'equal)))
                                      (and (plusp i) (nth (1- i) order)))))
                 (consumer-visible *d*)))))
  (setf *rows* original)
  (tick *d*))

;;; ---- 4b. the contract the CLIENT has to satisfy, pinned here -----------------
;;; A rectangle is absolute, so deltas carrying rectangles apply in any order.  An anchor is
;;; RELATIVE, and "insert X after Y" is unappliable until Y exists.  Two independent things put an
;;; anchor after its dependent, and neither is a bug to be fixed on the server:
;;;
;;;   * the reconciler emits within a priority band in reverse layout order (below);
;;;   * and the BUDGET can defer the anchor to a later pass entirely, which NO ordering rule on the
;;;     server could repair.
;;;
;;; So the client must be able to hold a node it cannot yet place.  Asserted here rather than only
;;; in the browser, because it is a property of the WIRE and it is what dom/client.html's `waiting`
;;; map exists for — and a future reordering of emission must not be mistaken for making that
;;; requirement go away.

(format t "~&== a delta's anchor may arrive AFTER the delta that needs it ==~%")
(on-message *d* "{\"t\":\"viewport\",\"rows\":4,\"scroll\":0}")
(tick *d*)
(on-message *d* "{\"t\":\"viewport\",\"rows\":6,\"scroll\":0}")
(let* ((ds (tick *d*))
       (order (mapcar #'delta-key ds))
       (anchors (mapcar (lambda (x) (cdr (delta-extent x))) ds)))
  (format t "     emitted ~{~a~^ ~} anchored to ~{~a~^ ~}~%" order (substitute "-" nil anchors))
  (ok "two rows appended arrive as :appeared" (= 2 (count :appeared (kinds ds))))
  (ok "and at least one names an anchor that is later in the SAME pass — a forward reference"
      (some (lambda (d) (let ((a (cdr (delta-extent d))))
                          (and a (member a (cdr (member d ds)) :key #'delta-key :test #'equal))))
            ds)))

;;; ---- 5. the budget is BYTES, and it bites -----------------------------------

(format t "~&== a byte budget, spent in bytes ==~%")
(defvar *phone* (attach-dom *proj* :view 'dom-view :rows 14 :budget 320 :invoker :device))
(ok "core would price these deltas at a flat 1 each; this encoding prices them in bytes"
    (let ((ds (tick *phone*)))
      (and (> (delta-cost *phone* (first ds)) 40)
           (= 1 (delta-cost nil (first ds))))))
(ok "a 320-byte budget delivers a handful of rows, not fourteen and not one"
    (and (< 1 (consumer-emitted *phone*) 14) (plusp (consumer-deferred *phone*))))
(let ((rounds 0) (frames 0))
  (loop while (plusp (consumer-deferred *phone*))
        do (incf rounds) (when (tick *phone*) (incf frames)) (when (> rounds 40) (return)))
  (format t "     drained in ~a further passes; ~a bytes delivered for ~a rows~%"
          rounds (dom-sent-bytes *phone*) (consumer-emitted *phone*))
  (ok "it drains to convergence with nothing new arriving (rule 4's idle drain)" (<= rounds 40))
  (ok "and was never told anything twice" (= 14 (consumer-emitted *phone*)))
  (ok "no single pass ever exceeded the byte budget it was given"
      (every (lambda (frame)
               (<= (reduce #'+ (mapcar (lambda (d) (length (to-json d))) (jdeltas (from-json frame))))
                   ;; the budget bounds the DELTAS; the frame envelope is fixed overhead on top
                   (+ 320 200)))
             (take-frames *phone*))))
(ok "the fast consumer next door was not slowed by any of it" (null (tick *d*)))

;;; ---- 6. the viewport is the browser's, and it says so -----------------------

(format t "~&== the browser reports its own viewport; the server slices to it ==~%")
(on-message *d* "{\"t\":\"viewport\",\"rows\":3,\"scroll\":10}")
(let ((ds (tick *d*)))
  (ok "a smaller viewport means a smaller working set, and the surplus is :gone"
      (and (= 3 (length (consumer-visible *d*)))
           (plusp (count :gone (kinds ds)))))
  (ok "and the slice is where the browser said it was"
      (equal '("k10" "k11" "k12") (mapcar #'p-key (consumer-visible *d*)))))
(on-message *d* "{\"t\":\"gesture\",\"g\":\"two-finger\",\"dy\":-2}")
(ok "two-finger is pan — in ROWS, because that is this consumer's axis"
    (= 8 (consumer-scroll-y *d*)))
(on-message *d* "{\"t\":\"gesture\",\"g\":\"two-finger\",\"dy\":9999}")
(ok "and it clamps to this consumer's own content and its own viewport"
    (= 17 (consumer-scroll-y *d*)))
(on-message *d* "{\"t\":\"viewport\",\"rows\":6,\"scroll\":0}")
(tick *d*)

;;; ---- 7. input is a key and a gesture, never a coordinate --------------------

(format t "~&== a browser sends back the key it already holds ==~%")
(on-message *d* "{\"t\":\"gesture\",\"g\":\"tap\",\"key\":\"k02\"}")
(ok "tap invoked the declared safe default" (equal '(:inspected "k02") (consumer-last-result *d*)))
(ok "and selected the row it landed on" (equal "k02" (consumer-selected *d*)))
(let* ((f (progn (tick *d*) (jframe *d*)))
       (d (first (jdeltas f))))
  (ok "the selection travels as view state, not folded into the shared content"
      (and (equal "changed" (json-get d "k")) (equal "k02" (json-get d "key"))
           (eq t (json-get (json-get d "state") "selected"))
           (equal '("k02" "expires 20" "ok") (json-get d "cells")))))
(ok "a tap on a key this consumer cannot see does nothing at all"
    (progn (on-message *d* "{\"t\":\"gesture\",\"g\":\"tap\",\"key\":\"k19\"}")
           (equal "k02" (consumer-selected *d*))))

(format t "~&== hold opens the menu, and menu items are presentations like any other ==~%")
(on-message *d* "{\"t\":\"gesture\",\"g\":\"hold\",\"key\":\"k03\"}")
(let ((ds (tick *d*)))
  (ok "its items arrive as ordinary :appeared deltas" (= 3 (count :appeared (kinds ds))))
  (ok "parented on the row that was held, in order"
      (let ((items (remove 'menu-item (consumer-visible *d*) :key #'p-type :test-not #'eq)))
        (and (= 3 (length items))
             (every (lambda (p) (equal "menu:k03" (car (p-extent p)))) items)
             (null (cdr (p-extent (first items))))
             (equal (p-key (first items)) (cdr (p-extent (second items))))))))
(let* ((f (jframe *d*))
       (mi (find "menu:k03" (jdeltas f) :key (lambda (x) (json-get x "in")) :test #'equal)))
  (format t "     ~a~%" (to-json mi))
  (ok "and a menu item's cells carry its label, its cost class and whether it is destructive"
      (= 3 (length (json-get mi "cells")))))

(format t "~&== hold-drag-release decomposes: the release lands on a menu item ==~%")
(let ((rev (find-if (lambda (p) (and (eq 'menu-item (p-type p))
                                     (eq :command (mi-kind (p-object p)))
                                     (cmd-destructive (mi-command (p-object p)))))
                    (consumer-visible *d*))))
  (setf (consumer-last-result *d*) nil)
  (on-message *d* (format nil "{\"t\":\"gesture\",\"g\":\"tap\",\"key\":\"~a\"}" (p-key rev)))
  (ok "tapping a destructive item confirms rather than acting" (null (consumer-last-result *d*)))
  (ok "and the menu became a confirmation"
      (let ((items (getf (consumer-menu *d*) :items)))
        (and (= 2 (length items)) (eq :confirm (mi-kind (first items)))))))
(tick *d*)
(let ((cf (find-if (lambda (p) (and (eq 'menu-item (p-type p)) (eq :confirm (mi-kind (p-object p)))))
                   (consumer-visible *d*))))
  (on-message *d* (format nil "{\"t\":\"gesture\",\"g\":\"tap\",\"key\":\"~a\"}" (p-key cf)))
  (ok "confirming runs it" (equal '(:revoked "k03") (consumer-last-result *d*)))
  (ok "and the menu closed" (null (consumer-menu *d*))))
(ok "closing emits :gone for exactly its items" (= 2 (count :gone (kinds (tick *d*)))))

;;; ---- 8. rule 6: the menu was courtesy; invocation is the enforcement point ---

(format t "~&== a client that sends a command it was never offered is still refused ==~%")
(tick *phone*)
(setf (consumer-last-result *phone*) nil)
(let ((*error-output* (make-broadcast-stream)))
  (multiple-value-bind (kind detail)
      (on-message *phone* "{\"t\":\"cmd\",\"name\":\"revoke-enrolment\",\"key\":\"k00\",\"confirmed\":true}")
    (declare (ignore detail))
    (ok "the guest's direct invocation reached the enforcement point" (eq :invoked kind))))
(ok "and was refused there, not filtered out of a menu"
    (eq :refused (first (consumer-last-result *phone*))))
(ok "the guest's menu never listed it either — courtesy, and it agreed"
    (notany #'cmd-destructive (applicable-commands 'enrolment :invoker :device)))
(setf (consumer-last-result *d*) nil)
(let ((*error-output* (make-broadcast-stream)))
  (on-message *d* "{\"t\":\"cmd\",\"name\":\"revoke-enrolment\",\"key\":\"k04\",\"confirmed\":true}"))
(ok "the owner, over the same projection at the same instant, may"
    (equal '(:revoked "k04") (consumer-last-result *d*)))
(ok "and the refusal did not leak into the other consumer's state"
    (eq :refused (first (consumer-last-result *phone*))))
(ok "a command naming something that was never declared is simply not run"
    (multiple-value-bind (kind)
        (on-message *d* "{\"t\":\"cmd\",\"name\":\"rm-rf\",\"key\":\"k04\"}")
      (eq :refused kind)))
(ok "and neither is a malformed message"
    (eq :ignored (on-message *d* "{ not json at all")))

;;; ---- 9. one query, two consumers, and the projection holds no place at all ---

(format t "~&== the shared half is untouched by any of this ==~%")
(let ((q0 *queries*))
  (tick-all *proj*)
  (ok "a round of two consumers costs ONE query between them" (= 1 (- *queries* q0))))
(ok "the projection holds domain objects, with no position of any kind on them"
    (let ((os (projection-objects *proj*)))
      (and (= 20 (length os)) (every (lambda (o) (typep o 'enrolment)) os)
           (notany (lambda (o) (typep o 'presentation)) os))))
(ok "and the two consumers' own working sets differ, over that one query"
    (not (equal (mapcar #'p-key (consumer-visible *d*))
                (mapcar #'p-key (consumer-visible *phone*)))))

(format t "~&== a flat app's frame is exactly the frame it always was ==~%")
;;; The regression the multiplex and the nesting both have to survive: a consumer that names no app
;;; and no containers of its own puts NO extra field on the wire.  Asserted on the frame's TEXT,
;;; because the claim is about bytes: `a` and `cs` are absent, not empty, and the frame still opens
;;; with the generation it has always opened with.
(let ((f (progn (scroll-to *d* 0) (tick *d*) (jframe *d*))))
  (ok "no app label on it" (null (json-get f "a")))
  (ok "no container list on it" (null (json-get f "cs")))
  (ok "and this consumer names no containers of its own — only the encoding's `rows`"
      (null (warp-dom::app-containers *d*))))
(ok "the frame's text still begins with the generation and nothing else"
    (let ((s (frame-for *d* '())))
      (and (eql 0 (search "{\"gen\":" s)) (null (search "\"a\":" s)) (null (search "\"cs\":" s)))))

;;; And the other half of the same regression: the key a client sends back is the key it was GIVEN,
;;; which is a STRING because JSON has no conses.  A flat client never noticed because its keys were
;;; strings already; a nesting one whose key is (column . entry) resolved every gesture to NIL.
(ok "a key that is not a string round-trips through the wire's PRINC and back"
    (let* ((p (first (consumer-visible *d*)))
           (k (princ-to-string (p-key p))))
      (eq p (warp-dom::%visible-by-key *d* k))))

(format t "~&== and still no glass, after all of that ==~%")
(ok "the GLASS package still does not exist" (null (find-package "GLASS")))
(ok "and neither does WARP-GLASS" (null (find-package "WARP-GLASS")))

(format t "~&~:[~a TEST(S) FAILED~;ALL TESTS PASSED~]~%" (zerop *fails*) *fails*)
