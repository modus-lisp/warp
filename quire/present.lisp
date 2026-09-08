;;;; quire/present.lisp — six row kinds, and what the demo learned by needing them.
;;;;
;;;; ==================================================================================
;;;; THE FINDING, STATED BEFORE THE CODE THAT PRODUCES IT
;;;; ==================================================================================
;;;;
;;;; warp's three earlier clients each needed ONE row shape, and the reference client
;;;; encodes that assumption twice over:
;;;;
;;;;     if (d.type === "menu-item")     cells = [label, cost, destructive?]
;;;;     else if (cells[2] === "opaque") cells = [caption, dims, "opaque"]
;;;;     else                            cells = [value, label, trend]
;;;;
;;;; The third slot means TREND, or DESTRUCTIVE, or the literal type tag "opaque", and which
;;;; one is decided by testing its own contents.  That is a type smuggled through a data slot,
;;;; and it works for exactly as long as every client is a flat list of one kind of thing.
;;;;
;;;; THIS DOCUMENT NEEDS SIX KINDS AND TWO OF THEM ARE N-ARY.  A pivot head is a corner cell
;;;; plus one heading per column plus a total; a pivot row is a label plus one number per
;;;; column plus a total.  Three cells cannot hold that at any width, so the positional
;;;; convention does not bend here, it snaps.
;;;;
;;;; ==================================================================================
;;;; WHAT THE PROTOCOL ALREADY ALLOWS, WHICH IS MORE THAN THE CLIENT DOES
;;;; ==================================================================================
;;;;
;;;; Worth being precise about, because it decides how much has to change.  The WIRE is fine:
;;;; DOM-CONSUMER's %CELLS is `(if (listp fingerprint) fingerprint (list fingerprint))' -- any
;;;; length, and %JSON-WRITE already renders strings, numbers and keywords.  Nothing in the
;;;; protocol says three.
;;;;
;;;; The limit is a CONVENTION in one `paint' function, and the fix is the one the core
;;;; already demonstrates once: MENU-ITEM is a declared TYPE whose cell layout an encoding may
;;;; rely on (PROTOCOL.md §10.3 says so in as many words).  Every delta already carries `type'.
;;;; So a widget set does not need a new field, a schema language, or a version negotiation --
;;;; it needs the type field USED, and a written-down cell layout per type.
;;;;
;;;; That is what this file is: six types, each with its layout stated where the method is,
;;;; so an encoding can dispatch on `type' instead of sniffing slot three.  Whether these six
;;;; become core widgets or stay quire's is the question the demo exists to answer; what it
;;;; has already settled is that "sniff the cells" does not survive a second shape of client.

(in-package #:warp-quire)

;;; ---- the declarations ---------------------------------------------------------------
;;; These say which CORE widget each of this app's row types is, which is the whole of what an
;;; encoding needs to paint them.  The app's classes stay its own -- a SLICE-DATA-ROW is not a
;;; subclass of anything in warp -- and the mapping is a side table, like PRESENTATION-KEY.
;;;
;;; Six types, five core widgets: HEADING-ROW and PROSE-ROW are their obvious ones, the two
;;; table rows are the n-ary pair that made the old convention untenable, and CRUMB-ROW is
;;; CHIPS, whose declaration in core carries the known gap about per-chip tapping.

(define-widget heading-row (text level))
(define-widget prose-row (text))
(define-widget slice-head-row (corner (:repeat column) total))
(define-widget slice-data-row (label (:repeat value) total))
(define-widget slice-total-row (label value))
(define-widget crumb-row ((:repeat chip)))

;;; ---- authored ---------------------------------------------------------------------

;;; HEADING   cells: (text level)
;;; The level is a keyword, not a number, for the same reason a trend is :OK rather than 0 --
;;; an encoding switches on it, and a text consumer wants to print "##" for :H2 without
;;; knowing that 2 meant anything.
(defmethod present ((r heading-row) (type (eql 'heading-row)) (view (eql 'quire-view)))
  (list (heading-text r)
        (ecase (heading-level r) (1 :h1) (2 :h2) (3 :h3))))

;;; PROSE     cells: (text)
;;; ONE CELL, and the wrapping is the consumer's.  A DOM consumer has a paragraph and lets the
;;; browser break it; a framebuffer consumer breaks it against a measured font; a text consumer
;;; wraps at its column count.  Sending pre-wrapped lines would put the narrowest consumer's
;;; geometry into the fingerprint, so every other consumer would re-render on a resize it does
;;; not care about -- and rule 2 says an extent is the CONSUMER's claim, not the projection's.
(defmethod present ((r prose-row) (type (eql 'prose-row)) (view (eql 'quire-view)))
  (list (prose-row-text r)))

;;; ---- computed ---------------------------------------------------------------------

;;; TABLE-HEAD  cells: (corner col... [total])   -- N-ARY
(defmethod present ((r slice-head-row) (type (eql 'slice-head-row)) (view (eql 'quire-view)))
  (head-labels r))

;;; TABLE-ROW   cells: (label value... total)    -- N-ARY
;;;
;;; THE TOTAL IS LAST AND UNLABELLED, which is a positional convention inside a declared type
;;; rather than across all of them -- the distinction that makes this tolerable where
;;; `cells[2] === "opaque"' is not.  A consumer that knows it is painting a TABLE-ROW knows
;;; the last cell is the total because that is this type's layout; it never has to guess from
;;; the value.
(defmethod present ((r slice-data-row) (type (eql 'slice-data-row)) (view (eql 'quire-view)))
  ;; THE TOTAL IS ALWAYS PRESENT, matching the head.  For a plain list the row's one number is
  ;; its total across an empty column axis, so the layout is (LABEL TOTAL) and the repeat
  ;; absorbs nothing -- which is what WIDGET-LAYOUT answers for n=2 and is why the two shapes
  ;; can share a type at all.
  (let ((cols (mapcar #'cdr (data-cells r))))
    (if (cdr (data-cells r))
        (append (list (data-label r)) cols (list (data-total r)))
        (list (data-label r) (data-total r)))))

;;; TABLE-TOTAL cells: (label value)
(defmethod present ((r slice-total-row) (type (eql 'slice-total-row)) (view (eql 'quire-view)))
  (list (total-label r) (total-value r)))

;;; CRUMBS      cells: (chip...)                 -- N-ARY
;;; The drill path, outermost first.  Each cell is one chip; tapping one pops back to it, which
;;; the command in app.lisp resolves by POSITION in this list -- the one place a cell index is
;;; load-bearing, and it is written down here because that is the whole of the contract.
(defmethod present ((r crumb-row) (type (eql 'crumb-row)) (view (eql 'quire-view)))
  (mapcar (lambda (clause) (format nil "~a" (cdr clause))) (crumb-path r)))
