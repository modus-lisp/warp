;;;; t/media.lisp — the media player, headless: a folder of real WebM files, a player whose clock
;;;; is driven by hand, a recording consumer that sees the frame number climb, and a framebuffer
;;;; consumer whose picture band changes while nothing else does.
;;;;
;;;; No mixer thread, no RFB server, no desktop.  The "mixer" is this file calling the source
;;;; thunk 50 times per second of pretend time, which is exactly what glass's would do.
;;;;   run:  sbcl --dynamic-space-size 2048 --non-interactive --load t/media.lisp

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream)))
    (asdf:load-system :warp-media/glass)))

(defpackage #:warp-media-test (:use #:cl #:warp)) (in-package #:warp-media-test)

(defvar *fails* 0)
(defun ok (n p) (format t "~&  ~:[FAIL~;ok  ~] ~a~%" p n) (unless p (incf *fails*)))

(defparameter *root* #p"/tmp/warp-media-fixture/")
(defparameter *vectors* (merge-pathnames "cassette/vectors/" (user-homedir-pathname)))

(defun build-fixture ()
  (when (probe-file *root*)
    (uiop:delete-directory-tree *root* :validate (lambda (p) (uiop:subpathp p #p"/tmp/"))))
  (ensure-directories-exist (merge-pathnames "more/" *root*))
  (dolist (v '("t5-av.webm" "t1-basic.webm"))
    (uiop:copy-file (merge-pathnames v *vectors*) (merge-pathnames v *root*)))
  (uiop:copy-file (merge-pathnames "t4-testsrc.webm" *vectors*) (merge-pathnames "more/t4.webm" *root*))
  (with-open-file (s (merge-pathnames "notes.txt" *root*) :direction :output :if-exists :supersede)
    (write-string "not media" s)))

(build-fixture)

;;; a stand-in for the mixer: something MIXER-ADD-SOURCE-shaped is not needed, the player only
;;; needs to believe it has one so it keeps its audio and uses the audio clock
(defvar *lib* (warp-media:make-library :root *root*))
(defvar *player* (warp-media:library-player *lib*))
(setf (warp-media:player-mixer *player*) :fake)
(defvar *source* (warp-media:player-source *player*))
(defvar *rc* nil)
(defun pull-audio (frames)
  "FRAMES mixer ticks of pretend time.  The desktop would be ticking the consumer (and so the
   presenter) at 60 Hz alongside; here every pull ticks it, and gives the decoder a moment."
  (loop repeat frames
        sum (prog1 (if (funcall *source*) 1 0)
              (when *rc* (tick *rc*))
              (sleep 0.003))))
(defun diag (tag)
  (format t "~&    [~a] state=~a frame=~a pos=~,2f aq=~a vq=~a done=~a~%" tag
          (warp-media:player-state *player*) (warp-media:player-frame-no *player*)
          (warp-media:player-position *player*) (warp-media::%audio-n *player*)
          (warp-media::%video-n *player*) (warp-media::%worker-done *player*)))
;;; a recording consumer WITH the player's layout, so the picture band is measured the same way
;;; the framebuffer will measure it — but with no positional claim at all
(defclass rec-media (warp-media:media-consumer recording-consumer) ())
(defmethod warp-media:picture-height ((c rec-media)) 0)
(defmethod warp-media:picture-place ((c rec-media)) nil)
(defmethod warp-media:transport-place ((c rec-media)) nil)
(defmethod warp-media:control-place ((c rec-media) kind) (declare (ignore kind)) nil)
(defmethod warp-media:seek-place ((c rec-media) i) (declare (ignore i)) nil)
(defmethod warp-media:list-top ((c rec-media)) 0)
(defmethod warp-media:row-place ((c rec-media) i prev) (declare (ignore i prev)) nil)

(format t "~&== the query~%")
(defvar *proj* (warp-media:library-projection *lib*))
(setf *rc* (attach *proj* :class 'rec-media :view 'warp-media:media-view :budget 100000 :viewport-h 100000))
(tick *rc*)
(let ((rows (projection-objects *proj*)))
  (ok "result-set: picture, transport, 4 controls, 32 seek cells, head, 1 folder, 2 tracks"
      (and (= (length rows) (+ 10 warp-media:+seek-cells+))
           (typep (first rows) 'warp-media:picture-node)
           (= 1 (count-if (lambda (o) (and (typep o 'warp-media:media-row) (eq (warp-media:row-kind o) :dir))) rows))
           (= 2 (count-if (lambda (o) (and (typep o 'warp-media:media-row) (eq (warp-media:row-kind o) :track))) rows))))
  (ok "notes.txt is not a track" (notany (lambda (o) (and (typep o 'warp-media:media-row)
                                                           (equal (pathname-name (warp-media:row-path o)) "notes")))
                                         rows))
  (ok "a song-less library lays out no picture (recording consumer gave it no extent)"
      (notany (lambda (d) (eq (p-type (delta-presentation d)) 'warp-media:media-picture))
              (warp::take-record *rc*))))

(format t "~&== play a WebM with sound: the audio clock paces the picture~%")
(let* ((track (find-if (lambda (o) (and (typep o 'warp-media:media-row)
                                        (equal (pathname-name (warp-media:row-path o)) "t5-av")))
                       (projection-objects *proj*)))
       (r (invoke 'warp-media::play-track track :owner)))
  (ok "play-track answered" (eq (first r) :playing))
  ;; let the worker open the file and fill its queues
  (loop repeat 200 until (eq (warp-media:player-state *player*) :playing) do (sleep 0.02))
  (ok "state is :playing" (eq (warp-media:player-state *player*) :playing))
  (ok "it knows it has video" (warp-media:player-has-video-p *player*))
  (ok "duration is ~1 s" (let ((d (warp-media:player-duration *player*))) (and d (< 0.9 d 1.2))))
  (sleep 0.3)
  (tick *rc*)
  (diag "after open")
  (ok "frame 1 is showing before any audio has been taken (timestamp 0)"
      (let ((f (warp-media:player-frame *player*))) (and f (= (warp-media:vf-no f) 1))))
  ;; half a second of pretend audio: 25 mixer ticks
  (let ((got (pull-audio 25)))
    (ok "the thunk handed out 25 audio frames" (= got 25)))
  (sleep 0.1)
  (tick *rc*)
  (diag "after 25 pulls")
  (let ((f (warp-media:player-frame *player*)))
    (ok "at t=0.5 s the picture is frame 8 (15 fps)" (and f (<= 7 (warp-media:vf-no f) 9)))
    (ok "position reads 0.5 s" (< 0.45 (warp-media:player-position *player*) 0.55)))
  (ok "the picture node's fingerprint carries the frame number and no pixels"
      (let* ((rec (warp::take-record *rc*))
             (pd (find 'warp-media:media-picture rec :key (lambda (d) (p-type (delta-presentation d))))))
        (declare (ignorable pd))
        ;; the recording consumer has no picture-place: the opaque node is invisible to it by
        ;; design, so what we check is PRESENT directly
        (let ((cells (present (first (projection-objects *proj*)) 'warp-media:media-picture 'warp-media:media-view)))
          (and (integerp (third cells)) (eq (fourth cells) :opaque)
               (notany (lambda (c) (typep c '(simple-array (unsigned-byte 8) (*)))) cells)))))
  (ok "pause is NIL from the thunk" (progn (warp-media:pause *player*) (zerop (pull-audio 5))))
  (ok "position does not move while paused" (< 0.45 (warp-media:player-position *player*) 0.55))
  (warp-media:resume *player*)
  ;; drain the rest of the second
  (let ((n 0)) (loop repeat 60 do (incf n (pull-audio 1)) (sleep 0.005))
    (ok "the rest of the audio came out (~25 more frames)" (<= 20 n 30)))
  (loop repeat 100 until (member (warp-media:player-state *player*) '(:ended :stopped))
        do (pull-audio 1) (sleep 0.02))
  (diag "after drain")
  ;; t5-av is the LAST track of the folder, so auto-advance has nowhere to go
  (ok "the track ended and the player stopped at the end of the folder"
      (member (warp-media:player-state *player*) '(:ended :stopped))))

(defun save-png (fb path)
  (let* ((w (glass:fb-width fb)) (h (glass:fb-height fb)) (px (glass:fb-pixels fb))
         (cv (scribe:make-canvas w h)) (d (scribe:canvas-pixels cv)))
    (dotimes (y h)
      (dotimes (x w)
        (let ((v (aref px (+ (* y w) x))) (i (* 3 (+ (* y w) x))))
          (setf (aref d i) (ldb (byte 8 16) v) (aref d (+ i 1)) (ldb (byte 8 8) v) (aref d (+ i 2)) (ldb (byte 8 0) v)))))
    (scribe:write-png cv path)))

(format t "~&== a framebuffer consumer: only the picture band moves~%")
(warp-media:stop *player*)
(defvar *fb* (glass:make-framebuffer warp-media-glass:+width+ 640))
(multiple-value-bind (on-key on-pointer dirty-p copy-p close-fn c)
    (warp-media-glass:make-media-window *fb* *lib*)
  (declare (ignore on-key copy-p close-fn))
  (defvar *c* c)
  (funcall dirty-p)
  (ok "first pass painted the transport, controls and rows" (> (consumer-landed *c*) 5))
  (ok "idle: a second pass paints nothing" (let ((before (consumer-landed *c*))) (funcall dirty-p)
                                             (= before (consumer-landed *c*))))
  ;; tap the first track row: play-track is the default
  (let* ((row (find-if (lambda (p) (eq (p-type p) 'warp-media:media-track)) (consumer-visible *c*)))
         (e (p-extent row)))
    (funcall on-pointer 1 (+ (extent-x e) 5) (+ (extent-y e) 5))
    (funcall on-pointer 0 (+ (extent-x e) 5) (+ (extent-y e) 5))
    (loop repeat 200 until (eq (warp-media:player-state *player*) :playing) do (sleep 0.02))
    (ok "a tap on a track plays it" (eq (warp-media:player-state *player*) :playing))
    (sleep 0.3)
    (funcall dirty-p)
    (let ((pic (find 'warp-media:media-picture (consumer-visible *c*) :key #'p-type)))
      (ok "the picture band is laid out now that the track has video" (and pic (p-extent pic)))
      (when pic
        (let* ((e (p-extent pic)) (px (glass:fb-pixels *fb*)) (w (glass:fb-width *fb*)))
          (ok "picture band is 512 x 288 at the top" (equal e (list 0 0 512 288)))
          (ok "there are non-black pixels in the picture band"
              (loop for y from (+ (extent-y e) 40) below (- (+ (extent-y e) (extent-h e)) 40) by 16
                    thereis (loop for x from 8 below w by 16
                                  thereis (/= 0 (aref px (+ (* y w) x))))))))
      ;; advance the clock; only the picture (and once a second the clock) should repaint
      (pull-audio 10) (sleep 0.1)
      (let ((before (consumer-landed *c*)))
        (funcall dirty-p)
        (let ((n (- (consumer-landed *c*) before)))
          ;; the picture, the clock text once a second, and the seek cells the position crossed
          (ok (format nil "advancing the clock repaints the picture, the cells it crossed, little else (~d deltas)" n) (<= 1 n 12))))))
  (save-png *fb* "/tmp/warp-media-shot.png")
  (format t "~&  wrote /tmp/warp-media-shot.png~%"))

(warp-media:shutdown *player*)
(format t "~&~a~%" (if (zerop *fails*) "MEDIA OK" (format nil "MEDIA: ~d FAILED" *fails*)))
(sb-ext:exit :code (if (zerop *fails*) 0 1))
