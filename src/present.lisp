;;;; present.lisp — projections, and the layout that gives them extents.
;;;;
;;;; PRESENT dispatches on (object, type, view) — the CLIM signature everyone forgets, and the seam
;;;; that makes "every view is an inspector" true as the DEGENERATE case rather than as an
;;;; architecture.  The default method walks slots via the MOP, so any new type in the image is
;;;; immediately browsable with zero UI code; designing a UI means specializing PRESENT for a
;;;; (type, view) pair.  Reads are projections here; writes are commands (command.lisp).
;;;;
;;;; PRESENT returns CONTENT, not pixels — a list of cells.  Layout then assigns extents and builds
;;;; the presentations.  Keeping them apart is what lets the content double as the FINGERPRINT: the
;;;; diff compares what the view derived its appearance from, never a closure.

(in-package #:warp)

(defgeneric present (object type view)
  (:documentation "Project OBJECT as TYPE into VIEW.  Returns a list of cells (strings or
(string . tag) pairs).  The default method is a MOP slot walk."))

(defmethod present (object type view)
  "The inspector, as a default: every slot, in definition order.  Legible, not designed — which is
exactly the trade named in DESIGN.md.  Specialize to design."
  (declare (ignorable type view))
  (let ((class (class-of object)))
    (cons (format nil "~a" (class-name class))
          (mapcar (lambda (sd)
                    (let ((name (sb-mop:slot-definition-name sd)))
                      (format nil "~(~a~): ~a" name
                              (if (slot-boundp object name)
                                  (slot-value object name)
                                  "#<unbound>"))))
                  (sb-mop:class-slots class)))))

;;; ---- layout ----------------------------------------------------------------
;;; A vertical list, which is client one's shape and the shape that exercises the protocol: scrolling
;;; produces :moved for rows that stay, :gone/:appeared for rows crossing the viewport edge.
;;;
;;; Only VISIBLE rows become presentations.  That is not an optimization — it is the working set.  A
;;; view subscribes to a slice, and the slice is what the consumer is told about.

(defun layout-list (objects type view
                    &key (x 0) (y 0) (width 640) (row-height 32) (scroll-y 0) (viewport-h 480)
                         (as-of nil))
  "Lay OBJECTS out as a vertical list and return the presentations for the rows that are VISIBLE
given SCROLL-Y and VIEWPORT-H.  Extents are grid-snapped in framebuffer space (rule 3), and each
row's fingerprint is its projected content, so a row that renders the same emits nothing."
  (let ((rh (snap row-height :up t))               ; rows are a whole number of macroblocks
        (out '()))
    (loop for o in objects
          for i from 0
          for top = (- (+ y (* i rh)) scroll-y)
          when (and (> (+ top rh) y) (< top (+ y viewport-h)))    ; intersects the viewport
            do (let ((content (present o type view)))
                 (push (make-presentation
                        :key (presentation-key type o)
                        :type type
                        :object o
                        :extent (snap-extent x top width rh)
                        :fingerprint content
                        :as-of as-of)
                       out)))
    (nreverse out)))

(defun list-content-height (objects &key (row-height 32))
  (* (length objects) (snap row-height :up t)))
