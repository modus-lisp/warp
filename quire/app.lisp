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

(define-command (pop-to :arg-type crumb-row :cost :local :label "back to here")
    (r invoker)
  (declare (ignore invoker))
  ;; Pops the WHOLE path.  Popping to a specific chip needs the tapped cell's index, and a
  ;; gesture carries a KEY and no coordinates (§10.5: "There are no coordinates on this wire"),
  ;; so a per-chip pop needs one presentation per chip rather than one row of cells.  That is a
  ;; real finding about the widget set and it is left visible here rather than worked around:
  ;; A ROW OF CHIPS IS NOT TAPPABLE PER CHIP.  Either chips become presentations, or this stays
  ;; an all-or-nothing pop.
  (let ((sl (part-slice (row-part r))))
    (setf (slice-filter sl) '())
    (setf (slice-rows-by sl) (car (first (cube-dims (doc-cube *document*)))))
    (list :popped t)))

(define-default-command 'crumb-row 'quire-view 'pop-to)

;;; ---- pivoting ---------------------------------------------------------------------
;;; On the HEAD row, because that is where the axes are, and a hold there is the closest thing
;;; this vocabulary has to "grab a dimension".

(define-command (measure-sum :arg-type slice-head-row :cost :local :label "measure: amount")
    (r invoker)
  (declare (ignore invoker))
  (setf (slice-measure (part-slice (row-part r))) "amount") (list :measure "amount"))

(define-command (measure-count :arg-type slice-head-row :cost :local :label "measure: orders")
    (r invoker)
  (declare (ignore invoker))
  (setf (slice-measure (part-slice (row-part r))) "orders") (list :measure "orders"))

(define-command (pivot-region :arg-type slice-head-row :cost :local :label "columns: region")
    (r invoker)
  (declare (ignore invoker))
  (let ((sl (part-slice (row-part r))))
    (setf (slice-cols-by sl) (if (equal (slice-cols-by sl) "region") nil "region")))
  (list :pivot "region"))

(define-command (pivot-quarter :arg-type slice-head-row :cost :local :label "columns: quarter")
    (r invoker)
  (declare (ignore invoker))
  (let ((sl (part-slice (row-part r))))
    (setf (slice-cols-by sl) (if (equal (slice-cols-by sl) "quarter") nil "quarter")))
  (list :pivot "quarter"))

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
