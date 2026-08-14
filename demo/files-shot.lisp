;;;; demo/files-shot.lisp — a picture of client two: real columns of real files, offscreen.
;;;;
;;;; Builds a fixture tree under /tmp out of REAL files (warp's own sources, copied in, so the names
;;;; and byte counts on screen are genuine), drills two levels, selects an image, runs ONE warp pass,
;;;; and writes the framebuffer to a PNG.  No RFB server is started and no live process is touched.
;;;;
;;;;   sbcl --non-interactive --load demo/files-shot.lisp [output.png]

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream)))
    (asdf:load-system :warp-files/glass)))

(defpackage #:warp-files-shot (:use #:cl #:warp)) (in-package #:warp-files-shot)

(defparameter *root* #p"/tmp/warp-files-demo/")
(defparameter *out*
  (or (second sb-ext:*posix-argv*) "/tmp/warp-files-demo.png"))

(defun copy-in (from to)
  (ensure-directories-exist to)
  (with-open-file (i from :element-type '(unsigned-byte 8))
    (with-open-file (o to :direction :output :element-type '(unsigned-byte 8)
                         :if-exists :supersede :if-does-not-exist :create)
      (let ((buf (make-array (file-length i) :element-type '(unsigned-byte 8))))
        (read-sequence buf i) (write-sequence buf o)))))

(defun swatch (path w h fn)
  (let* ((cv (scribe:make-canvas w h)) (d (scribe:canvas-pixels cv)))
    (dotimes (y h)
      (dotimes (x w)
        (multiple-value-bind (r g b) (funcall fn x y w h)
          (let ((i (* 3 (+ (* y w) x))))
            (setf (aref d i) r (aref d (+ i 1)) g (aref d (+ i 2)) b)))))
    (ensure-directories-exist path)
    (scribe:write-png cv path)))

(defun build ()
  (when (probe-file *root*)
    (uiop:delete-directory-tree *root* :validate (lambda (p) (uiop:subpathp p #p"/tmp/"))))
  (ensure-directories-exist *root*)
  ;; real sources, so the sizes in the middle column are real
  (dolist (f (directory "/home/claude/warp/src/*.lisp"))
    (copy-in f (merge-pathnames (format nil "engine/core/~a" (file-namestring f)) *root*)))
  (dolist (f (directory "/home/claude/warp/dom/*.lisp"))
    (copy-in f (merge-pathnames (format nil "engine/dom/~a" (file-namestring f)) *root*)))
  (copy-in "/home/claude/warp/DESIGN.md" (merge-pathnames "engine/DESIGN.md" *root*))
  (copy-in "/home/claude/warp/README.md" (merge-pathnames "README.md" *root*))
  (ensure-directories-exist (merge-pathnames "notes/" *root*))
  (with-open-file (s (merge-pathnames "notes/todo.txt" *root*) :direction :output
                                                               :if-exists :supersede)
    (write-string "nesting; opaque nodes" s))
  ;; and some real images for the preview pane
  (swatch (merge-pathnames "engine/assets/gradient.png" *root*) 320 200
          (lambda (x y w h) (values (floor (* 255 x) w) (floor (* 255 y) h) 140)))
  (swatch (merge-pathnames "engine/assets/rings.png" *root*) 256 256
          (lambda (x y w h)
            (let ((d (isqrt (+ (* (- x (floor w 2)) (- x (floor w 2)))
                               (* (- y (floor h 2)) (- y (floor h 2)))))))
              (values (mod (* d 7) 256) (- 255 (mod (* d 5) 256)) (mod (* d 11) 256)))))
  (swatch (merge-pathnames "engine/assets/checks.png" *root*) 200 150
          (lambda (x y w h) (declare (ignore w h))
            (if (evenp (+ (floor x 20) (floor y 20))) (values 230 230 240) (values 40 60 90))))
  *root*)

(build)

;;; ---- one browser, one projection, one framebuffer consumer ----------------------------------

(defvar *b* (warp-files:make-browser *root*))
(defvar *proj* (warp-files:browse-projection *b*))
(defvar *fb* (glass:make-framebuffer 928 512 warp-glass:+bg+))
(defvar *c* (warp-files-glass:attach-fb *proj* :fb *fb* :budget 100000 :invoker :owner))
(glass:with-fb-locked (*fb*) (glass:fb-fill *fb* warp-glass:+bg+))

;;; Navigate the way a finger would: two taps on directory rows, through the gesture path, so what
;;; is on screen is what the protocol produced and not a state somebody set up by hand.
(defun tap-named (name)
  (tick *c*)
  (let ((p (find-if (lambda (p) (and (member (p-type p) '(warp-files:fs-dir warp-files:fs-file))
                                     (equal name (first (p-fingerprint p)))))
                    (consumer-visible *c*))))
    (unless p (error "no row named ~s on screen" name))
    (on-gesture *c* :tap p)
    (tick *c*)
    p))

(tap-named "engine")
(tap-named "assets")
(tap-named "rings.png")
(warp-files:focus-on *c* 2)

(let ((deltas (tick *c*)))
  (declare (ignorable deltas))
  (format t "~&columns on screen : ~d~%" (length (warp-files:columns-of (projection-objects *proj*))))
  (format t "rows painted      : ~d~%" (length (consumer-visible *c*)))
  (format t "queries run       : ~d~%" (projection-queries *proj*))
  (format t "deltas landed     : ~d~%" (consumer-landed *c*))
  (let ((pv (find 'warp-files:fs-preview (consumer-visible *c*) :key #'p-type)))
    (when pv
      (format t "opaque node       : ~s~%" (first (p-fingerprint pv)))
      (format t "  its pixels are on the OBJECT (~a), never in the fingerprint~%"
              (let ((i (warp-files:opaque-pixels (p-object pv))))
                (if i (format nil "~dx~d" (pigment:img-w i) (pigment:img-h i)) "none"))))))

(warp-files-glass:save-fb-png *fb* *out*)
(format t "~&wrote ~a~%" *out*)
