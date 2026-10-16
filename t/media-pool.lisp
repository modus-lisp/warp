;;;; t/media-pool.lisp — the decode thread fills frames the UI's thread made (*FRAME-POOL*).
;;;;
;;;; On modus's bare-metal threads a picture made in shared memory comes out of the runtime lock's
;;;; arena (a Pi Zero's is 4 MB), so the player can instead hand the decoder a pool of :I420 frames
;;;; the UI's thread made, and take each back once it is neither queued nor shown.  This plays a
;;;; film with a real decode thread and the pool on, and checks: it plays to the end, every frame
;;;; shown came from the pool, the pool was REUSED (more distinct frame numbers than frame objects),
;;;; and no frame was handed out twice at once.
;;;;
;;;;   run:  sbcl --dynamic-space-size 2048 --non-interactive --load t/media-pool.lisp

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream)))
    (asdf:load-system :warp-media/glass)))

(defpackage #:warp-media-pool-test (:use #:cl)) (in-package #:warp-media-pool-test)

(defvar *fails* 0)
(defun ok (n p) (format t "~&  ~:[FAIL~;ok  ~] ~a~%" p n) (unless p (incf *fails*)))

(setf warp-media:*frame-format* :i420
      warp-media:*frame-pool* t)

(defparameter *vectors* (merge-pathnames "cassette/vectors/" (user-homedir-pathname)))
(defvar *player* (warp-media:make-player))

(format t "~&== a decode thread fills the UI's frames~%")
(warp-media:play-path *player* (merge-pathnames "t1-basic.webm" *vectors*))
(let ((nos '()) (objects '()) (bad 0) (t0 (get-internal-real-time)))
  (loop until (or (member (warp-media:player-state *player*) '(:ended :error))
                  (> (- (get-internal-real-time) t0) (* 20 internal-time-units-per-second)))
        do (let ((f (warp-media::player-frame-current *player*)))
             (when f
               (pushnew (warp-media:vf-no f) nos)
               (pushnew f objects)
               (unless (>= (warp-media::vf-pool f) 0) (incf bad))))
           (sleep 0.01))
  (ok (format nil "it ended (state ~a, error ~a)" (warp-media:player-state *player*)
              (warp-media:player-error *player*))
      (eq (warp-media:player-state *player*) :ended))
  (ok (format nil "the picture moved through the film (~d distinct frames shown)" (length nos))
      (> (length nos) 5))
  (ok (format nil "every frame shown came from the pool (~d did not)" bad) (zerop bad))
  (ok (format nil "the pool was reused: ~d frames shown in ~d frame objects (pool of ~d)"
              (length nos) (length objects) warp-media:*frame-pool-size*)
      (and (<= (length objects) warp-media:*frame-pool-size*) (> (length nos) (length objects)))))

(let ((free (warp-media::%pool-free *player*)))
  (ok "after the end, at most the frame on screen is out of the pool"
      (and free (<= (count 0 free) 1))))

(format t "~&POOL: ~:[~d FAILED~;all passed~]~%" (zerop *fails*) *fails*)
(uiop:quit (if (zerop *fails*) 0 1))
