;;;; glass/surface.lisp — warp's glass surface: deltas become framebuffer writes.
;;;;
;;;; This is the encoding half.  The delta stream decides WHAT travels; this decides how it lands in
;;;; pixels.  The important discipline is that a pass paints ONLY the extents the stream emitted —
;;;; never the whole view — because glass discovers damage by diffing tiles against its snapshot and
;;;; ships the dirty ones.  So glass independently CHECKS warp: if the reconciler is right, the tiles
;;;; glass finds dirty are the extents warp emitted, and nothing else.
;;;;
;;;; Input is the interim mapping.  DESIGN.md rule 5 wants semantic gestures recognized on the phone
;;;; and carried on the wire; today the client flattens them into RFB pointer events, so until that
;;;; protocol change lands: button 1 = tap, button 3 = hold (the menu).  Recognition still happens at
;;;; the edge — we are just receiving it in a lossy encoding.

(in-package #:warp-glass)

(defparameter +bg+     #x0c0e12)
(defparameter +row-bg+ #x161a20)
(defparameter +row-sel+ #x26303c)
(defparameter +fg+     #xdce4ec)
(defparameter +dim+    #x8a949c)
(defparameter +ok+     #x5abe82)
(defparameter +warn+   #xfabe3c)
(defparameter +bad+    #xf04646)

(defun trend-colour (trend)
  (case trend (:bad +bad+) (:warn +warn+) (t +ok+)))

;;; ---- painting --------------------------------------------------------------
;;; PAINT is the counterpart of PRESENT: present decides what a thing says, paint decides how it
;;; looks.  Keeping them apart is what lets the content double as the fingerprint.

(defgeneric paint (fb presentation view)
  (:documentation "Draw PRESENTATION into FB.  Called only for extents the delta stream emitted."))

(defmethod paint (fb p view)
  "Default: the content lines, small and plain — the visual counterpart of the MOP slot walk."
  (declare (ignorable view))
  (let* ((e (warp:p-extent p)) (x (warp::extent-x e)) (y (warp::extent-y e))
         (w (warp::extent-w e)) (h (warp::extent-h e)))
    (glass:fb-rect fb x y w h +row-bg+)
    (loop for line in (warp:p-fingerprint p)
          for i from 0
          while (< (* i 12) h)
          do (glass:fb-text fb (+ x 8) (+ y 12 (* i 12)) (princ-to-string line)
                            :size 11 :color +fg+))))

(defun clear-extent (fb e)
  (glass:fb-rect fb (warp::extent-x e) (warp::extent-y e)
                 (warp::extent-w e) (warp::extent-h e) +bg+))

;;; ---- the surface -----------------------------------------------------------

(defstruct (surface (:conc-name sf-))
  fb port name view
  rows-fn                       ; () -> the current result-set (presentations)
  (stream (warp:make-delta-stream))
  (visible '())                 ; last emitted set, for hit-testing
  (selected nil)
  (budget 400)
  (invoker :allowlist)
  (lock (bt:make-lock))
  (painted 0) (emitted 0) (passes 0)
  (stop nil))

(defun hit (sf x y)
  "The presentation under (X,Y), or NIL.  Reverse order so the topmost wins."
  (find-if (lambda (p)
             (let ((e (warp:p-extent p)))
               (and e (<= (warp::extent-x e) x (+ (warp::extent-x e) (warp::extent-w e) -1))
                    (<= (warp::extent-y e) y (+ (warp::extent-y e) (warp::extent-h e) -1)))))
           (reverse (sf-visible sf))))

(defun apply-deltas (sf deltas)
  "Paint exactly what the stream emitted, and nothing else."
  (let ((fb (sf-fb sf)))
    (glass:with-fb-locked (fb)
      (dolist (d deltas)
        (ecase (warp:delta-kind d)
          ((:appeared :changed)
           (paint fb (warp:delta-presentation d) (sf-view sf))
           (incf (sf-painted sf)))
          (:moved
           ;; No blit yet: repaint at the new extent and clear where it came from.  The :moved KIND
           ;; is still the right thing to carry — it is what a CopyRect or a motion vector will use
           ;; once the encoder can see a translation (DESIGN.md rule 2).
           (let* ((p (warp:delta-presentation d)) (e (warp:p-extent p)))
             (clear-extent fb (list (- (warp::extent-x e) (warp:delta-dx d))
                                    (- (warp::extent-y e) (warp:delta-dy d))
                                    (warp::extent-w e) (warp::extent-h e)))
             (paint fb p (sf-view sf))
             (incf (sf-painted sf))))
          (:gone
           (clear-extent fb (warp:delta-extent d))
           (incf (sf-painted sf))))))))

(defun tick (sf)
  "One pass: recompute the result-set, emit what is owed under budget, paint only that."
  (bt:with-lock-held ((sf-lock sf))
    (let ((rows (funcall (sf-rows-fn sf))))
      (multiple-value-bind (deltas deferred) (warp:emit (sf-stream sf) rows :budget (sf-budget sf))
        (declare (ignore deferred))
        (incf (sf-passes sf))
        (incf (sf-emitted sf) (length deltas))
        (setf (sf-visible sf) rows)
        (when deltas (apply-deltas sf deltas))
        deltas))))

(defun on-pointer (sf mask x y)
  "Interim gesture mapping (see the file header): button 1 = tap, button 3 = hold."
  (let ((p (hit sf x y)))
    (when p
      (let ((gesture (cond ((logtest mask 1) :tap) ((logtest mask 4) :hold) (t nil))))
        (when gesture
          (multiple-value-bind (kind payload)
              (warp:gesture-command gesture (warp:p-type p) (sf-view sf) :invoker (sf-invoker sf))
            (case kind
              (:invoke
               ;; the declared default — guaranteed non-destructive by warp
               (setf (sf-selected sf) (warp:p-key p))
               (handler-case (warp:invoke (warp:cmd-name payload) (warp:p-object p) (sf-invoker sf))
                 (warp:command-refused (c)
                   (format *error-output* "~&[warp] ~a~%" c))))
              (:menu
               ;; a real menu is the next piece of surface work; for now report what WOULD be offered,
               ;; which is already the useful half — it proves applicability and filtering are live
               (format *error-output* "~&[warp] hold on ~a -> ~{~a~^, ~}~%"
                       (warp:p-key p)
                       (mapcar #'warp:cmd-label payload))
               (finish-output *error-output*))
              (t nil))))))))

(defun run (&key (port 5910) (width 480) (height 448) (name "warp") view rows-fn
                 (hz 4) (budget 400) (invoker :allowlist))
  "Serve a warp surface over RFB on PORT.  Returns the SURFACE; the paint loop and the RFB server
each run on their own thread."
  (let* ((fb (glass:make-framebuffer width height +bg+))
         (sf (make-surface :fb fb :port port :name name :view view :rows-fn rows-fn
                           :budget budget :invoker invoker)))
    (bt:make-thread
     (lambda ()
       (handler-case
           (glass:serve fb port :name name
                        :on-pointer (lambda (mask x y) (on-pointer sf mask x y)))
         (error (e) (format *error-output* "~&[warp] serve: ~a~%" e))))
     :name "warp-rfb")
    (bt:make-thread
     (lambda ()
       (loop until (sf-stop sf) do
         (handler-case (tick sf)
           (error (e) (format *error-output* "~&[warp] tick: ~a~%" e)))
         (sleep (/ 1.0 hz))))
     :name "warp-paint")
    sf))
