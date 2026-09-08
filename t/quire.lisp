;;;; t/quire.lisp — client four, and the three things it is built to measure.
;;;;
;;;; This is not a screenshot test.  Each section asserts a NUMBER the protocol should produce
;;;; and is written so it can fail:
;;;;
;;;;   1. CELL WIDTH.  Six row kinds, two of them n-ary.  The assertion is that the widest row
;;;;      is wider than three cells, which is the claim that the reference client's
;;;;      "sniff cells[2]" convention cannot express this client at any width.
;;;;   2. AUTHORED PARTS ARE FREE.  A quiet pass over a document that is half prose must emit
;;;;      ZERO deltas.  If a prose row ever moves on a quiet pass, the fingerprint is not a
;;;;      pure function of its content and every consumer pays for it forever.
;;;;   3. A DRILL IS A SHAPE CHANGE, SCOPED.  Drilling one part must produce gone/appeared in
;;;;      that part's container and NOTHING in any other part -- the nesting claim that
;;;;      warp-files first exercised, now with authored content interleaved between the parts.
;;;;
;;;; Run:  sbcl --non-interactive --load t/quire.lisp

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream)))
    (asdf:load-system :warp-quire/dom)))

(defpackage #:warp-quire-test (:use #:cl #:warp #:warp-quire)) (in-package #:warp-quire-test)

(defvar *fails* 0)
(defun ok (n p &optional detail)
  "DETAIL is printed with the name — a check that fails on a number should say which number,
or the reader has to reconstruct it from the source."
  (format t "~&  ~:[FAIL~;ok  ~] ~a~@[   ~a~]~%" p n detail)
  (unless p (incf *fails*)))

(defun make-seat (proj)
  (warp-quire-dom:attach-dom proj :rows 200 :budget 1000000))

;;; TICK returns the deltas it landed.  Working with the structs rather than the encoded frame
;;; is deliberate: the assertions here are about the PROTOCOL (how many kinds, how wide, which
;;; container), and routing them through JSON would test the encoder as well and make a failure
;;; ambiguous about which half was wrong.
(defun pass (seat) (warp:tick seat))
(defun d-kind (d) (string-downcase (symbol-name (warp::delta-kind d))))
(defun d-type (d) (let ((p (warp::delta-presentation d)))
                    (and p (string-downcase (symbol-name (warp::p-type p))))))
(defun d-cells (d) (let ((p (warp::delta-presentation d))) (and p (warp::p-fingerprint p))))
(defun d-container (d)
  (let* ((p (warp::delta-presentation d))
         (e (or (and p (warp::p-extent p)) (warp::delta-extent d))))
    (if (consp e) (car e) "?")))

;;; ================================================================================
(format t "~&~%== quire: a compound document over a cube ==~%")

(defparameter *doc* (example-document))
(defparameter *proj* (quire-projection *doc*))
(defparameter *seat* (make-seat *proj*))

;;; ---- 1. the cell-width finding ------------------------------------------------
(format t "~&~%-- 1. six row kinds, and the width the old convention cannot hold --~%")

(let* ((ds (pass *seat*))
       (widths (mapcar (lambda (d) (length (d-cells d))) ds))
       (types (remove-duplicates (mapcar #'d-type ds) :test #'equal))
       (widest (reduce #'max widths :initial-value 0)))
  (format t "     row kinds on the wire : ~{~a~^ ~}~%" (sort (copy-list types) #'string<))
  (format t "     cell widths seen      : ~{~a~^ ~}~%"
          (sort (remove-duplicates widths) #'<))
  ;; FIVE, not six: the crumb row does not exist until there is a drill path, which is the
  ;; correct behaviour and was my assertion that was wrong.  A row that exists only to say
  ;; "you are at the top" is a row the budget pays for on every pass of every document.
  (ok "five row kinds before any drill (crumbs appear only with a path)" (= 5 (length types)))
  (ok "the widest row is wider than three cells" (> widest 3))
  (ok "a pivot row carries label + one cell per quarter + total"
      (member 5 widths))                     ; region + Q1 Q2 Q3 + total
  (ok "every delta names its type, so an encoding need not sniff cells"
      (every (lambda (d) (stringp (d-type d))) ds))
  ;; THE DECLARATION IS THE POINT, so assert it resolves rather than that it exists.  This is
  ;; the check that caught a real inconsistency while it was being written: a plain list's head
  ;; row was ONE cell where a pivot's was N -- two shapes wearing one presentation type, which
  ;; the old sniff-the-cells convention would have painted without complaint.
  (ok "every row resolves against its declared widget layout"
      (every (lambda (d)
               (let ((p (warp::delta-presentation d)))
                 (and p (warp:widget-layout (warp::p-type p)
                                            (length (warp::p-fingerprint p))))))
             ds))
  (ok "a pivot row resolves to label + values + total"
      (let ((d (find-if (lambda (d) (= 5 (length (d-cells d)))) ds)))
        (equal '(:label :value :value :value :total)
               (warp:widget-layout (warp::p-type (warp::delta-presentation d)) 5)))))

;;; ---- 2. authored parts cost nothing on a quiet pass ---------------------------
(format t "~&~%-- 2. a quiet pass over a document that is half prose --~%")

(let* ((d2 (pass *seat*)))
  (format t "     deltas on the second pass: ~a~%" (length d2))
  (ok "a quiet pass emits nothing at all" (zerop (length d2))))

;;; ---- 3. a drill is a scoped shape change --------------------------------------
(format t "~&~%-- 3. drilling one part leaves every other part alone --~%")

(let* ((before (document-rows *doc*))
       (target (find-if (lambda (r) (and (typep r 'slice-data-row)
                                         (string= (part-id (row-part r)) "channel")))
                        before)))
  (ok "found a data row in the channel part" (not (null target)))
  ;; RUN-COMMAND takes the CONSUMER first: the invoker is the seat's, so an owner and a guest
  ;; over one projection get different answers (rule 6's enforcement point).
  (warp:run-command *seat* (warp:find-command 'drill-into) target :confirmed t)
  (let* ((ds (pass *seat*))
         (by-container (make-hash-table :test 'equal)))
    (dolist (d ds) (push d (gethash (d-container d) by-container)))
    (format t "     containers touched: ~{~a~^ ~}~%"
            (sort (loop for k being the hash-keys of by-container collect k) #'string<))
    (ok "something changed" (plusp (length ds)))
    ;; TWO containers now, and both belong to the drilled part: its rows changed and a chip
    ;; appeared beside them.  The old assertion named one container and encoded the model where
    ;; the whole path was a single row -- the behaviour is right and the assertion was stale.
    (ok "only the drilled part's containers are touched, and both are its own"
        (every (lambda (k) (or (string= k "part:channel") (string= k "crumbs:channel")))
               (loop for k being the hash-keys of by-container collect k)))
    (ok "no other part moved"
        (notany (lambda (k) (search "pivot" k))
                (loop for k being the hash-keys of by-container collect k)))
    (ok "the change includes rows appearing and going, not just values"
        (and (find "appeared" ds :key #'d-kind :test #'equal)
             (find "gone" ds :key #'d-kind :test #'equal)))))

;;; ---- 4. a chip is a presentation, which is what makes it tappable ---------------
(format t "~&~%-- 4. one chip, one presentation, one key --~%")

(let* ((rows (document-rows *doc*))
       (chips (remove-if-not (lambda (r) (typep r 'crumb-chip)) rows)))
  (ok "a chip appeared once there is a drill path" (plusp (length chips)))
  (ok "each step of the path is its OWN presentation, not a cell in one row"
      (= (length chips)
         (length (slice-filter (part-slice (doc-part *doc* "channel"))))))
  (ok "and each has a distinct key, which is the whole of what makes it tappable"
      (let ((ks (mapcar (lambda (c) (presentation-key 'crumb-chip c)) chips)))
        (= (length ks) (length (remove-duplicates ks :test #'equal)))))
  (ok "chips live in their own container, so the client can lay them in a row"
      (every (lambda (c) (let ((n (row-container c)))
                           (and (>= (length n) 7) (string= "crumbs:" (subseq n 0 7)))))
             chips)))

;;; ---- 5. the thing that was impossible an hour ago -------------------------------
(format t "~&~%-- 5. popping to a chip, which a row of cells could not express --~%")

;; Drill twice more so the path has depth to pop back INTO rather than out of.
(let* ((rows (document-rows *doc*))
       (deeper (find-if (lambda (r) (and (typep r 'slice-data-row)
                                         (string= (part-id (row-part r)) "channel")
                                         (data-drill r)))
                        rows)))
  (when deeper (warp:run-command *seat* (warp:find-command 'drill-into) deeper :confirmed t)))

(let* ((sl (part-slice (doc-part *doc* "channel")))
       (before (length (slice-filter sl)))
       (chips (remove-if-not (lambda (r) (typep r 'crumb-chip)) (document-rows *doc*)))
       (first-chip (find 0 chips :key #'chip-depth)))
  (ok "the path is more than one step deep" (> before 1) before)
  (ok "found the first chip" (not (null first-chip)))
  (warp:run-command *seat* (warp:find-command 'pop-to) first-chip :confirmed t)
  (let ((after (length (slice-filter sl))))
    (ok "tapping the FIRST chip truncated the path to it" (= after 1) (list before '-> after))
    (ok "and kept it rather than undoing it — tapping North means show me North"
        (= 1 (length (slice-filter sl))))))

;;; ================================================================================
(format t "~&~%== ~[all checks passed~:;~:*~d FAILED~] ==~%~%" *fails*)
(sb-ext:exit :code (if (zerop *fails*) 0 1))
