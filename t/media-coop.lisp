;;;; t/media-coop.lisp — COOPERATIVE mode: the media player on a machine with no threads.
;;;;
;;;; The same WebM files and the same pretend mixer as t/media.lisp, with WARP-MEDIA:*COOPERATIVE*
;;;; set: no decode thread is ever made, the decoder runs inside PLAYER-FRAME-CURRENT (which the
;;;; projection's query calls on every tick), and the numbers must come out the same as the
;;;; threaded test's.  Then a file played with NO mixer, the way a board with no speaker plays it:
;;;; the wall clock paces the picture, every frame is shown, the track ends.
;;;;   run:  sbcl --dynamic-space-size 2048 --non-interactive --load t/media-coop.lisp

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream)))
    (asdf:load-system :warp-media/glass)))

(defpackage #:warp-media-coop-test (:use #:cl #:warp)) (in-package #:warp-media-coop-test)

(defvar *fails* 0)
(defun ok (n p) (format t "~&  ~:[FAIL~;ok  ~] ~a~%" p n) (unless p (incf *fails*)))

(setf warp-media:*cooperative* t)
;; the library lists audio only by default (*EXTENSIONS*); this test plays films, as a board with
;; its own screen (kiln zero) does
(setf warp-media:*extensions* (list* "webm" warp-media:*extensions*))
;; count every thread the player asks for (a live-thread count cannot see one that has finished)
(defvar *threads-made* 0)
(let ((make (fdefinition 'bt:make-thread)))
  (setf (fdefinition 'bt:make-thread)
        (lambda (&rest args) (incf *threads-made*) (apply make args))))

(defparameter *root* #p"/tmp/warp-media-coop-fixture/")
(defparameter *vectors* (merge-pathnames "cassette/vectors/" (user-homedir-pathname)))
(when (probe-file *root*)
  (uiop:delete-directory-tree *root* :validate (lambda (p) (uiop:subpathp p #p"/tmp/"))))
(ensure-directories-exist *root*)
(dolist (v '("t5-av.webm" "t1-basic.webm"))
  (uiop:copy-file (merge-pathnames v *vectors*) (merge-pathnames v *root*)))

(defvar *lib* (warp-media:make-library :root *root*))
(defvar *player* (warp-media:library-player *lib*))
(defvar *proj* (warp-media:library-projection *lib*))
(defclass rec-media (warp-media:media-consumer recording-consumer) ())
(defmethod warp-media:picture-height ((c rec-media)) 0)
(defmethod warp-media:picture-place ((c rec-media)) nil)
(defmethod warp-media:transport-place ((c rec-media)) nil)
(defmethod warp-media:control-place ((c rec-media) kind) (declare (ignore kind)) nil)
(defmethod warp-media:seek-place ((c rec-media) i) (declare (ignore i)) nil)
(defmethod warp-media:list-top ((c rec-media)) 0)
(defmethod warp-media:row-place ((c rec-media) i prev) (declare (ignore i prev)) nil)
(defvar *rc* (attach *proj* :class 'rec-media :view 'warp-media:media-view :budget 100000 :viewport-h 100000))
(tick *rc*)

(defun track (name)
  (find-if (lambda (o) (and (typep o 'warp-media:media-row)
                            (equal (pathname-name (warp-media:row-path o)) name)))
           (projection-objects *proj*)))

(format t "~&== with a mixer: the audio clock paces the picture, decoded by the UI's ticks~%")
(setf (warp-media:player-mixer *player*) :fake)
(defvar *source* (warp-media:player-source *player*))
(defun pull-audio (frames)
  (loop repeat frames sum (prog1 (if (funcall *source*) 1 0) (tick *rc*))))

(let ((r (invoke 'warp-media::play-track (track "t5-av") :owner)))
  (ok "play-track answered :playing at once (opened on this thread)" (eq (first r) :playing))
  (ok "it knows it has video" (warp-media:player-has-video-p *player*))
  (ok "duration is ~1 s" (let ((d (warp-media:player-duration *player*))) (and d (< 0.9 d 1.2))))
  (tick *rc*)
  (ok "one tick decoded ahead: frame 1 is up, queues have filled"
      (let ((f (warp-media:player-frame *player*)))
        (and f (= (warp-media:vf-no f) 1) (plusp (warp-media::%video-n *player*)))))
  (ok "the thunk handed out 25 audio frames" (= (pull-audio 25) 25))
  (tick *rc*)
  (let ((f (warp-media:player-frame *player*)))
    (ok "at t=0.5 s the picture is frame 8 (15 fps)" (and f (<= 7 (warp-media:vf-no f) 9)))
    (ok "position reads 0.5 s" (< 0.45 (warp-media:player-position *player*) 0.55)))
  (ok "pause is NIL from the thunk" (progn (warp-media:pause *player*) (zerop (pull-audio 5))))
  (warp-media:resume *player*)
  (let ((n (pull-audio 60)))
    (ok "the rest of the audio came out (~25 more frames)" (<= 20 n 30)))
  (tick *rc*)
  (ok "the track ended" (member (warp-media:player-state *player*) '(:ended :stopped))))

(format t "~&== no mixer: a board with no speaker plays the picture by the wall clock~%")
(setf (warp-media:player-mixer *player*) nil)
(warp-media:play-path *player* (merge-pathnames "t1-basic.webm" *root*))
(ok "playing at once" (eq (warp-media:player-state *player*) :playing))
(let ((seen '()) (t0 (get-internal-real-time)))
  (loop until (or (member (warp-media:player-state *player*) '(:ended :error))
                  (> (- (get-internal-real-time) t0) (* 10 internal-time-units-per-second)))
        do (tick *rc*)
           (let ((f (warp-media:player-frame *player*))) (when f (pushnew (warp-media:vf-no f) seen)))
           (sleep 0.01))
  (ok (format nil "it ended (state ~a, error ~a)" (warp-media:player-state *player*)
              (warp-media:player-error *player*))
      (eq (warp-media:player-state *player*) :ended))
  (ok (format nil "the picture moved through the film (~d distinct frames shown)" (length seen))
      (> (length seen) 5))
  (ok "it took about the film's length, not as fast as it decodes"
      (> (- (get-internal-real-time) t0) (* 0.5 internal-time-units-per-second))))

(ok (format nil "no thread was ever made (~d)" *threads-made*) (zerop *threads-made*))

(format t "~&COOP: ~:[~d FAILED~;all passed~]~%" (zerop *fails*) *fails*)
(uiop:quit (if (zerop *fails*) 0 1))
