;;;; media/dom.lisp — the media player as JSON deltas in somebody else's browser.
;;;;
;;;; THE THIRD FACET OF THE SAME APP.  warp-media/glass blits the decoded frame; this one cannot,
;;;; and is not going to be given a way to — the wire is JSON cells and "binary payloads" is an
;;;; open question in DESIGN.md, not an omission.  So the picture arrives as rule 9's opaque node:
;;;; the caption ("Big Buck Bunny — 640 x 360, frame 812"), the dimensions, and the frame number,
;;;; and nothing else.  A client draws a box with that caption in it.
;;;;
;;;; WHAT IS DIFFERENT FROM warp-files/dom.  The file browser nests, so its positional claim is one
;;;; container per column.  The player does not nest: it is three BANDS in running order — the
;;;; picture, the transport with its controls, the list — and the browser lays them out itself.  So
;;;; every presentation lands in ONE container, "rows", and the order is the sibling chain.  That is
;;;; the same (parent . after) the flat device manager uses, which is the point: an encoding that
;;;; has no geometry still has an ORDER, and the order is what the reconciler diffs.
;;;;
;;;; THE UNIT IS ROWS, NOT PIXELS.  The framebuffer's layout seam is in pixels because a framebuffer
;;;; has pixels; a browser reports how many rows fit and scrolls the rest.  So this file overrides
;;;; the two methods whose media-consumer defaults are in pixels — VISIBLE-LIST-ROWS and
;;;; CONTENT-HEIGHT — and leaves the rest of the seam (the PLACE generics) unused, because a
;;;; browser does its own layout and a server that shipped rectangles would be shipping a claim the
;;;; client is entitled to ignore.

(defpackage #:warp-media-dom
  (:use #:cl #:warp)
  (:local-nicknames (#:m #:warp-media) (#:d #:warp-dom))
  (:export #:media-dom-consumer #:attach-dom))

(in-package #:warp-media-dom)

(defclass media-dom-consumer (m:media-consumer d:dom-consumer) ()
  (:documentation "The player's bands as sibling lists in a browser.  A media layout mixed in FRONT
of DOM-CONSUMER, exactly as the file browser mixes MILLER-CONSUMER in front of it."))

(defun attach-dom (projection &rest initargs)
  "WARP:ATTACH with this file's encoding as the class.  INITARGS first: MAKE-INSTANCE takes the
leftmost of a duplicated initarg, so a default placed before a caller's argument would win over it."
  (apply #'warp:attach projection :class 'media-dom-consumer
         (append initargs (list :view 'm:media-view))))

;;; ---- the unit is rows ------------------------------------------------------

(defmethod m:visible-list-rows ((c media-dom-consumer))
  "The list band's visible range, in ROWS.  MEDIA-CONSUMER's method is in pixels — it divides the
viewport by ROW-HEIGHT — and would ask for a thirty-second of the rows the browser can show."
  (let ((s (max 0 (consumer-scroll-y c))))
    (values s (+ s (viewport-height c)))))

(defmethod content-height ((c media-dom-consumer))
  "In ROWS, not pixels: the number of list rows, which is what the browser scrolls against."
  (count-if (lambda (o) (typep o 'm:media-row)) (projection-objects (consumer-projection c))))

;;; ---- lay-out: the bands, in order, with no geometry ------------------------

(defmethod lay-out ((c media-dom-consumer) objects as-of)
  "The same bands the framebuffer paints, with (parent . after) where it had rectangles.

The picture is emitted only while the track has one — a song has no picture band, and the node is
still in the result-set but this consumer gives it no place.  The list is sliced to what the browser
says it can show, which is rule 8's consumer-negotiated working set arrived at from the browser end."
  (let ((sel (consumer-selected c)) (out '()) (i 0) (prev nil) (view (consumer-view c)))
    (multiple-value-bind (lo hi) (m:visible-list-rows c)
      (dolist (o objects)
        (let* ((ty (m:row-type o)) (key (presentation-key ty o)) (emit t))
          (etypecase o
            (m:picture-node (unless (m:has-picture-p c) (setf emit nil)))
            (m:transport)
            (m:media-button)
            (m:seek-cell)
            (m:media-row
             (unless (<= lo i (1- hi)) (setf emit nil))
             (incf i)))
          (when emit
            (let ((p (make-presentation :key key :type ty :object o
                                        :extent (cons d::+rows-container+ prev)
                                        :fingerprint (present o ty view) :as-of as-of)))
              (when (equal sel key) (setf (p-state p) (list :selected t)))
              (setf prev key)
              (push p out))))))
    (nreverse out)))