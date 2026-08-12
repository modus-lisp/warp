;;;; t/nochange.lisp — a 40-step scripted session, dumped one line per step, so a refactor can be
;;;; proved to have changed nothing.
;;;;
;;;; DESIGN.md, rule 8's "Doing it", names this method and says glass ran it twice in one week:
;;;;
;;;;   > copy-on-write defaults plus a no-change proof — a scripted session dumped as (damage box,
;;;;   > hint, hash of every pixel) per step, compared line for line against the previous build.
;;;;
;;;; It has been the method and not a file.  This is the file.  It is worth having as one because
;;;; every change to this codebase so far has been of the shape "move a boundary and keep the old
;;;; behaviour", and the assertion suites do not catch a regression they were not written to expect
;;;; — they check the claims somebody thought to make.  A per-step dump checks the claims nobody
;;;; thought to make, which is where these regressions actually live.
;;;;
;;;; BOTH ENCODINGS, ONE SESSION, because a change to core can move one and not the other and a
;;;; proof over either alone would miss it.  Per step the line carries:
;;;;
;;;;   glass   the delta kinds, their keys, their grid-snapped extents, and an FNV-1a hash of
;;;;           EVERY PIXEL of the framebuffer — the only check that catches a painting change the
;;;;           delta stream cannot see
;;;;   dom     the frame's byte count and its deltas as they would go on a link, verbatim
;;;;
;;;; Usage:
;;;;     sbcl --non-interactive --load t/nochange.lisp > /tmp/session.txt
;;;;     diff /tmp/session-before.txt /tmp/session-after.txt
;;;;
;;;; The session must be DETERMINISTIC or the diff is noise, so: a fixed fixture (no files, no
;;;; wall clock in any fingerprint — the enrolments are all lapsed, which makes PRESENT a pure
;;;; function of the row), a frozen AS-OF, and no threads.

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream)))
    (asdf:load-system :warp-monitor)
    (asdf:load-system :warp-glass)
    (asdf:load-system :warp-dom)))

(defpackage #:warp-nochange (:use #:cl)) (in-package #:warp-nochange)

;; nothing in this session reads or writes an enrolment file, but REVOKE-TERMINAL's handler names
;; one unconditionally, so point it at /tmp before anything can call it
(setf warp-monitor::*devices-file* "/tmp/warp-nochange-devices")

;;; ---- a frozen clock ------------------------------------------------------------------
;;; AS-OF travels on every presentation, so a live clock would put a different number in every
;;; line of the dump and the diff would be 100% noise.  Freezing it is the whole reason this file
;;; can be compared at all.

(defconstant +frozen+ 1750000000)
(defun warp::now-tick () +frozen+)

;;; ---- the fixture ---------------------------------------------------------------------
;;; Twelve stats and four LAPSED enrolments.  Lapsed on purpose: PRESENT for a live enrolment
;;; computes hours remaining from the wall clock, which is exactly the kind of thing that makes a
;;; dump differ between two runs a second apart.

(defvar *value* 0)
(defvar *extra* nil)
(defvar *rows*
  (append (loop for i below 4
                collect (make-instance 'warp-monitor::enrolment
                                       :pubkey (format nil "aa~2,'0d~a" i "bbccddeeff00")
                                       :expires 0))
          (loop for i below 12
                collect (make-instance 'warp-monitor::stat
                                       :name (format nil "stat~2,'0d" i)
                                       :value (format nil "~d" i)
                                       :trend (cond ((= i 3) :warn) ((= i 9) :bad) (t :ok))))))

(defun rows-fn ()
  (let ((rs (copy-list *rows*)))
    ;; one stat carries a mutable value, so a step can change one row and nothing else
    (setf (slot-value (nth 6 rs) 'warp-monitor::value) (format nil "~d" *value*))
    (if *extra* (append rs (list *extra*)) rs)))

(defvar *proj* (warp:make-projection #'rows-fn :type-fn #'warp-monitor:row-type))
(defvar *view* 'warp-monitor::monitor-view)

;;; ---- the two seats -------------------------------------------------------------------
;;; A framebuffer at a generous budget and a browser at a tight one, so the dump covers a pass
;;; that fits and a pass that defers.

(defvar *fb* (warp-glass:attach *proj* :fb (glass:make-framebuffer 480 448 warp-glass:+bg+)
                                       :view *view* :budget 100000 :invoker :allowlist))
(defvar *dom* (warp-dom:attach-dom *proj* :view *view* :rows 12 :budget 900 :invoker :device))

(defun fb-hash ()
  "FNV-1a over every pixel.  A delta stream can be identical while the painting changed."
  (let ((h 14695981039346656037) (px (glass:fb-pixels (warp-glass:consumer-fb *fb*))))
    (dotimes (i (length px) h)
      (setf h (ldb (byte 64 0) (* (logxor h (aref px i)) 1099511628211))))))

(defun fb-line (deltas)
  (format nil "~{~a~^ ~}"
          (mapcar (lambda (d)
                    (let ((e (warp:delta-extent d)))
                      (format nil "~(~a~):~a@~a"
                              (warp:delta-kind d) (warp:delta-key d)
                              (if e (format nil "~a,~a,~a,~a"
                                            (warp::extent-x e) (warp::extent-y e)
                                            (warp::extent-w e) (warp::extent-h e))
                                  "-"))))
                  deltas)))

(defvar *step* 0)
(defun step! (caption)
  (incf *step*)
  (let* ((fd (warp-glass:tick *fb*))
         (dd (warp:tick *dom*))
         (frames (warp-dom:take-frames *dom*)))
    (format t "~&~3,'0d ~24a~%" *step* caption)
    (format t "    glass  n=~2d hash=~16,'0x ~a~%" (length fd) (fb-hash) (fb-line fd))
    (format t "    dom    n=~2d def=~4d bytes=~5d~%" (length dd) (warp:consumer-deferred *dom*)
            (reduce #'+ (mapcar #'length frames) :initial-value 0))
    (dolist (f frames) (format t "      ~a~%" f))))

;;; ---- the session: 40 steps ------------------------------------------------------------
;;; Every kind of thing this protocol does, in an order that makes each one land on top of the
;;; previous one's state rather than on a clean slate.

(format t "~&== warp no-change session, 40 steps, frozen clock ==~%")

;; 1-6  first fill, and the tight seat converging under its budget with nothing new arriving
(step! "first paint")
(dotimes (i 5) (step! "idle drain"))

;; 7    genuinely idle: both seats owe nothing
(step! "idle")

;; 8-9  one row changes, twice — coalescing has nothing to coalesce at this rate
(setf *value* 1) (step! "one row changed")
(setf *value* 2) (step! "same row again")

;; 10-11 three changes between passes: the consumer is told the LATEST state ONCE
(setf *value* 3) (setf *value* 4) (setf *value* 5) (step! "three changes, one delta")
(step! "idle after coalesce")

;; 12-17 scroll, one row at a time, in each consumer's OWN unit
(dotimes (i 3)
  (warp-glass:scroll-by *fb* 32) (warp:scroll-by *dom* 1)
  (step! (format nil "scroll ~a" (1+ i))))
(dotimes (i 3)
  (warp-glass:scroll-by *fb* -32) (warp:scroll-by *dom* -1)
  (step! (format nil "scroll back ~a" (1+ i))))

;; 18-21 selection: view state is a presentation too, and it is PER CONSUMER
(setf (warp:consumer-selected *fb*) "stat00")
(step! "fb selects a row")
(step! "and the dom seat is unmoved")
(setf (warp:consumer-selected *dom*) "stat01")
(step! "dom selects another")
(setf (warp:consumer-selected *fb*) nil (warp:consumer-selected *dom*) nil)
(step! "both deselect")

;; 22-25 the hold menu, opened and closed on each seat independently
(warp:open-menu *fb* (first (warp:consumer-visible *fb*))
                (warp:applicable-commands 'warp-monitor::enrolment :invoker :allowlist))
(step! "fb opens a menu")
(warp:close-menu *fb*)
(step! "fb closes it")
(warp:open-menu *dom* (first (warp:consumer-visible *dom*))
                (warp:applicable-commands 'warp-monitor::enrolment :invoker :device))
(step! "dom opens a guest menu")
(warp:close-menu *dom*)
(step! "dom closes it")

;; 26-29 a row leaves and comes back — :gone / :appeared, and the repair after it
(setf *extra* (make-instance 'warp-monitor::stat :name "zz-new" :value "1" :trend :ok))
(step! "a row appears at the end")
(step! "idle")
(setf *extra* nil)
(step! "and leaves again")
(step! "idle")

;; 30-33 a re-sort: keys survive, positions do not.  This is the case NIL extents would have made
;; silent, and the case :moved was designed for.
(setf *rows* (reverse *rows*))
(step! "the result set re-sorts")
(step! "settling")
(setf *rows* (reverse *rows*))
(step! "and sorts back")
(step! "settling")

;; 34-36 the browser renegotiates its own slice — the consumer-negotiated case
(warp-dom:on-message *dom* "{\"t\":\"viewport\",\"rows\":4,\"scroll\":0}")
(step! "browser reports 4 rows")
(warp-dom:on-message *dom* "{\"t\":\"viewport\",\"rows\":12,\"scroll\":0}")
(step! "and 12 again")
(step! "idle")

;; 37-38 resync: forget what this seat holds, re-announce at a new generation
(warp:resync *dom*)
(step! "dom resync")
(step! "settling")

;; 39-40 a late joiner over the same projection, and the seats already there told nothing
(defvar *late* (warp-dom:attach-dom *proj* :view *view* :rows 6 :budget 100000
                                           :invoker :allowlist))
(step! "a third consumer attaches")
(let ((d (warp:tick *late*)))
  (format t "    late   n=~2d gen=~a~%" (length d)
          (warp-dom::ds-generation (warp:consumer-stream *late*))))
(step! "and nobody else was told")

(format t "~&== queries: ~a for ~a steps of ~a consumers ==~%"
        (warp:projection-queries *proj*) *step* (length (warp:projection-consumers *proj*)))
