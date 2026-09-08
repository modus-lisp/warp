;;;; t/media-seek.lisp — seeking: WebM to the exact frame (with and without Cues), MP3 by index
;;;; (CBR by arithmetic, VBR by Xing TOC) landing on the right sound, Opus from the decoded cache,
;;;; the paused seek that stays paused, and the seek bar's cells as commands.
;;;;   run:  sbcl --dynamic-space-size 2048 --non-interactive --load t/media-seek.lisp
;;;; Fixture files come from /tmp/warp-media-mp3 (made by ffmpeg: 440 Hz for 15 s then 880 Hz).

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream))) (asdf:load-system :warp-media/glass)))
(defpackage #:warp-media-seek-test (:use #:cl #:warp)) (in-package #:warp-media-seek-test)
(defvar *fails* 0)
(defun ok (n p) (format t "~&  ~:[FAIL~;ok  ~] ~a~%" p n) (unless p (incf *fails*)))

(defparameter *root* #p"/tmp/warp-media-seek-fixture/")
(defparameter *vectors* (merge-pathnames "cassette/vectors/" (user-homedir-pathname)))
(when (probe-file *root*) (uiop:delete-directory-tree *root* :validate (lambda (p) (uiop:subpathp p #p"/tmp/"))))
(ensure-directories-exist *root*)
(dolist (f '("t5-av.webm" "bbb360.webm")) (uiop:copy-file (merge-pathnames f *vectors*) (merge-pathnames f *root*)))
(dolist (f '("cbr.mp3" "vbr.mp3" "nocue.opus" "nocues.webm"))
  (uiop:copy-file (merge-pathnames f #p"/tmp/warp-media-mp3/") (merge-pathnames f *root*)))
(dolist (f '("av.mp4" "audio.m4a" "deep-av.mp4"))
  (uiop:copy-file (merge-pathnames f *vectors*) (merge-pathnames f *root*)))

(defvar *lib* (warp-media:make-library :root *root*))
(defvar *p* (warp-media:library-player *lib*))
(setf (warp-media:player-mixer *p*) :fake)
(defvar *src* (warp-media:player-source *p*))
(defun wait-playing () (loop repeat 400 until (member (warp-media:player-state *p*) '(:playing :error)) do (sleep 0.01))
  (warp-media:player-state *p*))
(defun pull-audio (n) (loop repeat n sum (if (funcall *src*) 1 0) do (sleep 0.002)))
(defun first-frames (n)
  "The next N audio frames concatenated (waits for the decoder)."
  (let ((acc '()))
    (loop repeat 400 while (< (length acc) n)
          do (let ((f (funcall *src*))) (if f (push f acc) (sleep 0.01))))
    (apply #'concatenate '(vector (signed-byte 16)) (nreverse acc))))
(defun zero-cross-hz (samples)
  (when (< (length samples) 2) (return-from zero-cross-hz 0d0))
  (let ((n 0))
    (loop for i from 1 below (length samples)
          when (and (< (aref samples (1- i)) 0) (>= (aref samples i) 0)) do (incf n))
    (/ (* n 48000d0) (length samples))))
(defun play (name &key from)
  (warp-media:play-path *p* (merge-pathnames name *root*) :from (or from 0d0))
  (let ((st (wait-playing)))
    (when (eq st :error) (format t "~&    !! ~a: ~a~%" name (warp-media:player-error *p*)))
    st))
(defun frame-ts () (let ((f (warp-media:player-frame *p*))) (and f (warp-media:vf-timestamp f))))
;; the presenter runs inside the query — the desktop ticks it at 60 Hz; here we ask directly
(defun wait-frame () (loop repeat 300 until (warp-media::player-frame-current *p*) do (sleep 0.01))
  (warp-media:player-frame *p*))

(format t "~&== WebM: seek lands on the frame, not the cluster~%")
(play "t5-av.webm")
(warp-media:seek *p* 0.6d0) (wait-playing)
(let ((f (wait-frame)))
  (ok (format nil "first picture after seek is at ~~0.6 s, not the cluster's key frame at 0 (got ~a, state ~a ~a)"
              (frame-ts) (warp-media:player-state *p*) (warp-media:player-error *p*))
      (and f (<= 0.55 (warp-media:vf-timestamp f) 0.67)))
  (ok "position reads 0.6" (<= 0.58 (warp-media:player-position *p*) 0.62)))
(pull-audio 5)
(ok "audio flows from the seek point" (plusp (pull-audio 5)))

(format t "~&== WebM without Cues: the cluster index is built by walking headers~%")
(play "nocues.webm")
(ok "a live-muxed file has no Duration either; the player copes" (null (warp-media:player-duration *p*)))
(ok "the file really has no Cues element"
    (null (cassette:webm-cues (cassette:parse-webm (cassette::slurp-file (merge-pathnames "nocues.webm" *root*))))))
(warp-media:seek *p* 4.0d0) (wait-playing)
(let ((f (wait-frame)))
  (ok (format nil "seek to 4.0 s shows the frame at 4.0 (got ~a)" (frame-ts)) (and f (<= 3.9 (warp-media:vf-timestamp f) 4.1))))

(format t "~&== paused seek stays paused and shows the new place~%")
(play "bbb360.webm")
(warp-media:pause *p*)
(warp-media:seek *p* 5.0d0)
(sleep 0.3)
(ok "still paused" (eq (warp-media:player-state *p*) :paused))
(let ((f (wait-frame)))
  (ok (format nil "the picture at 5.0 s is up while paused (got ~a)" (frame-ts)) (and f (<= 4.9 (warp-media:vf-timestamp f) 5.1))))
(ok "position 5.0 while paused" (<= 4.95 (warp-media:player-position *p*) 5.05))
(warp-media:seek *p* 100d0)
(sleep 0.3)
(ok "a seek past the end lands just short of it" (<= 9.5 (warp-media:player-position *p*) 10.0))

(format t "~&== MP3: duration and seek from the index~%")
(dolist (name '("cbr.mp3" "vbr.mp3"))
  (play name)
  (let ((d (warp-media:player-duration *p*)))
    (ok (format nil "~a: duration ~,2f s is ~~30 s" name (or d 0)) (and d (< 29.5 d 30.6))))
  (first-frames 10)                                          ; LAME's encoder delay: silence
  (ok (format nil "~a: at the start it is 440 Hz" name) (< 400 (zero-cross-hz (first-frames 10)) 480))
  (let ((t0 (get-internal-real-time)))
    (warp-media:seek *p* 20d0) (wait-playing)
    (let ((hz (zero-cross-hz (first-frames 10))))
      (ok (format nil "~a: seek to 20 s lands in the 880 Hz half (~,0f Hz), in ~d ms" name hz
                  (round (* 1000 (- (get-internal-real-time) t0)) internal-time-units-per-second))
          (< 820 hz 940))))
  (ok (format nil "~a: position reads 20 s" name) (<= 19.9 (warp-media:player-position *p*) 20.4))
  (warp-media:seek *p* 5d0) (wait-playing)
  (ok (format nil "~a: back to 5 s is 440 Hz again" name) (< 400 (zero-cross-hz (first-frames 10)) 480)))
(ok "the VBR file has a Xing TOC"
    (let ((idx (warp-media::%build-mp3-index (cassette::slurp-file (merge-pathnames "vbr.mp3" *root*)))))
      (and (warp-media:mi-toc idx) (warp-media:mi-frames idx))))

(format t "~&== Opus: decoded once, seeks are a lookup~%")
(play "nocue.opus")
(ok "duration ~30 s" (let ((d (warp-media:player-duration *p*))) (and d (< 29.8 d 30.2))))
(let ((t0 (get-internal-real-time)))
  (warp-media:seek *p* 20d0) (wait-playing)
  (let* ((hz (zero-cross-hz (first-frames 10)))
         (ms (round (* 1000 (- (get-internal-real-time) t0)) internal-time-units-per-second)))
    (ok (format nil "seek to 20 s is 880 Hz (~,0f) and took ~d ms (cache, not a decode)" hz ms)
        (and (< 820 hz 940) (< ms 400)))))

(format t "~&== MP4: cassette demuxes, reed decodes, and both tracks play~%")
;; av.mp4 is H.264 video + AAC audio, both 440 Hz.  reed's own MP4 reader cannot find the audio
;; config on this file because the video track comes first; cassette's demuxer can, which is the
;; whole reason this path exists.
;;
;; Its video is inter-coded H.264, so it is also the end-to-end check that P slices and motion
;; compensation reach the screen and not only the conformance test.
(play "av.mp4")
(ok "an inter-coded MP4 plays" (eq (warp-media:player-state *p*) :playing))
(ok (format nil "duration ~,2f s is ~~6 s" (or (warp-media:player-duration *p*) 0))
    (let ((d (warp-media:player-duration *p*))) (and d (< 5.9 d 6.2))))
(let ((f (wait-frame)))
  (ok (format nil "its video decodes rather than stopping at the first P slice (~a)"
              (if f (list (warp-media:vf-w f) (warp-media:vf-h f)) :no-picture))
      (and f (warp-media:player-has-video-p *p*) (null (warp-media:player-error *p*)))))
(first-frames 12)                    ; AAC priming: the first ~0.25 s is encoder delay and warm-up
(let ((hz (zero-cross-hz (first-frames 12))))
  (ok (format nil "the AAC track really decodes to the 440 Hz tone (~,0f Hz)" hz) (< 400 hz 480)))
(let ((t0 (get-internal-real-time)))
  (warp-media:seek *p* 3d0) (wait-playing)
  (let ((hz (zero-cross-hz (first-frames 12)))
        (ms (round (* 1000 (- (get-internal-real-time) t0)) internal-time-units-per-second)))
    (ok (format nil "seek to 3 s stays on tone (~,0f Hz) and is a cache lookup (~d ms)" hz ms)
        (and (< 400 hz 480) (< ms 500))))
  ;; the measurement above pulled 0.24 s of frames through the mixer, so the clock has moved
  (ok (format nil "position reads ~,2f s, i.e. 3 s plus what the measurement pulled"
              (warp-media:player-position *p*))
      (<= 2.9 (warp-media:player-position *p*) 3.4)))
(format t "~&== a picture that cannot be decoded at all still does not stop the sound~%")
;; deep-av.mp4 is High 10: ten bits per sample.  This decoder is eight-bit throughout, which is a
;; deep enough assumption that the file should stay undecodable, and that is what makes it a good
;; standing test for the player's answer to a picture it cannot start — drop it, say why, and run
;; the audio to the end.  Its two predecessors in this role both stopped being undecodable: av.mp4
;; when P slices landed, cabac-av.mp4 when CABAC did.
(play "deep-av.mp4")
(ok "a ten-bit MP4 still plays its sound" (eq (warp-media:player-state *p*) :playing))
(first-frames 8)
(ok (format nil "the transport says why the video stopped (~s)" (or (warp-media:player-error *p*) ""))
    ;; the REASON is deliberately not pinned down.  As the decoder grows, the first thing a given
    ;; file trips over changes — this one moved from CABAC to weighted prediction the day CABAC
    ;; started working — and what this test is about is the player's behaviour, not the decoder's
    ;; current frontier: a picture that cannot be decoded is dropped, and it says so.
    (let ((n (warp-media:player-error *p*)))
      (and n (search "video stopped" n) (> (length n) (length "video stopped: ")))))
(ok "and the state is still PLAYING, not ERROR" (eq (warp-media:player-state *p*) :playing))
(first-frames 12)
(ok (format nil "its audio keeps going at 440 Hz (~,0f)" (zero-cross-hz (first-frames 12)))
    (< 400 (zero-cross-hz (first-frames 12)) 480))

(play "audio.m4a")
(ok "an audio-only M4A plays too" (eq (warp-media:player-state *p*) :playing))
(first-frames 12)
(ok "and it is 440 Hz as well" (< 400 (zero-cross-hz (first-frames 12)) 480))
;; This assertion has now been emptied twice, which is the point of keeping it: it names what the
;; stack CANNOT do, so every time something starts working the list gets shorter.  It held
;; "V_MPEG4/ISO/AVC" until H.264 decoded, then "A_AAC" until AAC did, and av.mp4 now plays whole.
(ok "cassette names the codecs it cannot decode, and there are none left in this file"
    (null (cassette:player-unsupported (cassette:open-media (merge-pathnames "av.mp4" *root*)))))

(format t "~&== the seek bar: 32 cells, a tap on one is a command~%")
(warp-media:stop *p*)
(play "bbb360.webm")
(defvar *fb* (glass:make-framebuffer warp-media-glass:+width+ 640))
(multiple-value-bind (on-key on-pointer dirty-p) (warp-media-glass:make-media-window *fb* *lib*)
  (funcall dirty-p)
  (sleep 0.2)
  (funcall dirty-p)
  (funcall on-key t #xff53)                      ; Right: +10 s
  (sleep 0.4)
  (ok "Right arrow skips forward 10 s (to the end-clamp of a 10 s film)" (>= (warp-media:player-position *p*) 9.4))
  (funcall on-key t #xff51)                      ; Left: -10 s
  (sleep 0.4)
  (ok "Left arrow skips back" (< (warp-media:player-position *p*) 1.0))
  (funcall dirty-p)
  ;; the 16th cell lies at x = 16*16 .. 17*16, y = picture + transport
  (warp-media:pause *p*)                         ; so the position we read is the seek's, not the clock's
  (let ((y (+ warp-media-glass:+picture-h+ warp-media-glass:+row-h+ 4)) (x (+ (* 16 16) 4)))
    (funcall on-pointer 1 x y) (funcall on-pointer 0 x y)
    (sleep 0.5)
    (ok (format nil "tapping the 16th cell seeks to half way (~,2f s)" (warp-media:player-position *p*))
        (<= 4.95 (warp-media:player-position *p*) 5.05))
    (funcall dirty-p)
    (let* ((px (glass:fb-pixels *fb*)) (w (glass:fb-width *fb*))
           (yy (+ warp-media-glass:+picture-h+ warp-media-glass:+row-h+ 8))
           (filled (loop for cell below 32 count (= (aref px (+ (* yy w) (+ (* cell 16) 8))) warp-media-glass::+seek-filled+))))
      (ok (format nil "~d of 32 cells are painted filled" filled) (<= 15 filled 17)))))

(warp-media:shutdown *p*)
(format t "~&~a~%" (if (zerop *fails*) "SEEK OK" (format nil "SEEK: ~d FAILED" *fails*)))
(sb-ext:exit :code (if (zerop *fails*) 0 1))
