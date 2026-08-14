;;;; files/columns.lisp — Miller columns: one walk, and the positional claim left to the encoding.
;;;;
;;;; =============================================================================================
;;;; WHAT MET THE CODE: THE RECONCILER IS FLAT, AND "PARENT-SCOPED KEYS ALREADY EXIST" IS FALSE
;;;; =============================================================================================
;;;;
;;;; This client was commissioned to exercise parent-scoped keys, on the understanding that the
;;;; reconciler had them and nothing had used them.  It does not have them.  Read %DIFF:
;;;;
;;;;     (defun %diff (consumer delivered current) ...)     ; DELIVERED is ONE hash table,
;;;;     (gethash key delivered)                            ; keyed by P-KEY, and by nothing else.
;;;;
;;;; There is no parent anywhere in it.  Rule 1 opens with "reconcile matches on (parent, key)" and
;;;; the reconciler matches on `key`.  Three separate things say otherwise and all three are
;;;; decoration:
;;;;
;;;;   * PRESENTATION's CHILDREN slot is exported as P-CHILDREN and READ BY NOTHING.  Grep the
;;;;     repository: it appears in the DEFSTRUCT and in the export list, and in no other line of
;;;;     code in warp, warp-glass, warp-dom, the monitor, or any test.  A projection that put its
;;;;     nesting in CHILDREN — the obvious reading of the slot — would ship its roots and silently
;;;;     drop every descendant, because nothing walks it.
;;;;   * PRESENTATION-KEY's signature is (TYPE OBJECT).  A key function CANNOT SEE THE PARENT, so
;;;;     "the default key is a per-type key function" and "keys are scoped to the parent" cannot
;;;;     both be satisfied by the key function alone.
;;;;   * The DOM encoding's (parent . after) is in P-EXTENT, which is POSITION, not IDENTITY.  It is
;;;;     what INSERTBEFORE takes; it is not what the delivered table is keyed by.  The comment there
;;;;     calls it "rule 1's keys-are-scoped-to-the-parent written as data", and it is genuinely a
;;;;     different claim: two nodes in different containers with the same key collide in DELIVERED
;;;;     no matter what their extents say.
;;;;
;;;; SO WHAT DOES THIS CLIENT DO?  It scopes the key in the KEY FUNCTION, by giving the object its
;;;; parent (model.lisp's FS-ROW is an entry plus its column) and consing the two together.  That
;;;; works, it needed no change to core, and it is worth being precise about what it proves:
;;;;
;;;;   * the ASSERTION HOLDS — a change to one row emits deltas scoped to that row, a change in one
;;;;     column does not re-send the others, and two identically-named files in two columns do not
;;;;     collide.  The numbers are in t/files.lisp.
;;;;   * but it holds for a DIFFERENT REASON than rule 1 implies.  The scope is not a diff scope.
;;;;     There is exactly one diff, over one flat table, and "the column was not re-sent" is true
;;;;     because no column-shaped thing exists that COULD have been re-sent — not because a
;;;;     sub-diff was skipped.  The cost is O(all rows in all columns) per pass either way.
;;;;
;;;; That is a real result and it is a cheaper one than the rule advertises.  Flat-with-composite-
;;;; keys is sufficient for correctness and gets nesting for free.  What it does NOT get is the
;;;; thing rule 9 wants before it projects the desktop: an INDEPENDENT DIFF SCOPE, where a subtree
;;;; can be diffed, budgeted, or resynced without touching its siblings.  A window's contents ought
;;;; to be resyncable without re-diffing the session; here RESYNC clears the one DELIVERED table and
;;;; re-announces everything.  Rule 9 says to sequence the desktop last because being wrong about
;;;; nesting in an app costs a day and in the session costs the screen — on this evidence the thing
;;;; to be careful about is not whether nesting WORKS but that the reconciler has one scope, and a
;;;; session wants one per window.
;;;;
;;;; =============================================================================================
;;;; The walk, and what an encoding still has to say
;;;; =============================================================================================
;;;; Everything below is encoding-neutral: which columns exist, which rows are in view, what is
;;;; selected, what is focused, and where the preview goes in the running order.  What it does NOT
;;;; decide is WHERE anything is, because position is a claim only an encoding can make (rule 2's
;;;; correction).  Four generics carry that, and the two encodings are ~40 lines each.

(in-package #:warp-files)

(defclass miller-consumer (consumer)
  ((column-w :initarg :column-w :initform 224 :accessor column-w
             :documentation "Column width in this consumer's own units — pixels for a framebuffer,
ignored by a browser whose stylesheet knows better.")
   (focus-column :initarg :focus-column :initform 0 :accessor focus-column
                 :documentation "Rule 7 view state: WHICH COLUMN this consumer is looking at.  Per
consumer per view, keyed the way presentations are, and it is the third piece of view state after
selection and scroll — the one a flat list had no room for."))
  (:documentation "The Miller-column layout, with no encoding target.  ABSTRACT: mix it in FRONT of
an encoding's consumer class so this LAY-OUT wins and that class's APPLY-DELTAS satisfies core's
construction check."))

;;; ---- the seam ---------------------------------------------------------------------------------

(defgeneric row-place (consumer column row-index prev-key)
  (:documentation "This encoding's positional claim for the row at ROW-INDEX of COLUMN, following
PREV-KEY in its column's running order.  A rectangle for a framebuffer; (container . after) for a
DOM; NIL is legal and costs one unit."))

(defgeneric preview-place (consumer column-index prev-key)
  (:documentation "Where the opaque preview node goes, in the pane to the right of everything."))

(defgeneric visible-rows (consumer column)
  (:documentation "(values LO HI) — the half-open range of row indices this consumer can show in
COLUMN.  A framebuffer computes it from pixels and scroll; a browser is told by the browser."))

(defgeneric column-visible-p (consumer column-index depth)
  (:documentation "Can this consumer show the column at COLUMN-INDEX, of DEPTH columns plus a
preview pane?  A framebuffer runs out of width; a browser scrolls sideways by itself."))

(defmethod column-visible-p ((c miller-consumer) column-index depth)
  (declare (ignore depth))
  (< (* column-index (column-w c)) (viewport-width c)))

(defmethod visible-rows ((c miller-consumer) column)
  (declare (ignore column))
  (let ((rh (consumer-row-height c)) (s (consumer-scroll-y c)))
    (values (max 0 (floor s rh)) (ceiling (+ s (viewport-height c)) rh))))

;;; ---- grouping ---------------------------------------------------------------------------------

(defun columns-of (objects)
  "OBJECTS grouped into (column . rows), in column order.  The result-set is flat and in
column-major order, so this is a scan, not a sort."
  (let ((out '()))
    (dolist (o objects (nreverse (mapcar (lambda (cell) (cons (car cell) (nreverse (cdr cell))))
                                         out)))
      (when (typep o 'fs-row)
        (let* ((col (row-column o)) (cell (assoc col out :test #'eq)))
          (unless cell (setf cell (cons col '())) (push cell out))
          (push o (cdr cell)))))))

(defun max-column-rows (objects)
  (let ((n 0))
    (dolist (cell (columns-of objects) n)
      (setf n (max n (length (cdr cell)))))))

;;; ---- the preview: this consumer's, because the SELECTION is ----------------------------------

(defun %selected-file-row (c objects)
  "The FS-ROW this consumer has selected, if it is a file.  Selection is a KEY, so this is a lookup
by key against the shared objects — which is exactly why the key had to be stable across a re-read."
  (let ((sel (consumer-selected c)))
    (when (consp sel)
      (find-if (lambda (o)
                 (and (typep o 'fs-row) (row-entry o)
                      (eq 'fs-file (row-type o))
                      (equal sel (presentation-key 'fs-file o))))
               objects))))

(defun %preview-presentation (c objects depth as-of)
  (let ((row (%selected-file-row c objects)))
    (when row
      (let ((node (preview-for (column-browser (row-column row))
                               (row-entry row)
                               (column-path (row-column row)))))
        (when node
          (make-presentation
           :key (presentation-key 'fs-preview node)
           :type 'fs-preview :object node
           :extent (preview-place c depth nil)
           :fingerprint (present node 'fs-preview (consumer-view c))
           :as-of as-of))))))

;;; ---- lay-out ----------------------------------------------------------------------------------

(defmethod lay-out ((c miller-consumer) objects as-of)
  "One flat list of presentations covering every visible row of every visible column, plus the
opaque preview node.  Flat because that is what the reconciler diffs (see the header); the NESTING
is carried entirely by the keys and by each encoding's positional claim."
  (let* ((groups (columns-of objects))
         (depth (length groups))
         (sel (consumer-selected c))
         (focus (focus-column c))
         (out '()))
    (dolist (cell groups)
      (let* ((col (car cell)) (rows (cdr cell)) (ci (column-index col)))
        (when (column-visible-p c ci depth)
          (multiple-value-bind (lo hi) (visible-rows c col)
            (let ((prev nil))
              (dolist (r rows)
                (let ((ri (row-index r)))
                  (when (<= lo ri (1- hi))
                    (let* ((ty (row-type r))
                           (key (presentation-key ty r))
                           (p (make-presentation
                               :key key :type ty :object r
                               :extent (row-place c col ri prev)
                               :fingerprint (present r ty (consumer-view c))
                               :as-of as-of)))
                      ;; Rule 7, twice over, and both are THIS consumer's: which row is selected,
                      ;; and which column has focus.  Focus is annotated on the column HEADER only
                      ;; and not on every row of the column — a deliberate cheapness: moving focus
                      ;; then costs two deltas (the old header and the new one) instead of two
                      ;; whole columns, and the reconciler cannot tell the difference because
                      ;; P-STATE is diffed exactly like a fingerprint.
                      (let ((st (append (when (equal sel key) (list :selected t))
                                        (when (and (= ci focus) (zerop ri)) (list :focused t)))))
                        (when st (setf (p-state p) st)))
                      (setf prev key)
                      (push p out))))))))))
    (let ((pv (%preview-presentation c objects depth as-of)))
      (when pv (push pv out)))
    (nreverse out)))

;;; ---- the scroll axis --------------------------------------------------------------------------
;;; One scroll offset for the whole browser rather than one per column.  Rule 7 keeps ONE scroll
;;; slot and CONTENT-HEIGHT is what makes the clamp land in the right unit, so a per-column offset
;;; would need a slot core does not have — worth saying out loud as a limit rather than leaving it
;;; to be discovered.  The tallest column is what there is to scroll through.

(defmethod content-height ((c miller-consumer))
  (* (max-column-rows (projection-objects (consumer-projection c)))
     (consumer-row-height c)))

;;; ---- focus, which is view state and therefore per consumer -----------------------------------

(defun focus-on (c column-index)
  "Move this consumer's focus.  Its neighbours over the same browser are not moved — they are
looking at the same directories with their own eyes."
  (setf (focus-column c) (max 0 column-index)))
