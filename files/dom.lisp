;;;; files/dom.lisp — Miller columns as nested sibling lists, and a node this encoding cannot draw.
;;;;
;;;; THIS IS THE CONSUMER RULE 9 WAS WRITTEN FOR.  The framebuffer beside it blits the image
;;;; preview; this one cannot, and is not going to be given a way to.  The wire is JSON cells, and
;;;; "binary payloads" is listed in DESIGN.md as a real open question rather than an omission — so
;;;; inventing a side channel here to sneak the pixels through would answer a question that has not
;;;; been asked and would destroy the only test of the thing rule 9 actually claims:
;;;;
;;;;     a consumer that cannot blit still knows what the region is.
;;;;
;;;; It knows because the app SAID so.  The caption is in the fingerprint, so it travels on exactly
;;;; the same path as a filename or a byte count, costs its own bytes out of this consumer's own
;;;; budget, and needs no special case anywhere in this file.  What arrives is
;;;;
;;;;     {"k":"appeared","key":"(/tmp/fix/pics/ . PREVIEW)","type":"fs-preview",
;;;;      "in":"preview","cells":["kitten.png — PNG file, 320 x 200","192 x 120","opaque"], ...}
;;;;
;;;; and a client draws a box with that caption in it.  Note what is NOT in there: no pixels, no
;;;; data URI, no length that hints at an image.  The `opaque` tag in the third cell is the app
;;;; saying "this is a hole" and is the only thing a client needs to know to render a placeholder
;;;; instead of a row.
;;;;
;;;; NESTING, in this encoding, is nearly free — and it is the encoding where it reads best.  The
;;;; DOM's positional claim is already (parent . after), so N columns are N containers and a row's
;;;; place says which column it is in.  A framebuffer expresses "column 2" as a range of x that
;;;; nothing checks; here it is a name the client groups by.

(defpackage #:warp-files-dom
  (:use #:cl #:warp)
  (:local-nicknames (#:f #:warp-files) (#:d #:warp-dom))
  (:export #:files-dom-consumer #:attach-dom #:column-container))

(in-package #:warp-files-dom)

(defclass files-dom-consumer (f:miller-consumer d:dom-consumer) ()
  (:documentation "Miller columns as JSON deltas over somebody else's link."))

(defun attach-dom (projection &rest initargs)
  "INITARGS first: MAKE-INSTANCE takes the leftmost of a duplicated initarg, so a default placed
before a caller's argument would win over it."
  (apply #'warp:attach projection :class 'files-dom-consumer
         (append initargs (list :view 'f:files-view))))

;;; ---- where things are: containers and siblings, never coordinates ----------------------------

(defun column-container (column)
  "The DOM container for a column.  This is the nesting: one list per open directory, named by the
directory, and a row's position says which list it is in."
  (format nil "col:~a" (namestring (f:column-path column))))

(defmethod f:row-place ((c files-dom-consumer) column row-index prev-key)
  (declare (ignore row-index))
  (cons (column-container column) prev-key))

(defmethod f:preview-place ((c files-dom-consumer) column-index prev-key)
  (declare (ignore column-index))
  ;; The preview pane is its OWN container rather than the Nth column's, because this encoding has
  ;; no Nth position — a browser puts the preview where its stylesheet says, and the server has no
  ;; business claiming a column index it cannot measure.
  (cons "preview" prev-key))

;;; ---- the slice, in the unit the browser reports ----------------------------------------------
;;; Rule 8's consumer-negotiated slice, applied PER COLUMN: the browser says it can show N rows, and
;;; it gets N rows of every column rather than N rows of a flat list.  That is a real difference
;;; from the flat clients — the working set is depth x rows, not rows — and it is the one place the
;;; budget notices that this client nests.

(defmethod f:visible-rows ((c files-dom-consumer) column)
  (declare (ignore column))
  (let ((first (max 0 (consumer-scroll-y c))))
    (values first (+ first (viewport-height c)))))

(defmethod f:column-visible-p ((c files-dom-consumer) column-index depth)
  (declare (ignore column-index depth))
  ;; A browser scrolls sideways by itself; the server has no width to run out of.
  t)

(defmethod content-height ((c files-dom-consumer))
  "In ROWS, not pixels — MILLER-CONSUMER's method is in pixels and would clamp this consumer's
scroll against a number 32 times too big.  The unit is the consumer's, and this is where it bites."
  (f:max-column-rows (projection-objects (consumer-projection c))))
