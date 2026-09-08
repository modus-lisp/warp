;;;; quire/cube.lisp — a small OLAP cube: facts, dimensions, measures, and a slice.
;;;;
;;;; ==================================================================================
;;;; WHY A CUBE AND NOT A TABLE
;;;; ==================================================================================
;;;;
;;;; The document this feeds mixes AUTHORED content with LIVE QUERY REGIONS, and the whole
;;;; question it is built to ask is what a warp widget set has to carry.  A flat table would
;;;; not have asked it: a table is a list, and warp has three clients that are lists.
;;;;
;;;; A cube asks it because a SLICE IS NOT A LIST.  Group N facts by one dimension and you
;;;; get rows; group by two and you get rows AND columns, and a warp row is three positional
;;;; cells (value, label, trend).  Client one could live inside that.  A pivot with four
;;;; measures cannot, and finding out exactly where it breaks is the point of building this
;;;; rather than reasoning about it.
;;;;
;;;; ==================================================================================
;;;; NO DEPENDENCIES, AND NOT FOR PURITY
;;;; ==================================================================================
;;;;
;;;; Facts are plists, dimensions are functions, measures are (name . reducer).  There is no
;;;; storage engine, no index and no query planner, because none of that is under test: the
;;;; slice is re-run every epoch by an ordinary RESULT-SET (rule 8), the same way warp-files
;;;; re-reads the open columns from disk, so a cube that answered in microseconds and a cube
;;;; that answered from a file would exercise the protocol identically.
;;;;
;;;; What IS under test is that the result changes shape under the user's finger — drill into
;;;; a dimension and the row set is different rows, not the same rows with new numbers — and
;;;; a reconciler keyed on identity has to say `gone'/`appeared' rather than `changed'.

(in-package #:warp-quire)

;;; ---- the fact table ---------------------------------------------------------------

(defclass cube ()
  ((facts :initarg :facts :reader cube-facts
          :documentation "A list of plists.  One fact per row of the source data.")
   (dims  :initarg :dims  :reader cube-dims
          :documentation "((name . key) ...) — a dimension is a name and the plist key that
reads it out of a fact.  A FUNCTION would be more general and is not needed yet; when one
is, this is the seam.")
   (measures :initarg :measures :reader cube-measures
             :documentation "((name key . reducer) ...) — reducer is (values) -> value."))
  (:documentation "Facts, and the two vocabularies for asking about them."))

(defun sum-of (vals) (reduce #'+ vals :initial-value 0))
(defun count-of (vals) (length vals))
(defun mean-of (vals) (if (null vals) 0 (/ (sum-of vals) (length vals))))
(defun max-of (vals) (if (null vals) 0 (reduce #'max vals)))

(defun dim-key (cube name)
  (or (cdr (assoc name (cube-dims cube) :test #'string-equal))
      (error "quire: no dimension ~a" name)))

(defun measure-spec (cube name)
  (or (assoc name (cube-measures cube) :test #'string-equal)
      (error "quire: no measure ~a" name)))

(defun dim-values (cube name &key filter)
  "The distinct values of dimension NAME, in first-seen order, under FILTER."
  (let ((key (dim-key cube name)) (seen '()))
    (dolist (f (cube-facts cube) (nreverse seen))
      (when (fact-matches-p f filter)
        (let ((v (getf f key)))
          (unless (member v seen :test #'equal) (push v seen)))))))

(defun fact-matches-p (fact filter)
  "FILTER is ((key . value) ...) — every clause must hold.  NIL matches everything."
  (loop for (k . v) in filter always (equal (getf fact k) v)))

;;; ---- the slice --------------------------------------------------------------------
;;; A SLICE IS THE QUERY, and it is a value rather than a call: the document holds one per
;;; computed part, the user's gestures edit it, and the result-set re-runs it each epoch.
;;; Keeping it inert like this is what makes drill-down a state change rather than a
;;; control-flow problem -- ROWS-OF is a pure function of (cube, slice).

(defclass slice ()
  ((rows-by  :initarg :rows-by  :accessor slice-rows-by
             :documentation "Dimension name grouped down the side.")
   (cols-by  :initarg :cols-by  :accessor slice-cols-by  :initform nil
             :documentation "Dimension name grouped across the top, or NIL for a plain list.
THIS IS THE FIELD THAT BREAKS A THREE-CELL ROW: with it set, one row carries one value per
distinct column value, and there is no positional convention that survives that.")
   (measure  :initarg :measure  :accessor slice-measure
             :documentation "Which measure the cells hold.")
   (filter   :initarg :filter   :accessor slice-filter   :initform '()
             :documentation "((key . value) ...) — the drill path, innermost last.")
   (limit    :initarg :limit    :accessor slice-limit    :initform nil))
  (:documentation "One question asked of a cube."))

(defun slice-column-values (cube slice)
  "The column headings for SLICE, or NIL when it is a plain list."
  (when (slice-cols-by slice)
    (dim-values cube (slice-cols-by slice) :filter (slice-filter slice))))

(defstruct (slice-row (:constructor %make-slice-row))
  label                                  ; the row dimension's value
  cells                                  ; ((column-value . number) ...) — one entry per column,
                                         ; or a single (NIL . number) for a plain list
  total)                                 ; the row's total across columns

(defun rows-of (cube slice)
  "Run SLICE against CUBE.  Returns (values rows column-values grand-total).

RE-RUN EVERY EPOCH BY DESIGN (rule 8): this is the result-set, and it is a pure function of
its two arguments, so two consumers looking at one document see the same numbers without
sharing anything but the projection that called it."
  (let* ((rkey (dim-key cube (slice-rows-by slice)))
         (ckey (and (slice-cols-by slice) (dim-key cube (slice-cols-by slice))))
         (spec (measure-spec cube (slice-measure slice)))
         (mkey (second spec))
         (reducer (cddr spec))
         (cols (slice-column-values cube slice))
         (matching (remove-if-not (lambda (f) (fact-matches-p f (slice-filter slice)))
                                  (cube-facts cube)))
         (rows '()))
    (dolist (rv (dim-values cube (slice-rows-by slice) :filter (slice-filter slice)))
      (let* ((in-row (remove-if-not (lambda (f) (equal (getf f rkey) rv)) matching))
             (cells (if ckey
                        (mapcar (lambda (cv)
                                  (cons cv (funcall reducer
                                                    (mapcar (lambda (f) (getf f mkey))
                                                            (remove-if-not
                                                             (lambda (f) (equal (getf f ckey) cv))
                                                             in-row)))))
                                cols)
                        (list (cons nil (funcall reducer
                                                 (mapcar (lambda (f) (getf f mkey)) in-row)))))))
        (push (%make-slice-row :label rv :cells cells
                               :total (funcall reducer
                                               (mapcar (lambda (f) (getf f mkey)) in-row)))
              rows)))
    (setf rows (nreverse rows))
    (when (slice-limit slice)
      (setf rows (subseq rows 0 (min (length rows) (slice-limit slice)))))
    (values rows cols
            (funcall reducer (mapcar (lambda (f) (getf f mkey)) matching)))))

;;; ---- formatting -------------------------------------------------------------------
;;; A CELL IS A STRING BY THE TIME IT REACHES PRESENT, and that is warp's rule rather than a
;;; convenience: the fingerprint is what the view derived its appearance from, so a number
;;; that formats to "1.2k" must diff as "1.2k".  Format here, once, or two consumers rounding
;;; differently would each think the other's row had changed.

(defun fmt-number (n)
  (cond ((null n) "—")
        ((and (integerp n) (>= (abs n) 1000000)) (format nil "~,1fM" (/ n 1000000.0)))
        ((and (integerp n) (>= (abs n) 1000)) (format nil "~,1fk" (/ n 1000.0)))
        ((integerp n) (format nil "~d" n))
        ((rationalp n) (format nil "~,1f" (float n)))
        (t (format nil "~a" n))))
