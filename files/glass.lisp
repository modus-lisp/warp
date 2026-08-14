;;;; files/glass.lisp — Miller columns as framebuffer writes.
;;;;
;;;; The positional claim here is a grid-snapped rectangle, which is rule 3 unchanged: columns are
;;;; 224px (14 macroblocks) and rows are 32px (2), so SNAP-EXTENT is a no-op and every extent this
;;;; encoding declares is exactly the set of tiles glass will find dirty.  That invariant — a pass
;;;; paints ONLY what the stream emitted — is what lets glass independently check warp, and nesting
;;;; does not weaken it: a column is a range of x, not a new kind of thing.
;;;;
;;;; DELIBERATELY NOT the weft path.  DESIGN.md rule 9 names weft as the default rasterizer and a
;;;; hand-written PAINT as the specialization; the hand-written one is used here on purpose, because
;;;; adding a DOM->pixels path in the same change would confound the nesting measurement with a
;;;; whole new layout engine.  `warp-weft` deserves its own change and its own numbers.
;;;;
;;;; THE OPAQUE NODE IS BLITTED HERE AND NOWHERE ELSE.  Its pixels ride on the domain object, never
;;;; in the fingerprint, so this is the only file in warp that can see them — which is the point of
;;;; rule 9's facet bundle: the blit is a local privilege, and the caption is what travels.

(defpackage #:warp-files-glass
  (:use #:cl #:warp)
  (:local-nicknames (#:f #:warp-files) (#:g #:warp-glass))
  (:export #:files-fb-consumer #:attach-fb #:make-files-window #:save-fb-png
           #:+col-w+ #:+row-h+ #:+preview-h+))

(in-package #:warp-files-glass)

(defconstant +col-w+ 224 "Column width: 14 macroblocks, so rule 3's snap is a no-op.")
(defconstant +row-h+ 32  "Row height: 2 macroblocks.")
(defconstant +preview-h+ 176 "The opaque pane: 11 macroblocks tall.")

(defparameter +head-bg+    #x1e2530)
(defparameter +head-focus+ #x2d3a4c)
(defparameter +dir-mark+   #x7fa8d8)
(defparameter +hole+       #x11151b "The opaque node's mat — deliberately not the row colour.")

;;; ---- the consumer -----------------------------------------------------------------------------
;;; MILLER-CONSUMER first, so its LAY-OUT wins over core's vertical list; G:FB-CONSUMER second, so
;;; its APPLY-DELTAS satisfies core's "a consumer must have somewhere to put deltas" check and its
;;; VIEWPORT-WIDTH/HEIGHT read the framebuffer.

(defclass files-fb-consumer (f:miller-consumer g:fb-consumer) ()
  (:documentation "Miller columns painted into a glass framebuffer."))

(defun attach-fb (projection &rest initargs)
  "INITARGS come BEFORE the defaults, because MAKE-INSTANCE takes the LEFTMOST of a duplicated
initarg — put the defaults first and a caller's :ROW-HEIGHT is silently ignored."
  (apply #'warp:attach projection :class 'files-fb-consumer
         (append initargs (list :view 'f:files-view :row-height +row-h+ :column-w +col-w+))))

;;; ---- where things are -------------------------------------------------------------------------

(defmethod f:row-place ((c files-fb-consumer) column row-index prev-key)
  (declare (ignore prev-key))
  (snap-extent (* (f:column-index column) (f:column-w c))
               (- (* row-index (consumer-row-height c)) (consumer-scroll-y c))
               (f:column-w c)
               (consumer-row-height c)))

(defmethod f:preview-place ((c files-fb-consumer) column-index prev-key)
  (declare (ignore prev-key))
  (snap-extent (* column-index (f:column-w c))
               (- (consumer-row-height c) (consumer-scroll-y c))
               (f:column-w c) +preview-h+))

;;; ---- painting ---------------------------------------------------------------------------------
;;; PAINT dispatches on (fb presentation view) and a presentation is a struct, so the type branch is
;;; inside rather than on the lambda list.  That is core's seam as it stands, not a preference.

(defun %row-bg (p)
  (let ((st (p-state p)))
    (cond ((getf st :selected) g:+row-sel+)
          ((getf st :focused) +head-focus+)
          ((eq (p-type p) 'f:fs-head) +head-bg+)
          (t g:+row-bg+))))

(defun %cell (p n) (nth n (p-fingerprint p)))

(defmethod g:paint (fb p (view (eql 'f:files-view)))
  (let* ((e (p-extent p))
         (x (extent-x e)) (y (extent-y e)) (w (extent-w e)) (h (extent-h e)))
    (glass:fb-rect fb x y w h (%row-bg p))
    ;; a 1px rule down the right edge of every column, drawn INSIDE the extent
    (glass:fb-vline fb (+ x w -1) y h g:+bg+)
    (ecase (p-type p)
      (f:fs-head
       (g:fb-text-baseline fb (+ x 8) (g:row-baseline y h 12) (princ-to-string (%cell p 0))
                           :size 12 :color g:+fg+)
       (let ((s (princ-to-string (%cell p 1))))
         (g:fb-text-baseline fb (- (+ x w) 8 (glass:text-width s :size 10))
                             (g:row-baseline y h 10) s :size 10 :color g:+dim+)))
      (f:fs-dir
       (g:fb-text-baseline fb (+ x 10) (g:row-baseline y h 12) (princ-to-string (%cell p 0))
                           :size 12 :color g:+fg+)
       (g:fb-text-baseline fb (- (+ x w) 16) (g:row-baseline y h 12) ">" :size 12
                           :color +dir-mark+))
      (f:fs-file
       (g:fb-text-baseline fb (+ x 10) (g:row-baseline y h 12) (princ-to-string (%cell p 0))
                           :size 12 :color g:+fg+)
       (let ((s (princ-to-string (%cell p 1))))
         (g:fb-text-baseline fb (- (+ x w) 10 (glass:text-width s :size 10))
                             (g:row-baseline y h 10) s :size 10 :color g:+dim+)))
      (f:fs-preview (%paint-opaque fb p x y w h)))))

(defun %paint-opaque (fb p x y w h)
  "Rule 9's hole, filled.  This encoding CAN blit, so it does — and it still paints the app's
caption underneath, because the caption is the part of this node that is true for everyone."
  (glass:fb-rect fb x y w h +hole+)
  (glass:fb-frame fb x y w h g:+row-bg+ 1)
  (let* ((node (p-object p))
         (img (f:opaque-pixels node))
         (cap (princ-to-string (%cell p 0)))
         (text-y (+ y h -10)))
    (if img
        (%blit fb img
               (+ x (floor (- w (pigment:img-w img)) 2))
               (+ y 8))
        ;; no pixels to blit: say so where the picture would have been, rather than leaving a hole
        ;; in the hole.  Same discipline as the DOM's placeholder, one encoding up.
        (g:fb-text-baseline fb (+ x 10) (+ y (floor h 2)) "(no preview)" :size 11 :color g:+dim+))
    ;; the caption, clipped to the pane by character count rather than overflowing the extent
    (let ((max (max 1 (floor (- w 16) 5))))
      (g:fb-text-baseline fb (+ x 8) text-y
                          (if (> (length cap) max) (subseq cap 0 max) cap)
                          :size 10 :color g:+dim+))))

(defun %blit (fb img dx dy)
  "A PIGMENT:IMG onto the framebuffer, opaque pixels only.  The thumbnail was pre-scaled by warren's
own DECODE-PREVIEW-THUMB, so this is a copy and never a resample."
  (let* ((iw (pigment:img-w img)) (ih (pigment:img-h img)) (px (pigment:img-rgba img)))
    (dotimes (yy ih)
      (dotimes (xx iw)
        (let ((i (* 4 (+ (* yy iw) xx))))
          (when (> (aref px (+ i 3)) 127)
            (glass:fb-put fb (+ dx xx) (+ dy yy)
                          (glass:rgb (aref px i) (aref px (+ i 1)) (aref px (+ i 2))))))))))

;;; ---- a window ---------------------------------------------------------------------------------

(defun make-files-window (fb browser &key (budget 4000) (invoker :owner) projection)
  "The WM surface contract, as WARP-GLASS:MAKE-SURFACE-APP gives it: (values on-key on-pointer
dirty-p consumer).  Pass PROJECTION to seat this window at a browser somebody is already looking at."
  (let ((c (attach-fb (or projection (f:browse-projection browser))
                      :fb fb :budget budget :invoker invoker)))
    (glass:with-fb-locked (fb) (glass:fb-fill fb g:+bg+))
    (values
     (lambda (down keysym)
       (when (and down (= keysym #xff1b) (consumer-menu c)) (close-menu c) t))
     (lambda (mask x y)
       ;; focus follows the column the finger landed in — this consumer's view state, and nobody
       ;; else's, which is the whole of rule 7 applied to a dimension a flat list did not have
       (setf (f:focus-column c) (floor x (f:column-w c)))
       (g:on-pointer c mask x y))
     (lambda () (and (tick c) t))
     c)))

;;; ---- a picture of it --------------------------------------------------------------------------

(defun save-fb-png (fb path)
  "The framebuffer to a PNG, offscreen — no RFB server, no viewer, no live process touched.  Via
scribe's canvas because warp-glass already depends on scribe; glass's own inspect/ helpers use zpng,
which would be a new dependency for a screenshot."
  (let* ((w (glass:fb-width fb)) (h (glass:fb-height fb)) (px (glass:fb-pixels fb))
         (cv (scribe:make-canvas w h))
         (d (scribe:canvas-pixels cv)))
    (dotimes (y h)
      (dotimes (x w)
        (let ((v (aref px (+ (* y w) x))) (i (* 3 (+ (* y w) x))))
          (setf (aref d i)       (ldb (byte 8 16) v)
                (aref d (+ i 1)) (ldb (byte 8 8) v)
                (aref d (+ i 2)) (ldb (byte 8 0) v)))))
    (scribe:write-png cv path)
    path))
