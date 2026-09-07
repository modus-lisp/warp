;;;; demo/media-run.lisp — the media player against the wall clock: a REAL glass session mixer
;;;; pulling the source every 20 ms, a framebuffer consumer ticked at the desktop's 60 Hz, Big Buck
;;;; Bunny at 640x360 for a few seconds.  Reports how many pictures were shown against how many
;;;; the file has for that span, and saves a screenshot.
;;;;   sbcl --dynamic-space-size 2048 --non-interactive --load demo/media-run.lisp [FILE] [SECONDS]

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream)))
    (asdf:load-system :warp-media/glass)))

(defpackage #:warp-media-run (:use #:cl #:warp)) (in-package #:warp-media-run)

(defvar *file* (or (second sb-ext:*posix-argv*)
                   (namestring (merge-pathnames "cassette/vectors/bbb360.webm" (user-homedir-pathname)))))
(defvar *seconds* (or (ignore-errors (parse-integer (third sb-ext:*posix-argv*))) 5))

(defvar *mixer* (glass:session-mixer))            ; started: its thread pulls sources every 20 ms
(defvar *lib* (warp-media:make-library :root (directory-namestring *file*) :mixer *mixer*))
(defvar *player* (warp-media:library-player *lib*))
(defvar *fb* (glass:make-framebuffer warp-media-glass:+width+ 640))

(multiple-value-bind (on-key on-pointer dirty-p) (warp-media-glass:make-media-window *fb* *lib*)
  (declare (ignore on-key on-pointer))
  (funcall dirty-p)
  (setf (warp-media:player-queue *player*) (warp-media:folder-tracks (directory-namestring *file*)))
  (warp-media:play-path *player* *file*)
  (loop repeat 200 until (eq (warp-media:player-state *player*) :playing) do (sleep 0.02))
  (format t "~&playing ~a: ~ax~a video=~a duration=~,1fs~%" (file-namestring *file*)
          (if (warp-media:player-frame *player*) (warp-media:vf-w (warp-media:player-frame *player*)) "?")
          (if (warp-media:player-frame *player*) (warp-media:vf-h (warp-media:player-frame *player*)) "?")
          (warp-media:player-has-video-p *player*) (or (warp-media:player-duration *player*) 0))
  (let ((t0 (get-internal-real-time)) (paints 0) (ticks 0) (last-no 0) (shown 0))
    (loop while (< (/ (- (get-internal-real-time) t0) internal-time-units-per-second) *seconds*)
          do (when (funcall dirty-p) (incf paints))
             (incf ticks)
             (let ((no (warp-media:player-frame-no *player*)))
               (when (/= no last-no) (incf shown) (setf last-no no)))
             (sleep 1/60))
    (format t "~&~d s: ~d ticks, ~d paints, ~d distinct pictures shown, position ~,2f s, state ~a~%"
            *seconds* ticks paints shown (warp-media:player-position *player*) (warp-media:player-state *player*))
    (format t "~&pictures the file has for that span at nominal rate: ~d; decoder is ~a~%"
            (round (* *seconds* 30))
            (if (>= shown (* 0.9 *seconds* 30)) "KEEPING UP" "DROPPING")))
  (let* ((w (glass:fb-width *fb*)) (h (glass:fb-height *fb*)) (px (glass:fb-pixels *fb*))
         (cv (scribe:make-canvas w h)) (d (scribe:canvas-pixels cv)))
    (dotimes (y h)
      (dotimes (x w)
        (let ((v (aref px (+ (* y w) x))) (i (* 3 (+ (* y w) x))))
          (setf (aref d i) (ldb (byte 8 16) v) (aref d (+ i 1)) (ldb (byte 8 8) v) (aref d (+ i 2)) (ldb (byte 8 0) v)))))
    (scribe:write-png cv "/tmp/warp-media-run.png")
    (format t "~&wrote /tmp/warp-media-run.png~%")))

(warp-media:shutdown *player*)
(sb-ext:exit :code 0)
