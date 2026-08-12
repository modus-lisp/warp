;;;; demo/two-encodings.lisp — ONE projection, ONE query, TWO encodings at once.
;;;;
;;;; This is what rule 8 has been promising since it was written, asserted rather than narrated: a
;;;; glass/RFB consumer painting macroblocks into a framebuffer AND a DOM consumer serializing JSON
;;;; for a browser, over the same monitor data, in the same round, off one run of the query.
;;;;
;;;; The three numbers that make it a claim rather than a diagram:
;;;;
;;;;   * the QUERY COUNT for the round — one, not two;
;;;;   * each consumer's OWN working set — different rows, different positions, different units;
;;;;   * the shared projection carrying NO extents at all, so neither encoding's geometry could have
;;;;     leaked into the other's.
;;;;
;;;; Then the byte budget biting: a DOM consumer on a small budget deferring, draining to
;;;; convergence with nothing new arriving, and the bytes actually delivered counted.

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream)))
    (asdf:load-system :warp-monitor)
    (asdf:load-system :warp-glass)
    (asdf:load-system :warp-dom)))

(defpackage #:warp-two (:use #:cl)) (in-package #:warp-two)
(setf warp-monitor::*devices-file* "/tmp/warp-two-encodings-devices")

(defvar *fails* 0)
(defun ok (n p) (format t "~&  ~:[FAIL~;ok  ~] ~a~%" p n) (unless p (incf *fails*)))
(defun kinds (ds) (mapcar #'warp:delta-kind ds))

;;; ---- the projection: the QUERY, and nothing about how anyone looks at it ------
;;; Deterministic on purpose — PRESENT must be a pure function of the fixture, so the numbers below
;;; are the protocol's and not the wall clock's.

(defvar *queries* 0)
(defvar *value* 0)
(defun rows ()
  (append (list (make-instance 'warp-monitor::enrolment :pubkey "aa11bb22cc33" :expires 0)
                (make-instance 'warp-monitor::enrolment :pubkey "dd33ee44ff55" :expires 0))
          (loop for i below 18
                collect (make-instance 'warp-monitor::stat
                                       :name (format nil "stat~2,'0d" i)
                                       :value (format nil "~d" (if (= i 4) *value* i))
                                       :trend :ok))))
(defun rows-fn () (incf *queries*) (rows))

(defvar *proj* (warp:make-projection #'rows-fn :type-fn #'warp-monitor:row-type))
(defvar *view* 'warp-monitor::monitor-view)

;;; ---- two consumers, two encodings, one projection ----------------------------

(defvar *fb* (glass:make-framebuffer 480 448 warp-glass:+bg+))
(defvar *pixels*  (warp-glass:attach *proj* :fb *fb* :view *view*
                                     :budget 100000 :invoker :allowlist))
;; SCROLL-Y at attach rather than SCROLL-TO after it, deliberately: SCROLL-TO clamps against
;; CONTENT-HEIGHT, and before the first PULL the projection has no objects to be the height of.
(defvar *browser* (warp-dom:attach-dom *proj* :view *view* :rows 8 :budget 100000
                                              :invoker :device :scroll-y 6))

(format t "~&== one projection, two encodings, and one query for the round ==~%")
(let ((q0 *queries*))
  (let ((dp (warp-glass:tick *pixels*)) (db (warp-dom:tick *browser*)))
    (ok "the query ran ONCE for both consumers" (= 1 (- *queries* q0)))
    (ok "and the projection counted it once" (= 1 (warp:projection-queries *proj*)))
    (format t "     framebuffer: ~a deltas over ~a rows~%     browser:     ~a deltas over ~a rows~%"
            (length dp) (length (warp:consumer-visible *pixels*))
            (length db) (length (warp:consumer-visible *browser*)))
    (ok "the framebuffer got the slice its 448px window holds, at its own offset"
        (= 14 (length (warp:consumer-visible *pixels*))))
    (ok "the browser got the slice IT said it could show, at ITS own offset"
        (= 8 (length (warp:consumer-visible *browser*))))
    (ok "their working sets are genuinely different rows"
        (not (equal (mapcar #'warp:p-key (warp:consumer-visible *pixels*))
                    (mapcar #'warp:p-key (warp:consumer-visible *browser*)))))

    (format t "~&== the same row, positioned twice, in two vocabularies ==~%")
    (let* ((shared (intersection (mapcar #'warp:p-key (warp:consumer-visible *pixels*))
                                 (mapcar #'warp:p-key (warp:consumer-visible *browser*))
                                 :test #'equal))
           (k (first (sort shared #'string<)))
           (pp (find k (warp:consumer-visible *pixels*) :key #'warp:p-key :test #'equal))
           (pb (find k (warp:consumer-visible *browser*) :key #'warp:p-key :test #'equal)))
      (format t "     ~a~%       framebuffer extent ~a~%       browser position   ~a~%"
              k (warp:p-extent pp) (warp:p-extent pb))
      (ok "the framebuffer's position is a grid-snapped rectangle (rule 3)"
          (and (warp:rect-p (warp:p-extent pp))
               (zerop (mod (warp::extent-y (warp:p-extent pp)) warp:+grid+))
               (zerop (mod (warp::extent-h (warp:p-extent pp)) warp:+grid+))))
      (ok "the browser's is (parent . after) — no rectangle, and no 16px grid anywhere near it"
          (and (consp (warp:p-extent pb)) (not (warp:rect-p (warp:p-extent pb)))
               (equal "rows" (car (warp:p-extent pb)))))
      (ok "and they agree on the only two things that are the projection's: key and content"
          (and (equal (warp:p-key pp) (warp:p-key pb))
               (equal (warp:p-fingerprint pp) (warp:p-fingerprint pb)))))

    (format t "~&== the shared half carries no picture of anything ==~%")
    (ok "the projection holds domain objects, never presentations"
        (notany (lambda (o) (typep o 'warp:presentation)) (warp:projection-objects *proj*)))
    (ok "so there is no extent on it for either encoding to have leaked into"
        (every (lambda (o) (or (typep o 'warp-monitor::stat) (typep o 'warp-monitor::enrolment)))
               (warp:projection-objects *proj*)))
    (ok "and neither consumer's rows are the projection's objects"
        (and (notany (lambda (p) (member p (warp:projection-objects *proj*)))
                     (warp:consumer-visible *pixels*))
             (notany (lambda (p) (member p (warp:projection-objects *proj*)))
                     (warp:consumer-visible *browser*))))))

(format t "~&== a change reaches BOTH encodings, off one query, in their own terms ==~%")
(setf *value* 99)
(let* ((q0 *queries*)
       (dp (warp-glass:tick *pixels*)) (db (warp-dom:tick *browser*)))
  (ok "one query served the round" (= 1 (- *queries* q0)))
  (ok "the framebuffer was told, as a rectangle to repaint"
      (and (equal '(:changed) (kinds dp)) (warp:rect-p (warp:delta-extent (first dp)))))
  (ok "the browser was told, as JSON with the same key and no rectangle"
      (and (equal '(:changed) (kinds db))
           (equal (warp:delta-key (first dp)) (warp:delta-key (first db)))))
  (let ((json (first (last (warp-dom:take-frames *browser*)))))
    (format t "     ~a~%" json)
    (ok "and what actually went on the browser's link is that JSON"
        (search "\"k\":\"changed\"" json))))

(format t "~&== one scroll, two encodings: the SAME event, in two vocabularies and two units ==~%")
(warp:scroll-by *pixels* 32)                    ; one row, in pixels — this consumer's axis
(warp:scroll-by *browser* 1)                    ; one row, in rows   — this one's
(let* ((dp (warp-glass:tick *pixels*)) (db (warp-dom:tick *browser*))
       (ap (find :appeared dp :key #'warp:delta-kind))
       (ab (find :appeared db :key #'warp:delta-kind))
       (mb (find :moved db :key #'warp:delta-kind)))
  (format t "     framebuffer: ~{~(~a~)~^ ~}~%     browser:     ~{~(~a~)~^ ~}~%"
          (kinds dp) (kinds db))
  (ok "the framebuffer must translate every surviving row — that is what rule 2 is FOR"
      (= 13 (count :moved (kinds dp))))
  (ok "the browser translates NOTHING: a DOM has no coordinates, so only the anchor changed"
      (= 1 (count :moved (kinds db))))
  (format t "     one new row costs the framebuffer ~a macroblocks, and the browser ~a bytes~%"
          (warp:delta-cost *pixels* ap) (warp:delta-cost *browser* ab))
  (format t "     the browser's whole scroll:  ~a~%" (warp-dom:delta-json mb))
  (ok "the two encodings price the same kind of event in incomparable units, as they should"
      (and (= 60 (warp:delta-cost *pixels* ap)) (> (warp:delta-cost *browser* ab) 60)))
  (ok "and core's default would have priced the browser's delta at a flat 1 — the degeneracy"
      (= 1 (warp:delta-cost nil ab))))

;;; ---- the byte budget, biting -------------------------------------------------

(format t "~&== a byte budget, and what it actually costs to converge ==~%")
;; The control: the same 20 rows, same encoding, no budget at all — one pass, one frame.  That is
;; what the first fill "should" cost, and it is what the budgeted consumer is measured against.
(defvar *unbudgeted* (warp-dom:attach-dom *proj* :view *view* :rows 20 :budget 1000000
                                                 :invoker :device))
(warp-dom:tick *unbudgeted*)
(defvar *one-pass-bytes* (warp-dom:dom-sent-bytes *unbudgeted*))

(defvar *phone* (warp-dom:attach-dom *proj* :view *view* :rows 20 :budget 256 :invoker :device))
(let ((passes 0) (frames '()))
  (loop until (and (plusp passes) (zerop (warp:consumer-deferred *phone*)))
        do (incf passes) (warp-dom:tick *phone*) (when (> passes 60) (return)))
  (setf frames (warp-dom:take-frames *phone*))
  (let* ((per-pass (mapcar (lambda (f)
                             (reduce #'+ (mapcar (lambda (d) (length (warp-dom:to-json d)))
                                                 (warp-dom:json-get (warp-dom:from-json f)
                                                                    "deltas"))))
                           frames))
         (delivered (warp-dom:dom-sent-bytes *phone*)))
    (format t "     budget:              256 bytes of deltas per pass~%")
    (format t "     rows converged:      ~a in ~a passes~%" (warp:consumer-emitted *phone*) passes)
    (format t "     delta bytes/pass:    ~{~a~^ ~}~%" per-pass)
    (format t "     delivered:           ~a bytes over ~a frames~%" delivered (length frames))
    (format t "     the same fill unbudgeted: ~a bytes over 1 frame~%" *one-pass-bytes*)
    (format t "     cost of pacing:      ~a bytes (~,1f%%) — envelopes, not re-sends~%"
            (- delivered *one-pass-bytes*)
            (* 100 (/ (- delivered *one-pass-bytes*) (float *one-pass-bytes*))))
    (ok "no pass ever spent more than the budget on deltas"
        (every (lambda (b) (<= b 256)) per-pass))
    (ok "every pass but the last spent MOST of it — the budget bound it, not the data"
        (every (lambda (b) (> b 128)) (butlast per-pass)))
    (ok "it converged with nothing new arriving — rule 4's idle drain, in bytes"
        (and (< passes 60) (zerop (warp:consumer-deferred *phone*))))
    (ok "and delivered all 20 rows exactly once, never an intermediate"
        (= 20 (warp:consumer-emitted *phone*)))
    ;; THE claim.  Pacing does not cost content, only envelopes: the budgeted consumer and the
    ;; unbudgeted one put the SAME delta bytes on the wire, because deferral is acknowledged-state
    ;; lagging and not a queue.  A budget that duplicated work would show up here as a fat number.
    (ok "pacing cost only the extra frame envelopes — not one byte of content was sent twice"
        (< (- delivered *one-pass-bytes*) (* 30 (1- (length frames)))))
    (ok "and both consumers ended up holding exactly the same thing"
        (equal (sort (mapcar #'warp:p-key (warp:consumer-visible *phone*)) #'string<)
               (sort (mapcar #'warp:p-key (warp:consumer-visible *unbudgeted*)) #'string<)))))

(format t "~&== and the steady state is where a delta protocol earns its keep ==~%")
(warp-dom:take-frames *phone*)
(ok "converged, an idle pass puts nothing at all on the link"
    (progn (warp-dom:tick *phone*) (null (warp-dom:take-frames *phone*))))
(setf *value* 1234)
(let ((before (warp-dom:dom-sent-bytes *phone*)))
  (warp-dom:tick *phone*)
  (let ((cost (- (warp-dom:dom-sent-bytes *phone*) before)))
    (format t "     one row of twenty changed: ~a bytes on the wire, against ~a for a full re-send~%"
            cost *one-pass-bytes*)
    (format t "     ~,1f x~%" (/ *one-pass-bytes* (float cost)))
    (ok "a one-row change costs a small fraction of the working set"
        (< cost (/ *one-pass-bytes* 10)))))

(format t "~&== and every consumer on it still shares one query ==~%")
(let ((q0 *queries*))
  (warp:tick-all *proj*)
  (ok "a whole round — framebuffer, browser, phone, control — costs ONE query"
      (= 1 (- *queries* q0)))
  (ok "four consumers, two encodings, one projection"
      (= 4 (length (warp:projection-consumers *proj*))))
  (ok "and exactly one of them is the one that owns pixels"
      (= 1 (count-if (lambda (c) (typep c 'warp-glass:fb-consumer))
                     (warp:projection-consumers *proj*)))))

(format t "~&~:[~a ASSERTION(S) FAILED~;ALL ASSERTIONS HELD~]~%" (zerop *fails*) *fails*)
