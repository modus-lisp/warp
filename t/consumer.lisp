;;;; t/consumer.lisp — two seats, one projection.  DESIGN.md rule 8.
;;;;
;;;; Every assertion here is over a case the single-consumer code could not reach, and the ones that
;;;; matter are correctness rather than economy.  STREAM is a consumer's MEMORY of what it has been
;;;; told; two consumers sharing one would each be told half of every change, and the bug would look
;;;; like working code because the delta was emitted exactly once as designed.  So: does a change
;;;; reach BOTH seats, does a slow link defer and drain without a fast one dragging it, does a late
;;;; joiner start empty, and does one seat's finger stay out of the other's view?

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream)))
    (asdf:load-system :warp-monitor) (asdf:load-system :warp-glass)))
(defpackage #:wct (:use #:cl)) (in-package #:wct)

;; revoke rewrites the enrolment file; keep the real one out of it
(setf warp-monitor::*devices-file* "/tmp/warp-consumer-test-devices")

(defvar *fails* 0)
(defun ok (n p) (format t "~&  ~:[FAIL~;ok  ~] ~a~%" p n) (unless p (incf *fails*)))
(defun kinds (ds) (mapcar #'warp:delta-kind ds))
(defun fb () (glass:make-framebuffer 480 448 warp-glass:+bg+))
(defun digest (c)
  "FNV-1a over every pixel of this consumer's framebuffer."
  (let ((h 14695981039346656037) (px (glass:fb-pixels (warp-glass:consumer-fb c))))
    (dotimes (i (length px) h)
      (setf h (ldb (byte 64 0) (* (logxor h (aref px i)) 1099511628211))))))
(defun memory (c)
  "What this consumer is believed to hold: key -> (fingerprint extent state)."
  (let ((out '()))
    (maphash (lambda (k p) (push (list k (warp:p-fingerprint p) (warp:p-extent p) (warp:p-state p))
                                 out))
             (warp::ds-delivered (warp-glass:consumer-stream c)))
    (sort out #'string< :key (lambda (r) (princ-to-string (first r))))))

;;; ---- the projection: one result-set, deliberately deterministic -------------
;;; Two lapsed enrolments (so PRESENT is a pure function of the fixture, not of the wall clock)
;;; followed by twelve stats.  14 rows x 480x32 = 60 macroblocks each.

(defvar *queries* 0)
(defvar *value* 0)
(defun rows ()
  (append (list (make-instance 'warp-monitor::enrolment :pubkey "aa11bb22cc33" :expires 0)
                (make-instance 'warp-monitor::enrolment :pubkey "dd33ee44ff55" :expires 0))
          (loop for i below 12
                collect (make-instance 'warp-monitor::stat
                                       :name (format nil "stat~2,'0d" i)
                                       :value (format nil "~d" (if (= i 4) *value* i))
                                       :trend :ok))))
(defun rows-fn ()
  (incf *queries*)
  (let ((tick (warp:now-tick)) (i -1))
    (mapcar (lambda (o)
              (incf i)
              (let ((type (warp-monitor:row-type o)))
                (warp:make-presentation
                 :key (warp:presentation-key type o) :type type :object o
                 :extent (warp:snap-extent 0 (* i 32) 480 32)
                 :fingerprint (warp:present o type 'warp-monitor::monitor-view)
                 :as-of tick)))
            (rows))))

(defvar *proj* (warp-glass:make-projection #'rows-fn :view 'warp-monitor::monitor-view))
;; A owns the box and has the desktop's link; B is a guest on a phone, at a fifth of the budget.
(defvar *a* (warp-glass:attach *proj* :fb (fb) :budget 100000 :invoker :allowlist))
(defvar *b* (warp-glass:attach *proj* :fb (fb) :budget 120     :invoker :device))

(format t "~&== one projection, N seats, ONE query per round ==~%")
(let ((q0 *queries*))
  (warp-glass:tick *a*) (warp-glass:tick *b*)
  (ok "two consumers ticking a round ran the query once" (= 1 (- *queries* q0)))
  (ok "and the projection counted it once too" (= 1 (warp-glass:projection-queries *proj*))))
(let ((q0 *queries*))
  (dotimes (i 5) (warp-glass:tick-all *proj*))
  (ok "five rounds of two seats = five queries, not ten" (= 5 (- *queries* q0))))
(let* ((solo (warp-glass:make-surface :fb (fb) :view 'warp-monitor::monitor-view
                                      :rows-fn #'rows-fn))
       (q0 *queries*))
  (dotimes (i 5) (warp-glass:tick solo))
  (ok "a lone consumer still queries once per tick — the same path, not an equivalent one"
      (= 5 (- *queries* q0))))

(format t "~&== different budgets: the slow seat defers and drains, the fast one does not wait ==~%")
;; A had budget for all 14 rows in its first pass; B could afford two per pass.
(ok "the fast seat was complete after one pass" (= 14 (warp-glass:consumer-emitted *a*)))
(ok "the fast seat is idle now" (null (warp-glass:tick *a*)))
(ok "the slow seat is still owed rows" (plusp (warp::ds-pending-count
                                               (warp-glass:consumer-stream *b*))))
(format t "     after ~a rounds: A emitted ~a, deferred ~a | B emitted ~a, deferred ~a~%"
        (warp-glass:consumer-passes *a*) (warp-glass:consumer-emitted *a*)
        (warp-glass:consumer-deferred *a*) (warp-glass:consumer-emitted *b*)
        (warp-glass:consumer-deferred *b*))
(let ((rounds 0))
  ;; drain with NOTHING new arriving — the idle-drain case, now per consumer
  (loop while (plusp (warp-glass:consumer-deferred *b*))
        do (incf rounds) (warp-glass:tick-all *proj*) (when (> rounds 50) (return)))
  (format t "     B drained in ~a further rounds (2 rows per pass at 60 macroblocks a row)~%" rounds)
  (ok "the slow seat converged without new input" (<= rounds 50))
  (ok "and was never told anything twice"
      (= 14 (warp-glass:consumer-emitted *b*))))
(ok "both seats now hold IDENTICAL state" (equal (memory *a*) (memory *b*)))
(ok "and identical pixels, arrived at over different numbers of passes"
    (and (= (digest *a*) (digest *b*))
         (/= (warp-glass:consumer-painted *a*) 0)
         (> (warp-glass:consumer-passes *b*) 1)))

(format t "~&== a change reaches BOTH seats — the bug a shared stream would hide ==~%")
(setf *value* 99)
(let* ((q0 *queries*) (da (warp-glass:tick *a*)) (db (warp-glass:tick *b*)))
  (ok "the seat that ticked first was told" (equal '(:changed) (kinds da)))
  (ok "the seat that ticked second was told the SAME thing, not nothing"
      (and (equal '(:changed) (kinds db))
           (equal (warp:delta-key (first da)) (warp:delta-key (first db)))))
  (ok "and one query served both" (= 1 (- *queries* q0))))
(ok "and they are still identical" (and (equal (memory *a*) (memory *b*))
                                        (= (digest *a*) (digest *b*))))

(format t "~&== a late joiner starts empty and gets a snapshot; nobody else is told anything ==~%")
(defvar *c* (warp-glass:attach *proj* :fb (fb) :budget 240 :invoker :device))
(ok "its memory starts empty, not at somebody else's high-water mark"
    (null (memory *c*)))
(let ((ea (warp-glass:consumer-emitted *a*)) (eb (warp-glass:consumer-emitted *b*))
      (q0 *queries*))
  (let ((dc (warp-glass:tick *c*)) (da (warp-glass:tick *a*)) (db (warp-glass:tick *b*)))
    (ok "the joiner is announced the whole working set, all :appeared"
        (and (plusp (length dc)) (every (lambda (k) (eq k :appeared)) (kinds dc))))
    (ok "chunked by its own budget, through the ordinary path"
        (and (= 4 (length dc)) (plusp (warp-glass:consumer-deferred *c*))))
    (ok "the seats already there are told nothing new" (and (null da) (null db)))
    (ok "and the arrival cost one query, shared" (= 1 (- *queries* q0)))
    (ok "their counters did not move" (and (= ea (warp-glass:consumer-emitted *a*))
                                           (= eb (warp-glass:consumer-emitted *b*))))))
(loop repeat 20 while (plusp (warp-glass:consumer-deferred *c*))
      do (warp-glass:tick-all *proj*))
(ok "the joiner converges to exactly what the others hold" (equal (memory *a*) (memory *c*)))

(format t "~&== resync carries a generation, and only for the seat that asked ==~%")
(let ((gb (warp::ds-generation (warp-glass:consumer-stream *b*)))
      (ga (warp::ds-generation (warp-glass:consumer-stream *a*))))
  (let ((d (warp-glass:resync *b*)))
    (ok "the resynced seat re-announces its working set" (every (lambda (k) (eq k :appeared))
                                                                (kinds d)))
    (ok "its generation advanced" (= (1+ gb) (warp::ds-generation
                                              (warp-glass:consumer-stream *b*))))
    (ok "its neighbour's did not, and it was told nothing"
        (and (= ga (warp::ds-generation (warp-glass:consumer-stream *a*)))
             (null (warp-glass:tick *a*)))))
  (loop repeat 20 while (plusp (warp-glass:consumer-deferred *b*))
        do (warp-glass:tick-all *proj*))
  (ok "and it converges back to what everyone else holds" (equal (memory *a*) (memory *b*))))

(format t "~&== two people looking at one list have one list and two selections ==~%")
;; a tap on content selects.  Rows 5 and 8 are stats; A takes one, B the other.
(warp-glass:on-pointer *a* 1 20 (+ 4 (* 5 32)))
(warp-glass:on-pointer *b* 1 20 (+ 4 (* 8 32)))
(ok "the two selections differ" (and (warp-glass:consumer-selected *a*)
                                     (warp-glass:consumer-selected *b*)
                                     (not (equal (warp-glass:consumer-selected *a*)
                                                 (warp-glass:consumer-selected *b*)))))
(let ((da (warp-glass:tick *a*)) (db (warp-glass:tick *b*)))
  (ok "each seat is told its OWN row changed, and only that row"
      (and (equal '(:changed) (kinds da)) (equal '(:changed) (kinds db))
           (equal (warp:delta-key (first da)) (warp-glass:consumer-selected *a*))
           (equal (warp:delta-key (first db)) (warp-glass:consumer-selected *b*))))
  (ok "selection travels as view state on the presentation, not in the shared fingerprint"
      (and (equal '(:selected t) (warp:p-state (warp:delta-presentation (first da))))
           (equal (warp:present (warp:p-object (warp:delta-presentation (first da)))
                                'warp-monitor::stat 'warp-monitor::monitor-view)
                  (warp:p-fingerprint (warp:delta-presentation (first da)))))))
(ok "the projection's own row is untouched — copy-on-write, so the shared half stays shared"
    (every (lambda (p) (null (warp:p-state p))) (warp-glass:projection-rows *proj*)))
(ok "the seats now legitimately DIFFER, and only in their selections"
    (let ((ma (memory *a*)) (mb (memory *b*)))
      (= 2 (length (set-difference ma mb :test #'equal)))))
(ok "a third seat that selected nothing still matches the projection exactly"
    (every (lambda (r) (null (fourth r))) (memory *c*)))

(format t "~&== one seat's menu is not the other's ==~%")
(warp-glass:on-pointer *a* 4 20 10)          ; hold on enrolment row 0
(warp-glass:on-pointer *b* 4 20 42)          ; hold on enrolment row 1
(let ((da (warp-glass:tick *a*)) (db (warp-glass:tick *b*)))
  (ok "each seat is shown its own menu"
      (and (every (lambda (x) (eq 'warp-glass::menu-item
                                  (warp:p-type (warp:delta-presentation x)))) da)
           (every (lambda (x) (eq 'warp-glass::menu-item
                                  (warp:p-type (warp:delta-presentation x)))) db)))
  (ok "over different rows, so at different extents"
      (not (equal (mapcar #'warp:delta-extent da) (mapcar #'warp:delta-extent db))))
  (ok "and neither was told about the other's"
      (and (null (warp-glass:consumer-menu *c*)) (null (warp-glass:tick *c*)))))

(format t "~&== INVOKER is per seat: the owner and the guest are offered different commands ==~%")
(let* ((ia (mapcar (lambda (it) (first (warp:present it 'warp-glass::menu-item 'v)))
                   (getf (warp-glass:consumer-menu *a*) :items)))
       (ib (mapcar (lambda (it) (first (warp:present it 'warp-glass::menu-item 'v)))
                   (getf (warp-glass:consumer-menu *b*) :items))))
  (format t "     owner: ~{~a~^, ~}~%     guest: ~{~a~^, ~}~%" ia ib)
  (ok "the owner is offered revoke" (member "revoke" ia :test #'string=))
  (ok "the guest, over the same list and the same type, is not"
      (and (member "inspect" ib :test #'string=) (not (member "revoke" ib :test #'string=)))))

(format t "~&== but the menu is still only courtesy: invocation is the enforcement point ==~%")
(setf (warp-glass:consumer-last-result *b*) nil)
(warp-glass::run-command *b* (warp:find-command 'warp-monitor::revoke-terminal)
                         (first (rows)) :confirmed t)
(ok "the guest invoking revoke directly — bypassing the menu it was never shown — is refused"
    (eq :refused (first (warp-glass:consumer-last-result *b*))))
(setf (warp-glass:consumer-last-result *a*) nil)
(warp-glass::run-command *a* (warp:find-command 'warp-monitor::revoke-terminal)
                         (first (rows)) :confirmed t)
(ok "and the owner, at the same instant over the same projection, may"
    (eq :revoked (first (warp-glass:consumer-last-result *a*))))
(ok "the refusal did not leak into the other seat's state"
    (null (warp-glass:consumer-last-result *c*)))

(format t "~&~:[~a TEST(S) FAILED~;ALL TESTS PASSED~]~%" (zerop *fails*) *fails*)
