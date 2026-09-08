;;;; catalogue/dom.lisp — the catalogue as nested sibling lists: one container per widget.

(defpackage #:warp-catalogue-dom
  (:use #:cl #:warp)
  (:local-nicknames (#:cat #:warp-catalogue) (#:d #:warp-dom))
  (:export #:catalogue-dom-consumer #:attach-dom))

(in-package #:warp-catalogue-dom)

(defclass catalogue-dom-consumer (d:dom-consumer) ()
  (:documentation "Every widget warp has, as JSON deltas, one container per widget."))

(defun attach-dom (projection &rest initargs)
  (apply #'warp:attach projection :class 'catalogue-dom-consumer
         (append initargs (list :view 'cat:catalogue-view))))

(defmethod lay-out ((c catalogue-dom-consumer) objects as-of)
  "One container per widget section.  PREV is per container for the reason warp-quire's is:
`after' orders siblings WITHIN a container and says nothing across them, so one PREV threaded
across sections would anchor each section's first row to the last row of the previous one."
  (let* ((all objects)
         (n (length all))
         (first (max 0 (min (consumer-scroll-y c) n)))
         (last (min n (+ first (viewport-height c))))
         (type-fn (projection-type-fn (consumer-projection c)))
         (prev (make-hash-table :test 'equal)))
    (loop for o in (subseq all first last)
          for ty = (row-type-of type-fn o)
          for key = (presentation-key ty o)
          for container = (cat:row-container o)
          collect (let ((p (make-presentation
                            :key key :type ty :object o
                            :extent (cons container (gethash container prev))
                            :fingerprint (present o ty (consumer-view c))
                            :as-of as-of)))
                    (setf (gethash container prev) key)
                    p))))
