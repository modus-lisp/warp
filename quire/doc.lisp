;;;; quire/doc.lisp — a compound document: authored parts and computed parts, in one order.
;;;;
;;;; ==================================================================================
;;;; THE OPENDOC IDEA, AND WHY IT IS THE INTERESTING HALF
;;;; ==================================================================================
;;;;
;;;; OpenDoc's claim was that a document is not a file belonging to an application; it is a
;;;; surface with PARTS on it, each part owning its region and knowing how to draw itself,
;;;; and the container knowing only the order.  Numbers.app is the same claim with the
;;;; spreadsheet's grid demoted: a sheet is a canvas holding tables, and a table is a part.
;;;;
;;;; That maps onto warp better than a grid does, and it is the reason to build this one:
;;;;
;;;;   * a PART is a container (§10.4).  The client creates one per part on demand and drops
;;;;     it when the last child leaves -- which is exactly what warp-files does per column,
;;;;     so the mechanism is proven and this is the second shape using it.
;;;;   * an AUTHORED part is constant.  It re-presents to identical cells every epoch, so it
;;;;     produces NO deltas after its first appearance, and a document that is nine-tenths
;;;;     prose costs nine-tenths of nothing per pass.  That is a property worth measuring,
;;;;     and the test does.
;;;;   * a COMPUTED part is a result-set that changes SHAPE, not just values.  Drill in and
;;;;     the rows are different rows; the reconciler must say gone/appeared rather than
;;;;     changed, and it must scope that to one part's container while the prose around it
;;;;     stays put.
;;;;
;;;; ==================================================================================
;;;; ONE PROJECTION, MANY PARTS
;;;; ==================================================================================
;;;;
;;;; ROWS-FN returns every row of every part, flattened, in document order, and each row
;;;; carries the part it belongs to.  The alternative -- a projection per part -- was
;;;; rejected: rule 8 shares ONE query per epoch between N consumers, and N projections
;;;; would make a document of twelve parts twelve epoch handshakes for one screen.
;;;;
;;;; The flattening is not a compromise on the client side either.  Containers are a flat
;;;; sequence on the wire (§10.4: "cs is a sequence, not a tree"), so a flat row list with a
;;;; container name per row is the shape the protocol already wants.

(in-package #:warp-quire)

;;; ---- parts ------------------------------------------------------------------------

(defclass part ()
  ((id    :initarg :id    :reader part-id
          :documentation "Stable across edits: a part's identity is not its position, or
moving a paragraph would destroy and rebuild everything below it.")
   (title :initarg :title :reader part-title :initform nil))
  (:documentation "One region of the document."))

(defclass prose-part (part)
  ((level :initarg :level :reader prose-level :initform nil
          :documentation "NIL for body text, 1..3 for a heading.")
   (text  :initarg :text  :reader prose-text))
  (:documentation "AUTHORED.  Constant until somebody edits it, which is what makes it the
control in every measurement here: if a prose part ever emits a delta on a quiet pass, the
fingerprint is not a pure function of the content."))

(defclass slice-part (part)
  ((slice :initarg :slice :reader part-slice)
   (note  :initarg :note  :reader part-note :initform nil))
  (:documentation "COMPUTED.  Holds the question, not the answer; the answer is re-derived
each epoch by ROWS-OF."))

;;; ---- the document -----------------------------------------------------------------

(defclass document ()
  ((title :initarg :title :reader doc-title)
   (cube  :initarg :cube  :reader doc-cube)
   (parts :initarg :parts :accessor doc-parts))
  (:documentation "An ordered set of parts over one cube."))

(defun doc-part (doc id)
  (find id (doc-parts doc) :key #'part-id :test #'string=))

;;; ---- the rows a part contributes --------------------------------------------------
;;; Every row type here is a separate presentation TYPE, and that is the finding this demo
;;; exists to produce rather than a stylistic choice.  warp's three clients each needed one
;;; row type; this one needs six, and the moment there are six it stops being possible to
;;; smuggle "which kind am I" into the third cell of a three-cell row -- which is what
;;; `cells[2] === "opaque"' does in the reference client today.

(defclass doc-row () ((part :initarg :part :reader row-part))
  (:documentation "Anything that appears inside a part's container."))

(defclass heading-row (doc-row)
  ((level :initarg :level :reader heading-level)
   (text  :initarg :text  :reader heading-text)))

(defclass prose-row (doc-row)
  ((text :initarg :text :reader prose-row-text)))

(defclass slice-head-row (doc-row)
  ((labels* :initarg :labels :reader head-labels
            :documentation "The column headings, left-most first, INCLUDING the corner cell.
A three-cell row cannot hold this and that is the point.")))

(defclass slice-data-row (doc-row)
  ((label :initarg :label :reader data-label)
   (cells :initarg :cells :reader data-cells)     ; ((column . formatted) ...)
   (total :initarg :total :reader data-total)
   (drill :initarg :drill :reader data-drill :initform nil
          :documentation "The (key . value) this row would filter by if tapped, or NIL when
the slice is already at its finest grain.")))

(defclass slice-total-row (doc-row)
  ((label :initarg :label :reader total-label)
   (value :initarg :value :reader total-value)))

(defclass crumb-chip (doc-row)
  ((clause :initarg :clause :reader chip-clause)     ; the (key . value) this chip stands for
   (depth  :initarg :depth  :reader chip-depth))     ; how far into the path it is, 0-based
  (:documentation "ONE step of the drill path, and a presentation rather than a cell.

RESOLVED, and the design answered it before this app existed: PROTOCOL.md says `Menus are
presentations -- opening one emits :appeared per item\'.  A menu is a list of tappable things
and so is a breadcrumb, so they are the same shape.

The rule that separates a chip from a table cell, which is the question this settles: DOES THE
THING HAVE IDENTITY IN THE DOMAIN?  A filter clause is an object -- (region . North) -- you can
name it, key it and revoke it.  A pivot cell is an ATTRIBUTE of a row and has no identity apart
from it.  Things with identity get keys; things without are cells.

That is also why this does not generalise into `make every cell tappable\': a five-column pivot
of twenty rows would become a hundred presentations instead of twenty, which is exactly the
cost a delta protocol exists to avoid.  Four chips is four."))

;;; ---- identity ---------------------------------------------------------------------
;;; RULE 1: the key is declared, and it has to be stable across a re-query or every pass is a
;;; teardown.  A part's rows key on (part-id, what-they-are, which-one) -- never on position,
;;; because sorting a slice by a different measure reorders rows that are the same rows.

(define-presentation-key heading-row (r) (format nil "~a/h" (part-id (row-part r))))
(define-presentation-key prose-row   (r) (format nil "~a/p" (part-id (row-part r))))
(define-presentation-key slice-head-row (r) (format nil "~a/head" (part-id (row-part r))))
(define-presentation-key crumb-chip (r)
  ;; Keyed by DEPTH, not by value: popping to a chip truncates the path there, and two drills
  ;; onto the same value at different depths are different steps.
  (format nil "~a/crumb/~a" (part-id (row-part r)) (chip-depth r)))
(define-presentation-key slice-total-row (r) (format nil "~a/total" (part-id (row-part r))))
(define-presentation-key slice-data-row (r)
  (format nil "~a/r/~a" (part-id (row-part r)) (data-label r)))

;;; ---- the container a row lives in --------------------------------------------------

(defun row-container (r)
  "Where a row goes.  `part:<id>' by the same convention warp-files uses for `col:<path>' -- an
app container's name is the app's, and must not be `rows' or begin with `menu:' (§10.4).

CHIPS GET THEIR OWN CONTAINER, and that is the whole of what makes them a horizontal strip: a
container's place is the client's (§10.4 -- \"Nothing on the wire says where a container goes\"),
so `crumbs:<id>' is a name the stylesheet lays out in a row while `part:<id>' stacks.  The
server claims no geometry and the client needs no new delta kind."
  (if (typep r 'crumb-chip)
      (format nil "crumbs:~a" (part-id (row-part r)))
      (format nil "part:~a" (part-id (row-part r)))))

;;; ---- the query ---------------------------------------------------------------------

(defun part-rows (doc p)
  "The rows P contributes this epoch, in order."
  (etypecase p
    (prose-part
     (list (if (prose-level p)
               (make-instance 'heading-row :part p :level (prose-level p) :text (prose-text p))
               (make-instance 'prose-row :part p :text (prose-text p)))))
    (slice-part
     (let ((sl (part-slice p)))
       (multiple-value-bind (rows cols grand) (rows-of (doc-cube doc) sl)
         (append
          ;; The drill path, when there is one.  Absent at the top level rather than empty:
          ;; a row that exists only to say "nothing here" is a row the budget pays for.
          (loop for clause in (slice-filter sl)
                for depth from 0
                collect (make-instance 'crumb-chip :part p :clause clause :depth depth))
          ;; THE HEAD ALWAYS ENDS WITH THE TOTAL COLUMN, pivoted or not, and that is a
          ;; correction the widget declaration forced.  It used to append "total" only when
          ;; there were columns, so a plain list's head was ONE cell while a pivot's was N --
          ;; two shapes wearing one presentation type, which WIDGET-LAYOUT refused to resolve
          ;; and the old sniff-the-cells convention would have painted without complaint.
          ;;
          ;; Making them consistent is not padding: for a list grouped by one dimension, the
          ;; row's single number IS its total across the (empty) column axis, so `(corner
          ;; total)' is what that row has always meant.  The heading reads better as the
          ;; measure's name than the word "total" when there is nothing to total across.
          (list (make-instance 'slice-head-row :part p
                               :labels (append (list (slice-rows-by sl))
                                               (mapcar (lambda (c) (format nil "~a" c))
                                                       (or cols '()))
                                               (list (if cols "total" (slice-measure sl))))))
          (mapcar (lambda (r)
                    (make-instance 'slice-data-row :part p
                                   :label (format nil "~a" (slice-row-label r))
                                   :cells (mapcar (lambda (c)
                                                    (cons (car c) (fmt-number (cdr c))))
                                                  (slice-row-cells r))
                                   :total (fmt-number (slice-row-total r))
                                   :drill (unless (slice-cols-by sl)
                                            (cons (dim-key (doc-cube doc) (slice-rows-by sl))
                                                  (slice-row-label r)))))
                  rows)
          (list (make-instance 'slice-total-row :part p
                               :label (format nil "~a" (slice-measure sl))
                               :value (fmt-number grand)))))))))

(defun document-rows (doc)
  "Every row of every part, flattened, in document order.  This is ROWS-FN."
  (loop for p in (doc-parts doc) append (part-rows doc p)))
