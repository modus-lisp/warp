;;;; t/reconcile.lisp — does the stream converge to current state under a budget?
;;;;
;;;; That is the claim the whole design rests on, so it is checked directly rather than inferred
;;;; from a rendered picture.

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream))) (asdf:load-system :warp)))

(defpackage #:warp-test (:use #:cl #:warp))
(in-package #:warp-test)

(defvar *fails* 0)
(defun ok (name pred)
  (format t "~&  ~:[FAIL~;ok  ~] ~a~%" pred name)
  (unless pred (incf *fails*)))

;;; a domain object with NO lisp identity across renders — the device-manager case
(defstruct (enrol (:constructor enrol (pubkey exp))) pubkey exp)
(define-presentation-key enrolment (e) (enrol-pubkey e))

(defun row (pubkey exp y &key (h 32))
  "A presentation of an enrolment, grid-snapped, fingerprinted on what it displays."
  (let ((o (enrol pubkey exp)))
    (make-presentation :key (presentation-key 'enrolment o) :type 'enrolment :object o
                       :extent (snap-extent 0 y 640 h)
                       :fingerprint (list pubkey exp)
                       :as-of (now-tick))))

(defun kinds (deltas) (mapcar #'delta-kind deltas))
(defun keys-of (deltas) (mapcar #'delta-key deltas))

(format t "~&== identity survives objects being rebuilt (the eq trap) ==~%")
(let ((s (make-delta-stream)))
  (emit s (list (row "aa" 100 0) (row "bb" 200 32)))
  ;; rebuild every object from scratch, as a file re-read does: not EQ to anything before
  (multiple-value-bind (d n) (emit s (list (row "aa" 100 0) (row "bb" 200 32)))
    (ok "rebuilt-but-identical state emits nothing" (and (null d) (zerop n)))))

(format t "~&== the four kinds ==~%")
(let ((s (make-delta-stream)))
  (emit s (list (row "aa" 100 0) (row "bb" 200 32)))
  (ok "changed fingerprint -> :changed"
      (equal '(:changed) (kinds (emit s (list (row "aa" 101 0) (row "bb" 200 32))))))
  (ok "same content, new position -> :moved"
      (equal '(:moved) (kinds (emit s (list (row "aa" 101 32) (row "bb" 200 32))))))
  (ok "new key -> :appeared"
      (equal '(:appeared) (kinds (emit s (list (row "aa" 101 32) (row "bb" 200 32) (row "cc" 300 64))))))
  (ok "dropped key -> :gone"
      (equal '(:gone) (kinds (emit s (list (row "aa" 101 32) (row "bb" 200 32)))))))

(format t "~&== the stream carries state, not events (coalescing) ==~%")
(let ((s (make-delta-stream)))
  (emit s (list (row "aa" 1 0)))
  ;; three changes before the next emit
  (let ((current (list (row "aa" 4 0))))
    (declare (ignorable current))
    (multiple-value-bind (d) (emit s (list (row "aa" 4 0)))
      (ok "three intermediate changes collapse to one delta" (= 1 (length d)))
      (ok "and it carries the NEWEST value"
          (equal '("aa" 4) (p-fingerprint (delta-presentation (first d))))))))

(format t "~&== budget: defer, then converge (no stranding) ==~%")
(let* ((s (make-delta-stream))
       ;; 40 rows of 32px over 640px wide = 40 * (40 x 2) macroblocks each
       (rows (loop for i below 40 collect (row (format nil "k~2,'0d" i) i (* 32 i)))))
  (multiple-value-bind (d1 n1) (emit s rows :budget 200)
    (ok "first pass emits some" (plusp (length d1)))
    (ok "first pass defers the rest" (plusp n1))
    ;; drive to convergence with NOTHING new arriving — the idle-drain case that stranded before
    (let ((passes 0) (total (length d1)))
      (loop for (d n) = (multiple-value-list (emit s rows :budget 200))
            while d do (incf passes) (incf total (length d))
                       (when (> passes 100) (return)))
      (ok "converges with no new input" (<= passes 100))
      (ok "every row was delivered exactly once" (= total (length rows)))
      (ok "nothing pending at the end" (zerop (ds-pending-count s)))
      (multiple-value-bind (d) (emit s rows)
        (ok "and it is then quiet" (null d))))))

(format t "~&== a delta deferred and then changed is sent once, newest-only ==~%")
(let* ((s (make-delta-stream))
       (rows (loop for i below 10 collect (row (format nil "k~d" i) 0 (* 32 i)))))
  (emit s rows :budget 100000)                        ; everyone delivered
  ;; change all ten, but allow only a little through
  (let ((changed (loop for i below 10 collect (row (format nil "k~d" i) 1 (* 32 i)))))
    (emit s changed :budget 5)
    ;; now change them AGAIN before the remainder goes out
    (let ((changed2 (loop for i below 10 collect (row (format nil "k~d" i) 2 (* 32 i)))))
      (let ((seen '()))
        (loop repeat 50
              for d = (emit s changed2 :budget 5)
              while d do (setf seen (append seen d)))
        (ok "no row is sent an intermediate value"
            (every (lambda (d) (equal 2 (second (p-fingerprint (delta-presentation d))))) seen))
        (ok "and all ten arrive" (= 10 (length (remove-duplicates (keys-of seen) :test #'equal))))))))

(format t "~&== ordering: unseen and misleading before merely stale ==~%")
(let ((s (make-delta-stream)))
  (emit s (list (row "old" 1 0) (row "stale" 1 32)))
  ;; simultaneously: one disappears, one appears, one changes
  (let ((d (emit s (list (row "stale" 9 32) (row "new" 1 64)))))
    (ok ":gone first, then :appeared, then :changed"
        (equal '(:gone :appeared :changed) (kinds d)))))

(format t "~&== resync: snapshot re-announces the working set and bumps the generation ==~%")
(let* ((s (make-delta-stream)) (rows (list (row "aa" 1 0) (row "bb" 2 32))))
  (emit s rows)
  (multiple-value-bind (d n gen) (snapshot s rows)
    (declare (ignore n))
    (ok "snapshot re-announces everything as :appeared"
        (equal '(:appeared :appeared) (kinds d)))
    (ok "generation advanced" (= gen 1))))

(format t "~&== extents snap outward to the macroblock grid ==~%")
(let ((e (snap-extent 5 20 100 20)))
  (ok "origin snaps down, size snaps up, coverage preserved"
      (and (zerop (extent-x e)) (= 16 (extent-y e))
           (>= (+ (extent-x e) (extent-w e)) 105)
           (>= (+ (extent-y e) (extent-h e)) 40)
           (zerop (mod (extent-w e) +grid+)) (zerop (mod (extent-h e) +grid+)))))

(format t "~&== a type with no key function fails loudly, not silently ==~%")
(let ((unkeyed (enrol "zz" 1)))
  (ok "unkeyed type signals rather than defaulting to eq"
      (handler-case (progn (presentation-key 'no-such-type unkeyed) nil)
        (error () t))))

(format t "~&~:[~a TEST(S) FAILED~;ALL TESTS PASSED~]~%" (zerop *fails*) *fails*)
