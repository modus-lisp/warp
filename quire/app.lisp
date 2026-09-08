;;;; quire/app.lisp — the touch UI: what a tap means on a document that is half prose.
;;;;
;;;; ==================================================================================
;;;; RULE 5's VOCABULARY IS CLOSED, AND THAT IS THE INTERESTING CONSTRAINT
;;;; ==================================================================================
;;;;
;;;; A phone sends tap, hold, or two-finger.  There is no drag, no pinch, no right-click and
;;;; no keyboard, so every affordance this document has must be expressible as "tap a thing"
;;;; or "hold a thing and pick from a menu".  A desktop pivot table would use a drag to move a
;;;; dimension between axes; here that is a menu item on the head row, and the constraint
;;;; produces a better answer than the freedom would have -- the menu says what the axes ARE,
;;;; where a drag target says only where you may drop.
;;;;
;;;; TAP IS NON-DESTRUCTIVE (rule 6), so tap drills and tap-a-chip pops.  Both are navigation
;;;; and both are reversible by another tap, which is what lets them be the DEFAULT command on
;;;; their types.  Nothing here deletes anything; the document is read-only over a cube and the
;;;; only state a gesture touches is the SLICE, which is a value in a part.
;;;;
;;;; A COMMAND EDITS THE QUESTION, NEVER THE ANSWER.  Drilling sets a filter on the slice; the
;;;; next epoch re-runs ROWS-OF and the rows are different rows.  No command here computes a
;;;; result or touches a presentation, which is what keeps the reconciler honest: it sees a
;;;; result-set that changed shape, exactly as it would if the underlying facts had changed.

(in-package #:warp-quire)

;;; ---- drilling ---------------------------------------------------------------------

(define-command (drill-into :arg-type slice-data-row :cost :local :label "drill in")
    (r invoker)
  (declare (ignore invoker))
  (let* ((p (row-part r)) (sl (part-slice p)) (clause (data-drill r)))
    (unless clause
      (error "quire: ~a is already at its finest grain" (data-label r)))
    ;; APPEND, not push: the filter is a PATH and its order is the crumb trail the user reads
    ;; back.  Innermost last, so popping is a truncation.
    (setf (slice-filter sl) (append (slice-filter sl) (list clause)))
    ;; Drilling one level down means the row dimension is spent; move to the next one the cube
    ;; offers that is not already in the path.  A document that named its own drill order would
    ;; be more expressive and is not needed yet -- when it is, this is the seam.
    (let ((next (find-if (lambda (d)
                           (not (assoc (cdr d) (slice-filter sl) :test #'equal)))
                         (cube-dims (doc-cube *document*)))))
      (when next (setf (slice-rows-by sl) (car next))))
    (list :drilled (cdr clause))))

(define-default-command 'slice-data-row 'quire-view 'drill-into)

(define-command (pop-to :arg-type crumb-chip :cost :local :label "back to here")
    (r invoker)
  (declare (ignore invoker))
  ;; POPS TO THIS CHIP, which is what it was always supposed to do and could not while the whole
  ;; path was one presentation: a gesture carries a key and no coordinates, so a row of N cells
  ;; had nothing to send that said WHICH cell.  Each chip is a presentation now and its key names
  ;; its depth, so the pop is a truncation.
  ;;
  ;; TRUNCATE AT the chip's depth, keeping it: tapping "North" means "show me North", not "undo
  ;; North".  The rows dimension goes back to the one that was current when that step was taken,
  ;; which is the dimension AFTER the last surviving clause.
  (let* ((sl (part-slice (row-part r)))
         (keep (subseq (slice-filter sl) 0 (1+ (chip-depth r)))))
    (setf (slice-filter sl) keep)
    (let ((next (find-if (lambda (d) (not (assoc (cdr d) keep :test #'equal)))
                         (cube-dims (doc-cube *document*)))))
      (when next (setf (slice-rows-by sl) (car next))))
    (list :popped (cdr (chip-clause r)))))

(define-default-command 'crumb-chip 'quire-view 'pop-to)

;;; ---- the parameters, as pickers ----------------------------------------------------
;;; FOUR COMMANDS BECAME TWO, and that is the measurement rather than the tidy-up.  Setting a
;;; measure used to need one command per measure -- MEASURE-SUM, MEASURE-COUNT -- because a
;;; command could not carry a value, so the cube's four measures would have been four commands
;;; and a fifth measure would have been a fifth.  A parameter with ten values does not survive
;;; that, and a parameter over the DATA (filter to any region) cannot be written at all.
;;;
;;; A picker is the same hold-menu rule 5 already had.  What changed is that the menu lists
;;; VALUES, and the tap carries the one that was tapped.

(define-command (set-measure :arg-type slice-head-row :cost :local :label "measure"
                             ;; The choices come from the CUBE, so adding a measure to the model
                             ;; adds it to every menu with no UI edit anywhere.  That is the
                             ;; property a command-per-value cannot have.
                             :values (lambda (r) (declare (ignore r))
                                       (mapcar (lambda (m) (cons (car m) (car m)))
                                               (cube-measures (doc-cube *document*))))
                             :current (lambda (r) (slice-measure (part-slice (row-part r)))))
    (r invoker value)
  (declare (ignore invoker))
  (setf (slice-measure (part-slice (row-part r))) value)
  (list :measure value))

(define-command (set-columns :arg-type slice-head-row :cost :local :label "columns"
                             :values (lambda (r)
                                       ;; every dimension the rows are not already grouped by,
                                       ;; plus the way back to a plain list
                                       (let ((rows-by (slice-rows-by (part-slice (row-part r)))))
                                         (cons (cons nil "(none)")
                                               (loop for (name . nil) in (cube-dims
                                                                          (doc-cube *document*))
                                                     unless (equal name rows-by)
                                                       collect (cons name name)))))
                             :current (lambda (r) (slice-cols-by (part-slice (row-part r)))))
    (r invoker value)
  (declare (ignore invoker))
  (setf (slice-cols-by (part-slice (row-part r))) value)
  (list :columns value))

(define-command (set-rows :arg-type slice-head-row :cost :local :label "rows"
                          :values (lambda (r)
                                    (let ((cols-by (slice-cols-by (part-slice (row-part r)))))
                                      (loop for (name . nil) in (cube-dims (doc-cube *document*))
                                            unless (equal name cols-by)
                                              collect (cons name name))))
                          :current (lambda (r) (slice-rows-by (part-slice (row-part r)))))
    (r invoker value)
  (declare (ignore invoker))
  (setf (slice-rows-by (part-slice (row-part r))) value)
  (list :rows value))

;;; ---- the document under the cursor -------------------------------------------------
;;; ONE DOCUMENT PER IMAGE, because a command's arguments are a row and an invoker and neither
;;; carries the document.  Threading it through would mean a slot on every row -- which the
;;; rows already have, as PART -> but a part does not know its document either.  The honest
;;; fix is a backlink from part to document; this special is the demo's stand-in and is named
;;; so it cannot be mistaken for a design.

(defvar *document* nil "The document commands act on.  See the note above: a stand-in.")

(defun quire-projection (doc)
  "The result-set: every row of every part, re-run each epoch (rule 8)."
  (setf *document* doc)
  (make-projection (lambda () (document-rows doc))))
