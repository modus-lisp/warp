;;;; media/layout.lisp — the consumer with no encoding: what is where, in running order.
;;;;
;;;; Three bands: the PICTURE (present only while the track has one), the TRANSPORT with its four
;;;; controls beside it, and the LIST, which is the only band that scrolls.  Where each lands is
;;;; an encoding's claim (rule 2's correction) and comes through the generics below; this file
;;;; decides only which presentations exist and what each one's key, type and fingerprint are.

(in-package #:warp-media)

(defclass media-consumer (consumer)
  ()
  (:documentation "The player's layout with no encoding target.  ABSTRACT: mix it in FRONT of an
encoding's consumer class."))

;;; ---- the seam --------------------------------------------------------------------------------------

(defgeneric picture-height (consumer)
  (:documentation "How tall the picture band is in this consumer's units when there is a picture."))
(defgeneric picture-place (consumer)
  (:documentation "Where the picture goes."))
(defgeneric transport-place (consumer)
  (:documentation "Where the title/clock row goes."))
(defgeneric control-place (consumer kind)
  (:documentation "Where the control KIND (:prev :toggle :next :stop) goes."))
(defgeneric seek-place (consumer index)
  (:documentation "Where the INDEX-th seek cell goes."))
(defgeneric list-top (consumer)
  (:documentation "Where the list band starts, in this consumer's units."))
(defgeneric row-place (consumer index prev-key)
  (:documentation "Where the INDEX-th list row goes, following PREV-KEY."))
(defgeneric visible-list-rows (consumer)
  (:documentation "(values LO HI): the half-open range of list rows this consumer can show."))

(defun has-picture-p (c)
  (player-has-video-p (library-player (%consumer-library c))))

(defun %consumer-library (c)
  ;; the library is on every object the query returns; the transport is always there
  (let ((tr (find-if (lambda (o) (typep o 'transport)) (projection-objects (consumer-projection c)))))
    (and tr (transport-library tr))))

(defmethod visible-list-rows ((c media-consumer))
  (let ((rh (consumer-row-height c)) (s (consumer-scroll-y c)))
    (values (max 0 (floor s rh))
            (ceiling (+ s (max 0 (- (viewport-height c) (list-top c)))) rh))))

;;; ---- lay-out ---------------------------------------------------------------------------------------

(defmethod lay-out ((c media-consumer) objects as-of)
  (let ((sel (consumer-selected c)) (out '()) (i 0) (prev nil) (view (consumer-view c)))
    (multiple-value-bind (lo hi) (visible-list-rows c)
      (dolist (o objects)
        (let* ((ty (row-type o)) (key (presentation-key ty o)) (extent nil) (emit t))
          (etypecase o
            (picture-node
             ;; no picture band at all for a song: the node is still in the result-set, but this
             ;; consumer gives it no place and does not emit it
             (if (has-picture-p c) (setf extent (picture-place c)) (setf emit nil)))
            (transport (setf extent (transport-place c)))
            (media-button (setf extent (control-place c (button-kind o))))
            (seek-cell (setf extent (seek-place c (cell-index o))))
            (media-row
             (if (<= lo i (1- hi))
                 (setf extent (row-place c i prev))
                 (setf emit nil))
             (setf prev key)
             (incf i)))
          (when emit
            (let ((p (make-presentation :key key :type ty :object o :extent extent
                                        :fingerprint (present o ty view) :as-of as-of)))
              (when (equal sel key) (setf (p-state p) (list :selected t)))
              (push p out))))))
    (nreverse out)))

(defmethod content-height ((c media-consumer))
  (* (count-if (lambda (o) (typep o 'media-row)) (projection-objects (consumer-projection c)))
     (consumer-row-height c)))
