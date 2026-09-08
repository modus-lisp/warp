;;;; quire/dom.lisp — the document as nested sibling lists: one container per part.
;;;;
;;;; ==================================================================================
;;;; WHAT THIS FILE IS FOR, AND WHY IT IS NOT IN doc.lisp
;;;; ==================================================================================
;;;;
;;;; doc.lisp has a ROW-CONTAINER function and nothing calls it, which is the correct shape
;;;; and looked like a bug until the layout was written.  A container is a POSITIONAL CLAIM,
;;;; and rule 2 puts positional claims in the consumer: the projection says what the rows ARE,
;;;; and where they go is the business of whoever is looking.  A framebuffer consumer would
;;;; place these parts as stacked bands with y-coordinates; this one names them.
;;;;
;;;; So doc.lisp offers the NAME and this file makes the CLAIM, the same split warp-files has
;;;; between COLUMN-PATH and its ROW-PLACE method.
;;;;
;;;; ==================================================================================
;;;; PREV IS PER CONTAINER, AND GETTING THAT WRONG IS SILENT
;;;; ==================================================================================
;;;;
;;;; DOM-CONSUMER's own LAY-OUT threads one PREV through the whole slice, which is right for a
;;;; flat list: every row is a sibling of the one before it.  Here the rows are partitioned
;;;; across containers, and `after' orders siblings WITHIN one container (§10.4: "after orders
;;;; siblings within one container and says nothing across them").
;;;;
;;;; Thread one PREV across parts and every container's first row claims to follow the last row
;;;; of the PREVIOUS part -- a key that is not its sibling and that the client will not find in
;;;; that container.  The client's own rule ("a container the client holds that cs does not
;;;; mention keeps its relative place") means this does not crash; it silently orders rows by
;;;; whatever the DOM did with an unresolvable anchor.  A hash of last-key-per-container is the
;;;; whole fix and it is three lines, but it is three lines that a flat client had no reason to
;;;; have and no way to miss.

(defpackage #:warp-quire-dom
  (:use #:cl #:warp)
  (:local-nicknames (#:q #:warp-quire) (#:d #:warp-dom))
  (:export #:quire-dom-consumer #:attach-dom))

(in-package #:warp-quire-dom)

(defclass quire-dom-consumer (d:dom-consumer) ()
  (:documentation "A compound document as JSON deltas: one container per part."))

(defun attach-dom (projection &rest initargs)
  "INITARGS first: MAKE-INSTANCE takes the leftmost of a duplicated initarg, so a default
placed before a caller's argument would win over it."
  (apply #'warp:attach projection :class 'quire-dom-consumer
         (append initargs (list :view 'q:quire-view))))

(defmethod lay-out ((c quire-dom-consumer) objects as-of)
  "The slice, partitioned into one container per part, in document order.

The SLICE ITSELF IS STILL FLAT -- objects[scroll .. scroll+rows) -- because scrolling a
document scrolls the document, not each part independently.  That is the difference from
warp-files, where the slice is per column because the columns scroll separately, and it is
why this cannot just inherit MILLER-CONSUMER: same nesting mechanism, opposite scroll model."
  (let* ((all objects)
         (n (length all))
         (first (max 0 (min (consumer-scroll-y c) n)))
         (last (min n (+ first (viewport-height c))))
         (type-fn (projection-type-fn (consumer-projection c)))
         (sel (consumer-selected c))
         (prev (make-hash-table :test 'equal)))    ; container -> its last key so far
    (loop for o in (subseq all first last)
          for ty = (row-type-of type-fn o)
          for key = (presentation-key ty o)
          for container = (q:row-container o)
          collect (let ((p (make-presentation
                            :key key :type ty :object o
                            :extent (cons container (gethash container prev))
                            :fingerprint (present o ty (consumer-view c))
                            :as-of as-of)))
                    (when (equal sel key) (setf (p-state p) (list :selected t)))
                    (setf (gethash container prev) key)
                    p))))
