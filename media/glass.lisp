;;;; media/glass.lisp — the media player as framebuffer writes.
;;;;
;;;; THE PICTURE IS BLITTED HERE AND NOWHERE ELSE.  The frame's RGB rides on the domain object;
;;;; its fingerprint carries only the caption, the size and the frame number.  So a new frame is
;;;; one :changed delta on the picture's extent, this file paints it, and glass finds exactly that
;;;; rectangle dirty — which is also what the WebRTC encoder then ships as VP8 to a phone.  A
;;;; film decoded from VP8 by cassette, painted here, and encoded back to VP8 by webrtc-media:
;;;; the whole round trip is Lisp.
;;;;
;;;; Geometry snaps to 16 (rule 3): the picture band is 18 macroblocks tall, the transport 2, rows
;;;; 2, and the window is 32 wide — so every extent this encoding claims is exactly the set of
;;;; tiles glass will find dirty.

(defpackage #:warp-media-glass
  (:use #:cl #:warp)
  (:local-nicknames (#:m #:warp-media) (#:g #:warp-glass))
  (:export #:media-fb-consumer #:attach-fb #:make-media-window #:make-media-surface #:register
           #:+width+ #:+picture-h+ #:+row-h+ #:*library*))

(in-package #:warp-media-glass)

(defconstant +width+ 512 "32 macroblocks.")
(defconstant +picture-h+ 288 "18 macroblocks: 512 x 288 is 16:9.")
(defconstant +row-h+ 32 "2 macroblocks.")
(defconstant +control-w+ 48 "3 macroblocks per control.")

(defparameter +head-bg+ #x1e2530)
(defparameter +mat+ #x000000 "Behind the picture.")
(defparameter +playing+ #x5abe82)
(defparameter +control-bg+ #x232a36)

;;; ---- the consumer -----------------------------------------------------------------------------------

(defclass media-fb-consumer (m:media-consumer g:fb-consumer) ())

(defun attach-fb (projection &rest initargs)
  (apply #'warp:attach projection :class 'media-fb-consumer
         (append initargs (list :view 'm:media-view :row-height +row-h+))))

;;; ---- where things are ---------------------------------------------------------------------------------

(defmethod m:picture-height ((c media-fb-consumer)) (declare (ignore c)) +picture-h+)

(defmethod m:picture-place ((c media-fb-consumer))
  (snap-extent 0 0 (viewport-width c) +picture-h+))

(defun %transport-y (c) (if (m:has-picture-p c) +picture-h+ 0))

(defmethod m:transport-place ((c media-fb-consumer))
  ;; the title/clock row takes what the four controls leave
  (snap-extent 0 (%transport-y c) (- (viewport-width c) (* 4 +control-w+)) +row-h+))

(defmethod m:control-place ((c media-fb-consumer) kind)
  (let ((i (ecase kind (:prev 0) (:toggle 1) (:next 2) (:stop 3))))
    (snap-extent (+ (- (viewport-width c) (* 4 +control-w+)) (* i +control-w+))
                 (%transport-y c) +control-w+ +row-h+)))

(defconstant +seek-h+ 16 "The seek bar: one macroblock tall.")
(defparameter +seek-empty+ #x2a3240)
(defparameter +seek-filled+ #x5abe82)
(defparameter +seek-head+ #xdce4ec)

(defmethod m:seek-place ((c media-fb-consumer) index)
  (let ((cw (floor (viewport-width c) m:+seek-cells+)))
    (snap-extent (* index cw) (+ (%transport-y c) +row-h+) cw +seek-h+)))

(defmethod m:list-top ((c media-fb-consumer)) (+ (%transport-y c) +row-h+ +seek-h+))

(defmethod m:row-place ((c media-fb-consumer) index prev-key)
  (declare (ignore prev-key))
  (snap-extent 0 (+ (m:list-top c) (- (* index +row-h+) (consumer-scroll-y c)))
               (viewport-width c) +row-h+))

;;; ---- painting ---------------------------------------------------------------------------------------------

(defun %cell (p n) (nth n (p-fingerprint p)))

(defmethod g:paint (fb p (view (eql 'm:media-view)))
  (let* ((e (p-extent p))
         (x (extent-x e)) (y (extent-y e)) (w (extent-w e)) (h (extent-h e))
         (sel (getf (p-state p) :selected)))
    (ecase (p-type p)
      (m:media-picture (%paint-picture fb p x y w h))
      (m:media-transport
       (glass:fb-rect fb x y w h +head-bg+)
       (g:fb-text-baseline fb (+ x 8) (g:row-baseline y h 12) (%clip (princ-to-string (%cell p 0)) (- w 120) 6)
                           :size 12 :color g:+fg+)
       (let ((s (princ-to-string (%cell p 1))))
         (g:fb-text-baseline fb (- (+ x w) 8 (glass:text-width s :size 11)) (g:row-baseline y h 11) s
                             :size 11 :color (case (%cell p 2) (:playing +playing+) (:error g:+bad+) (t g:+dim+)))))
      (m:media-seek
       (glass:fb-rect fb x y w h g:+bg+)
       (glass:fb-rect fb x (+ y 6) w 4 (ecase (%cell p 0)
                                          (:empty +seek-empty+) (:filled +seek-filled+) (:head +seek-head+))))
      (m:media-control
       (glass:fb-rect fb x y w h (if sel g:+row-sel+ +control-bg+))
       (glass:fb-vline fb x y h g:+bg+)
       (let ((s (princ-to-string (%cell p 0))))
         (g:fb-text-baseline fb (+ x (floor (- w (glass:text-width s :size 13)) 2)) (g:row-baseline y h 13) s
                             :size 13 :color g:+fg+)))
      (m:media-head
       (glass:fb-rect fb x y w h +head-bg+)
       (g:fb-text-baseline fb (+ x 8) (g:row-baseline y h 12)
                           (format nil "~a ~a" (if (eq (%cell p 2) :up) "<" "") (%cell p 0))
                           :size 12 :color g:+fg+)
       (let ((s (princ-to-string (%cell p 1))))
         (g:fb-text-baseline fb (- (+ x w) 8 (glass:text-width s :size 10)) (g:row-baseline y h 10) s
                             :size 10 :color g:+dim+)))
      (m:media-dir
       (glass:fb-rect fb x y w h (if sel g:+row-sel+ g:+row-bg+))
       (g:fb-text-baseline fb (+ x 10) (g:row-baseline y h 12) (format nil "[ ~a ]" (%cell p 0))
                           :size 12 :color g:+fg+))
      (m:media-track
       (let ((st (%cell p 2)))
         (glass:fb-rect fb x y w h (if sel g:+row-sel+ g:+row-bg+))
         (g:fb-text-baseline fb (+ x 10) (g:row-baseline y h 12)
                             (format nil "~a ~a" (case st (:playing ">") (:paused "||") (:track " ") (t "*"))
                                     (%clip (princ-to-string (%cell p 0)) (- w 80) 6))
                             :size 12 :color (if (member st '(:playing :paused :loading)) +playing+ g:+fg+))
         (let ((s (princ-to-string (%cell p 1))))
           (g:fb-text-baseline fb (- (+ x w) 10 (glass:text-width s :size 10)) (g:row-baseline y h 10) s
                               :size 10 :color g:+dim+)))))))

(defun %clip (s px approx-char-w)
  (let ((max (max 1 (floor px approx-char-w))))
    (if (> (length s) max) (subseq s 0 max) s)))

(defun %paint-picture (fb p x y w h)
  "Rule 9's hole, filled: scale the frame into the band, letterboxed on black, and the caption
   in the bottom-left because the caption is the part that is true for everyone."
  (let* ((node (p-object p)) (f (m:node-frame node)))
    (cond
      ((null f)
       (glass:fb-rect fb x y w h +mat+)
       (g:fb-text-baseline fb (+ x 10) (+ y (floor h 2)) (princ-to-string (%cell p 0)) :size 11 :color g:+dim+))
      (t (%blit-frame fb f x y w h)))))

(defun %blit-frame (fb f x y w h)
  "Nearest-neighbour scale of the frame's RGB into the WxH band at (X,Y), aspect preserved.
   Writes the framebuffer's pixel vector directly: this runs 30 times a second."
  (declare (optimize (speed 3) (safety 0)))
  (let* ((fw (m:vf-w f)) (fh (m:vf-h f))
         (rgb (m:vf-rgb f))
         (scale (min (/ w fw) (/ h fh)))
         (dw (max 1 (floor (* fw scale)))) (dh (max 1 (floor (* fh scale))))
         (ox (+ x (floor (- w dw) 2))) (oy (+ y (floor (- h dh) 2)))
         (px (glass:fb-pixels fb)) (stride (glass:fb-width fb))
         (fbh (glass:fb-height fb)))
    (declare (type fixnum fw fh dw dh ox oy stride fbh)
             (type (simple-array (unsigned-byte 8) (*)) rgb)
             (type (simple-array (unsigned-byte 32) (*)) px))
    ;; the mat, where the picture does not reach
    (when (< dh h) (glass:fb-rect fb x y w (- oy y) +mat+) (glass:fb-rect fb x (+ oy dh) w (- (+ y h) oy dh) +mat+))
    (when (< dw w) (glass:fb-rect fb x oy (- ox x) dh +mat+) (glass:fb-rect fb (+ ox dw) oy (- (+ x w) ox dw) dh +mat+))
    (dotimes (dy dh)
      (let* ((sy (min (1- fh) (floor (* dy fh) dh)))
             (srow (* sy fw))
             (ty (+ oy dy)))
        (declare (type fixnum sy srow ty))
        (when (and (>= ty 0) (< ty fbh))
          (let ((drow (* ty stride)))
            (declare (type fixnum drow))
            (dotimes (dx dw)
              (let* ((sx (min (1- fw) (floor (* dx fw) dw)))
                     (si (* 3 (+ srow sx)))
                     (tx (+ ox dx)))
                (declare (type fixnum sx si tx))
                (when (and (>= tx 0) (< tx stride))
                  (setf (aref px (+ drow tx))
                        (logior (ash (aref rgb si) 16) (ash (aref rgb (+ si 1)) 8) (aref rgb (+ si 2)))))))))))
    (glass:fb-touch fb)))

;;; ---- a window -------------------------------------------------------------------------------------------------

(defvar *library* nil "The library the desktop's Media windows share, made on first open.")

(defun %session-mixer ()
  (let ((f (find-symbol "SESSION-MIXER" "GLASS")))
    (and f (fboundp f) (ignore-errors (funcall f)))))

(defun make-media-window (fb library &key (budget 3000) (invoker :owner) projection)
  "The WM surface contract: (values on-key on-pointer dirty-p copy-p close-fn consumer)."
  (let ((c (attach-fb (or projection (m:library-projection library)) :fb fb :budget budget :invoker invoker)))
    (glass:with-fb-locked (fb) (glass:fb-fill fb g:+bg+))
    (values
     (lambda (down keysym)
       (when down
         (case keysym
           (#xff1b (when (consumer-menu c) (close-menu c) t))                 ; Escape
           (#x20 (m:toggle (m:library-player library)) t)                    ; space
           (#xff51 (m:skip (m:library-player library) -10) t)                ; Left
           (#xff53 (m:skip (m:library-player library) 10) t)                 ; Right
           (t nil))))
     (lambda (mask x y) (g:on-pointer c mask x y))
     (lambda () (and (tick c) t))
     nil
     (lambda () (detach c))
     c)))

(defun make-media-surface (fb)
  "MAKE-FN for ADD-SURFACE / REGISTER-APP: one shared library on the session mixer."
  (unless *library*
    (setf *library* (m:make-library :mixer (%session-mixer))))
  (make-media-window fb *library*))

(defun register (&key (label "Media") (width +width+) (height 640))
  "Put the player in the glass desktop's root menu, as a surface app — no McCLIM anywhere."
  (let ((fn (and (find-package "CLIM-GLASS") (find-symbol "REGISTER-APP" "CLIM-GLASS"))))
    (when (and fn (fboundp fn))
      (funcall fn label (list :surface #'make-media-surface :title label :width width :height height))
      label)))
