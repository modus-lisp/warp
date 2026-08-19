;;;; app/monitor.lisp — a live monitor for the glass pipeline.  warp's first practical client.
;;;;
;;;; Why this app and not the device manager: we spent a whole session grepping a log file for these
;;;; numbers, so this is something we actually want.  It is also a far better test of the protocol
;;;; than a list of two enrolments that changes once a day —
;;;;
;;;;   * every row changes every few seconds, which exercises coalescing and the budget
;;;;   * rows appear and vanish (sessions, deferred work, expiring terminals)
;;;;   * the numbers are SAMPLED, so as-of is real and staleness is visible rather than theoretical
;;;;   * it has genuine commands at three different cost classes, including a destructive one
;;;;
;;;; And it is honest dogfooding: the monitor is displayed *through* the pipeline it measures, so an
;;;; inefficient projection shows up in its own numbers.
;;;;
;;;; Data comes from files the gateway already writes (/tmp/glass-stats.sexp, .glass-devices) — the
;;;; same file-as-source-of-truth arrangement, so no IPC and any process can read it.

(in-package #:warp-monitor)

;;; ---- the domain ------------------------------------------------------------
;;; Two presentation types.  A stat is a named measurement; an enrolment is a trusted terminal.

(defclass stat ()
  ((name  :initarg :name  :reader stat-name)
   (value :initarg :value :reader stat-value)     ; a string, already formatted
   (trend :initarg :trend :reader stat-trend :initform nil)   ; :ok :warn :bad
   (as-of :initarg :as-of :reader stat-as-of :initform nil)))

(defclass enrolment ()
  ((pubkey  :initarg :pubkey  :reader pubkey)
   (expires :initarg :expires :reader expires)))  ; unix

(define-presentation-key stat (s) (stat-name s))
(define-presentation-key enrolment (e) (pubkey e))

;;; ---- projections -----------------------------------------------------------
;;; Designed rows.  The MOP default would still work and would show every slot with equal weight —
;;; the editorial choice here is that the VALUE leads and the name is secondary, because when you
;;; glance at a monitor you are looking for the number that is wrong.

(defmethod present ((s stat) (type (eql 'stat)) (view (eql 'monitor-view)))
  (list (stat-value s) (stat-name s) (or (stat-trend s) :ok)))

(defmethod present ((e enrolment) (type (eql 'enrolment)) (view (eql 'monitor-view)))
  (let* ((left (- (expires e) (- (get-universal-time) 2208988800)))
         (hrs (/ left 3600.0)))
    (list (if (plusp left)
              (if (< hrs 1) (format nil "~dm" (max 1 (round (* hrs 60)))) (format nil "~,1fh" hrs))
              "lapsed")
          (format nil "terminal ~a" (subseq (pubkey e) 0 8))
          (cond ((not (plusp left)) :bad) ((< hrs 2) :warn) (t :ok)))))

;;; ---- commands, at three real cost classes ----------------------------------

(define-command (inspect-row :arg-type stat :cost :local :label "inspect") (o i)
  (list :inspect (stat-name o)))

(define-command (inspect-terminal :arg-type enrolment :cost :local :label "inspect") (o i)
  (list :inspect (pubkey o)))

(define-command (force-keyframe :arg-type stat :cost :gateway :label "force keyframe") (o i)
  ;; a real, safe, idempotent-ish action: ask the encoder for a fresh keyframe
  (list :force-keyframe (stat-name o)))

(define-command (revoke-terminal :arg-type enrolment :cost :gateway
                                 :destructive t :confirm t :label "revoke") (o i)
  (revoke-in-file (pubkey o))
  (list :revoked (pubkey o)))

;;; policy: written once, here, next to the thing it protects
(define-command-authorization revoke-terminal (invoker) (eq invoker :allowlist))
(define-command-authorization force-keyframe (invoker) (member invoker '(:allowlist :device)))

;;; tap is safe on both types; revoke is hold-menu only, and warp refuses to let it be a default
(define-default-command 'stat 'monitor-view 'inspect-row)
(define-default-command 'enrolment 'monitor-view 'inspect-terminal)

;;; ---- the data source: files the gateway already writes ----------------------

(defparameter *stats-file* "/tmp/glass-stats.sexp")
;; webrtc-data is a sibling checkout of warp's, so resolve it from warp's own
;; root rather than naming an absolute path.
(defparameter *devices-file*
  (asdf:system-relative-pathname
   "warp" "../webrtc-data/demo/glass-webrtc/.glass-devices"))

(defun read-stats ()
  (handler-case
      (with-open-file (s *stats-file* :if-does-not-exist nil)
        (and s (read s nil nil)))
    (error () nil)))

(defun read-devices ()
  (handler-case
      (with-open-file (s *devices-file* :if-does-not-exist nil)
        (when s
          (loop for line = (read-line s nil) while line
                for sp = (position #\Space line)
                when sp collect (make-instance 'enrolment
                                               :pubkey (subseq line 0 sp)
                                               :expires (or (ignore-errors
                                                             (parse-integer (subseq line (1+ sp))))
                                                            0)))))
    (error () nil)))

(defun revoke-in-file (pubkey)
  "Remove an enrolment.  The gateway re-reads the file on mtime change, so this is the whole
implementation — no IPC, and the gateway still enforces its own authorization on invocation."
  (let ((keep (remove pubkey (read-devices) :key #'pubkey :test #'string=)))
    (with-open-file (s *devices-file* :direction :output :if-exists :supersede
                                      :if-does-not-exist :create)
      (dolist (e keep) (format s "~a ~a~%" (pubkey e) (expires e))))
    t))

;;; ---- the query -------------------------------------------------------------
;;; DESIGN.md: views subscribe to RESULT-SETS, not to objects they happen to enumerate.  So this is
;;; a query returning rows, even though its implementation is two file reads.  Time is an input —
;;; quantized to a tick — so a row can lapse and emit a delta without anything else happening.

(defun tri (v lo hi) (cond ((null v) :ok) ((> v hi) :bad) ((> v lo) :warn) (t :ok)))

;;; DISPLAY PRECISION IS A BANDWIDTH DECISION.  Measuring this app taught us the lesson: rendering
;;; "196 KB/s" changes the row on every sample while telling a human nothing new, and since the
;;; fingerprint is the projected content, every sample then costs a delta.  Quantizing to the
;;; precision a glance can actually use makes "unchanged to the eye" mean "unchanged to the
;;; protocol" — the same row, a fraction of the traffic.  It is an editorial choice with a transport
;;; consequence, which is precisely the kind of decision this architecture is meant to surface.
(defun q (v step) (and v (* step (round v step))))
(defun mmm (triple) (if (consp triple) (third triple) nil))     ; the max of (min mean max)

(defun monitor-rows (&key (tick (now-tick)))
  "The current result-set: pipeline stats then trusted terminals."
  (let* ((st (read-stats))
         (v  (getf st :video))
         (rows '()))
    (flet ((row (name value &optional trend)
             (push (make-instance 'stat :name name :value value :trend (or trend :ok) :as-of tick)
                   rows)))
      (if (null v)
          (row "no session" "idle" :warn)
          (progn
            (row "fps"        (format nil "~d" (or (q (getf v :fps) 2) 0)))
            (row "rate"       (format nil "~d KB/s" (or (q (getf v :kbs) 25) 0))
                 (tri (getf v :kbs) (* 0.8 (or (getf st :target-kbs) 150))
                      (or (getf st :target-kbs) 150)))
            ;; the quantizer is discrete and every step is meaningful, so it is NOT quantized
            (row "quantizer"  (format nil "~d" (or (getf v :qi) 0))
                 (tri (getf v :qi) (+ 8 (or (getf st :qi-base) 8)) 30))
            (row "encode max" (format nil "~d ms" (or (q (mmm (getf v :encode-ms)) 20) 0))
                 (tri (mmm (getf v :encode-ms)) 60 120))
            (row "frame max"  (format nil "~d KB" (or (q (mmm (getf v :frame-kb)) 8) 0))
                 (tri (mmm (getf v :frame-kb)) 24 48))
            (row "coded MBs"  (format nil "~d" (or (q (mmm (getf v :coded-mb)) 250) 0)))
            (row "deferred"   (format nil "~d" (or (q (getf v :pending) 100) 0))
                 (tri (getf v :pending) 0 400))
            (row "refinements" (format nil "~d" (or (getf v :cleanups) 0)))))
      ;; connection health, from the same file.  This is the row that matters when the thing is
      ;; broken: a failed session used to be visible only to whoever was tailing the log at that
      ;; instant, which is nobody.
      (let ((ok (getf st :sessions-ok)) (bad (getf st :sessions-failed))
            (norelay (getf st :no-relay)) (err (getf st :last-error)))
        (when (or ok bad)
          (row "sessions" (format nil "~d ok / ~d failed" (or ok 0) (or bad 0))
               (if (and bad (plusp bad)) :warn :ok)))
        (when (and norelay (plusp norelay))
          (row "no relay" (format nil "~d" norelay) :bad))
        (when err (row "last error" (princ-to-string err) :bad)))
      (dolist (e (read-devices)) (push e rows)))
    (nreverse rows)))

(defun row-type (o) (if (typep o 'stat) 'stat 'enrolment))

(defun monitor-presentations (&key (scroll 0) (width 480) (viewport-h 384) (row-h 32))
  "Query and lay out in one call — the fused shape, kept for the headless cost harness, which has no
consumer to lay out for.  A SEAT does not use this: it pulls MONITOR-ROWS from the shared projection
and lays them out itself, at its own scroll offset and its own window size (DESIGN.md rule 8).

Mixed types in one list, each keyed and projected by its own type: LAYOUT-LIST takes ROW-TYPE as its
type argument and asks it per object."
  (let ((tick (now-tick)))
    (layout-list (monitor-rows :tick tick) #'row-type 'monitor-view
                 :width width :viewport-h viewport-h :row-height row-h :scroll-y scroll
                 :as-of tick)))
