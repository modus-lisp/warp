;;;; media/engine.lisp — the player: threads, decoders, one source thunk, one clock.
;;;;
;;;; THE OUTPUT OF THIS FILE IS TWO THINGS.  A SOURCE THUNK — no arguments, the next 960 mono
;;;; samples at 48 kHz, or NIL — which is reed's contract, glass's mixer's contract and
;;;; webrtc-media's, so the sound reaches whoever the session is playing to without an adapter.
;;;; And a FRAME — the most recent decoded picture, as RGB octets, with the number that says it is
;;;; new — which the projection wraps as an opaque node and the framebuffer encoding blits.
;;;;
;;;; AUDIO IS THE CLOCK.  The mixer pulls a frame every 20 ms whether we are ready or not, so the
;;;; number of samples it has taken IS the time the listener has heard, and the picture shown is
;;;; the latest one whose timestamp is not past that.  A file with no sound is paced by the wall
;;;; clock instead, and a player with no mixer to feed drops its audio and does the same — the
;;;; picture must still move on a box that is not listening.
;;;;
;;;; ONE WORKER THREAD demuxes and decodes, in file order, into two bounded queues: audio frames
;;;; for the thunk and RGB frames for the presenter.  It blocks when the queue it wants to fill is
;;;; full, which is what keeps it a fixed distance ahead of the clock instead of decoding the whole
;;;; film into memory.  Everything the UI reads — state, position, the current frame — is a slot
;;;; read under one lock; nothing in the UI's path waits on a decoder.
;;;;
;;;; PAUSE IS NIL, as in spool: the thunk returns NIL and the mixer plays silence, its clock never
;;;; stops, and no consumer has to be told anything.

(in-package #:warp-media)

(defconstant +rate+ 48000)
(defconstant +frame-samples+ 960 "20 ms at 48 kHz — one mixer tick.")
(defparameter *audio-queue-max* 64 "Audio frames decoded ahead: 1.28 s.")
(defparameter *video-queue-max* 6 "Video frames decoded ahead.")

;;; ---- a decoded picture ---------------------------------------------------------------------------

(defstruct (video-frame (:conc-name vf-))
  (w 0 :type fixnum) (h 0 :type fixnum)
  (rgb nil)                                     ; packed 8-bit RGB, w*h*3 octets
  (no 0 :type fixnum)                           ; monotonically increasing; the fingerprint's part
  (timestamp 0d0 :type double-float))           ; seconds

;;; ---- the player ------------------------------------------------------------------------------------

(defclass player ()
  ((state :initform :stopped :accessor player-state
          :documentation ":stopped :loading :playing :paused :ended :error")
   (error :initform nil :accessor player-error)
   (track :initform nil :accessor player-track :documentation "The pathname playing, or NIL.")
   (title :initform nil :accessor player-title)
   (duration :initform nil :accessor player-duration :documentation "Seconds, or NIL when unknown.")
   (has-video :initform nil :accessor player-has-video-p)
   (has-audio :initform nil :accessor %has-audio)
   ;; the clock
   (emitted :initform 0 :accessor %emitted :documentation "Samples the mixer has taken since BASE.")
   (base :initform 0d0 :accessor %base :documentation "Seconds the last start or seek landed at.")
   (wall-start :initform nil :accessor %wall-start
               :documentation "Internal-time when wall-clock pacing (re)started, or NIL while paused.")
   (wall-accum :initform 0d0 :accessor %wall-accum
               :documentation "Seconds of wall-clock playing accumulated before the current run.")
   ;; what the presenter shows
   (frame :initform nil :accessor player-frame)
   (frame-no :initform 0 :accessor player-frame-no)
   ;; the queues
   (audio-q :initform '() :accessor %audio-q) (audio-n :initform 0 :accessor %audio-n)
   (video-q :initform '() :accessor %video-q) (video-n :initform 0 :accessor %video-n)
   (worker :initform nil :accessor %worker)
   (worker-done :initform t :accessor %worker-done)
   (generation :initform 0 :accessor %generation
               :documentation "Bumped on every open/seek/stop; a worker that sees a newer one quits.")
   ;; the playlist the engine advances through
   (queue :initform '() :accessor player-queue :documentation "Pathnames, in play order.")
   (index :initform -1 :accessor player-index)
   (on-change :initform nil :accessor player-on-change
              :documentation "Called with the player whenever a track starts or ends, for the UI.")
   ;; what the current track decoded to, kept so a seek is a lookup, not a second decode
   (pcm-cache :initform nil :accessor %pcm-cache :documentation "(path . mono s16 48k vector), or NIL.")
   (mp3-index :initform nil :accessor %mp3-index :documentation "(path . MP3-INDEX), or NIL.")
   ;; the mixer this player is a source on, if any
   (mixer :initform nil :accessor player-mixer)
   (source-handle :initform nil :accessor %source-handle)
   (lock :initform (bt:make-lock "warp-media-player") :reader %lock))
  (:documentation "Shared playback state — the query's argument.  One per window group, not per seat."))

(defun make-player (&key mixer)
  (let ((p (make-instance 'player)))
    (when mixer (attach-mixer p mixer))
    p))

(defmacro with-player ((p) &body body) `(bt:with-lock-held ((%lock ,p)) ,@body))

;;; ---- the clock ---------------------------------------------------------------------------------

(defun %now () (/ (get-internal-real-time) (float internal-time-units-per-second 1d0)))

(defun player-clock-seconds (p)
  "Where playback is, in seconds: audio samples handed out when there is sound to hand out, the
   wall clock otherwise.  Caller holds the lock or accepts a torn read."
  (+ (%base p)
     (if (and (%has-audio p) (player-mixer p))
         (/ (%emitted p) (float +rate+ 1d0))
         (+ (%wall-accum p)
            (if (%wall-start p) (- (%now) (%wall-start p)) 0d0)))))

(defun player-position (p)
  "Seconds of the track the listener has reached, clamped to the duration when one is known.

   For a SILENT film this is the picture on screen, not the wall clock.  The wall clock is the
   right thing to pace *against* — a frame goes up when its timestamp arrives — but the wrong thing
   to report when the decoder cannot keep up, which H.264 at 640x360 currently cannot.  Reporting it
   runs the clock and the seek bar off the end while the picture is still in the middle: a number
   that describes the machine rather than the film.  MAX against the base keeps a frame left over
   from before a seek from reading as the position after it."
  (let ((s (with-player (p)
             (let ((f (and (not (%has-audio p)) (player-frame p))))
               (if f (max (%base p) (vf-timestamp f)) (player-clock-seconds p))))))
    (if (player-duration p) (min s (player-duration p)) s)))

(defun %wall-run (p) (unless (%wall-start p) (setf (%wall-start p) (%now))))
(defun %wall-hold (p)
  (when (%wall-start p)
    (incf (%wall-accum p) (- (%now) (%wall-start p)))
    (setf (%wall-start p) nil)))

;;; ---- the source thunk: the mixer's end -----------------------------------------------------------

(defun player-source (p)
  "P as a source thunk.  Hand it to a mixer once; it stays valid across tracks, pauses and seeks."
  (lambda ()
    (handler-case
        (with-player (p)
          (when (eq (player-state p) :playing)
            (let ((f (pop (%audio-q p))))
              (cond
                (f (decf (%audio-n p)) (incf (%emitted p) (length f)) f)
                ;; nothing queued: either the decoder is behind (silence, ask again) or it is
                ;; finished, in which case the track has ended once the picture has caught up —
                ;; promote what the clock allows first, since nobody else may be looking
                ((and (%worker-done p) (%has-audio p))
                 (%present-locked p)
                 (when (null (%video-q p)) (%finish-locked p))
                 nil)
                (t nil)))))
      (serious-condition (e)
        ;; this runs on the mixer's 20 ms thread: a decode problem is one silent frame and a
        ;; state, never an escaping condition
        (setf (player-state p) :error (player-error p) (princ-to-string e))
        nil))))

(defun attach-mixer (p mixer &key (name "media") (gain 1.0d0))
  "Register P's source on MIXER (a glass mixer, reached by whoever owns one).  MIXER-ADD-SOURCE is
   found by name so this file loads without glass."
  (let ((add (and (find-package "GLASS") (find-symbol "MIXER-ADD-SOURCE" "GLASS"))))
    (when (and add (fboundp add))
      (setf (player-mixer p) mixer
            (%source-handle p) (funcall add mixer (player-source p) :name name :gain gain))))
  p)

(defun detach-mixer (p)
  (let ((rm (and (find-package "GLASS") (find-symbol "MIXER-REMOVE-SOURCE" "GLASS"))))
    (when (and rm (fboundp rm) (player-mixer p) (%source-handle p))
      (ignore-errors (funcall rm (player-mixer p) (%source-handle p)))))
  (setf (player-mixer p) nil (%source-handle p) nil)
  p)

;;; ---- the presenter: which frame is current ---------------------------------------------------------

(defun %present-locked (p)
  "Promote every queued frame whose time has come; the last of them is what is shown."
  (let ((clock (player-clock-seconds p)) (shown nil))
    ;; the first picture of a track goes up at once, whatever its timestamp: a player that shows
    ;; black until the clock catches a 7 ms offset looks broken for exactly that long
    (when (and (null (player-frame p)) (%video-q p))
      (setf shown (pop (%video-q p))) (decf (%video-n p)))
    (loop while (and (%video-q p) (<= (vf-timestamp (first (%video-q p))) clock))
          do (setf shown (pop (%video-q p))) (decf (%video-n p)))
    (when shown
      (setf (player-frame p) shown (player-frame-no p) (vf-no shown)))
    ;; a silent film ends when its last frame has been shown
    (when (and (%worker-done p) (null (%video-q p)) (not (%has-audio p))
               (eq (player-state p) :playing)
               (or (null (player-duration p)) (>= clock (player-duration p))))
      (%finish-locked p))
    shown))

(defun player-frame-current (p)
  "The frame to show now — promotes queued frames first.  Called from the query, at UI rate."
  (with-player (p) (%present-locked p) (player-frame p)))

;;; ---- state changes -----------------------------------------------------------------------------------

(defun %finish-locked (p)
  (setf (player-state p) :ended)
  (%wall-hold p)
  (let ((cb (player-on-change p)))
    (when cb (bt:make-thread (lambda () (ignore-errors (funcall cb p :ended))) :name "warp-media-ended"))))

(defun %reset-locked (p)
  (incf (%generation p))
  (setf (%audio-q p) '() (%audio-n p) 0 (%video-q p) '() (%video-n p) 0
        (%emitted p) 0 (%base p) 0d0 (%wall-start p) nil (%wall-accum p) 0d0
        (player-error p) nil))

(defun stop (p)
  "Stop, forget the track, keep the playlist."
  (with-player (p)
    (%reset-locked p)
    (setf (player-state p) :stopped (player-track p) nil (player-title p) nil
          (player-duration p) nil (player-has-video-p p) nil (%has-audio p) nil
          (player-frame p) nil))
  (player-state p))

(defun pause (p)
  (with-player (p)
    (when (eq (player-state p) :playing)
      (setf (player-state p) :paused)
      (%wall-hold p)))
  (player-state p))

(defun resume (p)
  (with-player (p)
    (when (eq (player-state p) :paused)
      (setf (player-state p) :playing)
      (%wall-run p)))
  (player-state p))

(defun toggle (p)
  (case (player-state p)
    (:playing (pause p))
    (:paused (resume p))
    ((:stopped :ended :error) (if (player-queue p) (play-index p (max 0 (player-index p))) (player-state p)))
    (t (player-state p))))

(defun shutdown (p)
  "Stop the worker and leave the mixer."
  (stop p)
  (detach-mixer p)
  p)

;;; ---- opening a track -------------------------------------------------------------------------------

(defun %media-kind (path)
  (let ((type (string-downcase (or (pathname-type path) ""))))
    (cond ((string= type "webm") :webm)
          ((string= type "mp3") :mp3)
          ((member type '("opus" "ogg" "oga") :test #'string=) :opus)
          ;; MP4 and M4A go through CASSETTE's demuxer and then reed's AAC decoder, rather than
          ;; reed's own whole-file MP4 reader.  The reason is a real failure: reed's reader looks
          ;; for an esds under the first track it finds, so on a file with VIDEO first it finds an
          ;; avcC and reports "no esds AudioSpecificConfig" — an A/V mp4 would not play at all,
          ;; not even its sound.  cassette knows which track is the audio one.
          ((member type '("m4a" "mp4") :test #'string=) :mp4)
          ((member type '("aac" "adts") :test #'string=) :aac)
          (t nil))))

(defun play-path (p path &key (from 0d0))
  "Open PATH and start playing it FROM seconds.  Returns the new state.  The previous track's
   worker is told to quit by generation; it drops out on its next queue push."
  (let ((kind (%media-kind path)))
    (unless kind
      (with-player (p) (setf (player-state p) :error (player-error p) "not a media file"))
      (return-from play-path :error))
    (with-player (p)
      (%reset-locked p)
      (setf (player-state p) :loading
            (player-track p) (pathname path)
            (player-title p) (pathname-name path)
            (player-duration p) nil
            (player-has-video-p p) nil (%has-audio p) nil
            (player-frame p) nil
            (%base p) (float from 1d0)
            (%worker-done p) nil)
      (let ((gen (%generation p)))
        (setf (%worker p)
              (bt:make-thread (lambda () (%run-worker p gen kind path from))
                              :name "warp-media-decode"))))
    (player-state p)))

(defun play-index (p i)
  "Play the I-th entry of the queue."
  (let ((q (player-queue p)))
    (when (and q (<= 0 i (1- (length q))))
      (setf (player-index p) i)
      (play-path p (nth i q)))))

(defun play-next (p)
  (let ((q (player-queue p)) (i (1+ (player-index p))))
    (if (< i (length q))
        (play-index p i)
        (progn (stop p) (setf (player-state p) :ended) :ended))))

(defun play-prev (p)
  (play-index p (max 0 (1- (player-index p)))))

(defun seek (p seconds)
  "Jump to SECONDS in the current track — a fresh worker from there.  A paused player stays
   paused and shows the picture at the new place; a seek past the end lands just short of it."
  (let ((track (player-track p)) (dur (player-duration p)))
    (when (and track (member (player-state p) '(:playing :paused :ended)))
      (let* ((paused (eq (player-state p) :paused))
             (target (max 0d0 (float seconds 1d0)))
             (target (if dur (min target (max 0d0 (- dur 0.25d0))) target)))
        (play-path p track :from target)
        (when paused
          ;; the worker flips :loading -> :playing when it goes live; hold it at paused instead
          (loop repeat 200 until (eq (player-state p) :playing) do (sleep 0.005))
          (pause p))))
    (player-position p)))

(defun seek-fraction (p fraction)
  "Jump to FRACTION (0..1) of a track whose duration is known."
  (let ((dur (player-duration p)))
    (when dur (seek p (* dur (max 0d0 (min 1d0 fraction)))))))

(defun skip (p delta) (seek p (+ (player-position p) delta)))

;;; ---- the worker: demux, decode, queue ---------------------------------------------------------------

(defun %live-p (p gen) (and (= gen (%generation p))))

(defun %push-audio (p gen frames)
  "Queue mono frames, blocking while the queue is full.  Returns NIL when superseded."
  (dolist (f frames t)
    (loop
      (unless (%live-p p gen) (return-from %push-audio nil))
      (when (with-player (p)
              (when (< (%audio-n p) *audio-queue-max*)
                (setf (%audio-q p) (nconc (%audio-q p) (list f)))
                (incf (%audio-n p))
                t))
        (return))
      (sleep 0.01))))

(defun %push-video (p gen frame)
  (loop
    (unless (%live-p p gen) (return-from %push-video nil))
    (when (with-player (p)
            (when (< (%video-n p) *video-queue-max*)
              (setf (%video-q p) (nconc (%video-q p) (list frame)))
              (incf (%video-n p))
              t))
      (return t))
    (sleep 0.005)))

(defun %go-live (p gen &key has-video has-audio duration title)
  "The worker knows what the file is: publish that, and start the clock."
  (with-player (p)
    (when (%live-p p gen)
      (setf (player-has-video-p p) has-video
            (%has-audio p) (and has-audio (player-mixer p) t)
            (player-duration p) duration)
      (when title (setf (player-title p) title))
      (when (eq (player-state p) :loading)
        (setf (player-state p) :playing)
        (%wall-run p))
      (let ((cb (player-on-change p)))
        (when cb (ignore-errors (funcall cb p :started)))))))

(defun %fail (p gen e)
  (with-player (p)
    (when (%live-p p gen)
      (setf (player-state p) :error (player-error p) (princ-to-string e)))))

(defun %run-worker (p gen kind path from)
  (handler-case
      (ecase kind
        ((:webm :mp4) (%run-container p gen path from))
        ((:mp3 :opus :aac) (%run-audio-file p gen kind path from)))
    (serious-condition (e) (%fail p gen e)))
  (with-player (p) (when (%live-p p gen) (setf (%worker-done p) t))))

;;; ---- WebM: video and Opus, interleaved --------------------------------------------------------------

(defun %pcm->mono-frames (pcm carry)
  "reed's float32 PCM struct (48 kHz, interleaved) -> a list of 960-sample s16 mono frames.
   CARRY is the partial frame left over from last time; returns (values frames new-carry)."
  (let* ((samples (reed:pcm-samples pcm))
         (ch (reed:pcm-channels pcm))
         (n (floor (length samples) ch))
         (mono (make-array (+ (length carry) n) :element-type '(signed-byte 16)))
         (frames '()))
    (replace mono carry)
    (dotimes (i n)
      (let ((acc 0d0))
        (dotimes (c ch) (incf acc (aref samples (+ (* i ch) c))))
        (setf (aref mono (+ (length carry) i))
              (let ((v (round (* (/ acc ch) 32767))))
                (max -32768 (min 32767 v))))))
    (let ((pos 0) (total (length mono)))
      (loop while (<= (+ pos +frame-samples+) total)
            do (push (subseq mono pos (+ pos +frame-samples+)) frames)
               (incf pos +frame-samples+))
      (values (nreverse frames) (subseq mono pos)))))

(defun %picture->frame (pic no)
  (let* ((w (cassette:picture-width pic)) (h (cassette:picture-height pic))
         (rgb (make-array (* w h 3) :element-type '(unsigned-byte 8))))
    (cassette:picture->rgb-into pic rgb)
    (make-video-frame :w w :h h :rgb rgb :no no
                      :timestamp (float (or (cassette:picture-timestamp pic) 0d0) 1d0))))

(defun %video-gave-up (p gen e any-frames-p)
  "The video track stopped decoding part way through.  Keep playing the sound.

   This is the difference between a media player and a decoder test.  A file can carry a picture
   this decoder does not do yet — H.264 P slices are the live example — and the sound in it is
   still perfectly good sound.  Going silent over a picture nobody asked about is the worse
   failure, so the picture is dropped, the reason is put where the transport shows it, and the
   audio runs to the end.  ANY-FRAMES-P keeps the last decoded picture on screen when some frames
   did land; when none did, the layout gives the space back."
  (with-player (p)
    (when (%live-p p gen)
      (unless any-frames-p (setf (player-has-video-p p) nil))
      (setf (player-error p) (format nil "video stopped: ~a" e)))))

(defun %run-container (p gen path from)
  "Play a WebM or an MP4: video through cassette (VP8 or H.264), audio through whichever decoder
   the track needs.

   Written against cassette's PUBLIC api rather than its internals, which is what lets one
   function cover both containers and both video codecs: NEXT-VIDEO-FRAME already knows whether
   it is feeding a VP8 or an H.264 decoder, and the caller does not have to.

   The one thing cassette cannot do per packet is AAC, so an MP4's audio is decoded whole, once,
   and paced against the picture here.  That is why the interleave is explicit: the worker has to
   keep sound ahead of vision, or the bounded video queue stalls the audio it is meant to stay in
   step with."
  (let* ((wp (cassette:open-media path :audio (and (player-mixer p) t)))
         (vt (cassette:player-video-track wp))
         (at (cassette:player-audio-track wp))
         (duration (cassette:player-duration wp))
         (landed (if (plusp from) (or (cassette:seek-media wp from) 0d0) 0d0))
         (start (max (float from 1d0) landed))
         ;; an MP4's AAC track: cassette demuxes it, reed decodes it, cached per track
         (aac (when (and (null at) (player-mixer p)
                         (member (string-downcase (or (pathname-type path) ""))
                                 '("mp4" "m4a") :test #'string=))
                (or (%pcm-for p path)
                    (let ((m (ignore-errors (%mp4-aac-mono path))))
                      (when m (with-player (p) (setf (%pcm-cache p) (cons path m))) m)))))
         (aac-pos (if aac (min (length aac) (floor (* start +rate+))) 0))
         (carry (make-array 0 :element-type '(signed-byte 16)))
         (no 0))
    (declare (type fixnum aac-pos no))
    (with-player (p) (when (%live-p p gen) (setf (%base p) start)))
    (%go-live p gen :has-video (and vt t) :has-audio (or (and at t) (and aac t))
              :duration (or duration (and aac (/ (length aac) (float +rate+ 1d0)))))
    (labels ((pump-audio-to (target)
               (cond
                 (aac
                  (loop while (and (< (/ aac-pos (float +rate+ 1d0)) target)
                                   (< aac-pos (length aac)))
                        do (let ((end (min (length aac) (+ aac-pos +frame-samples+))))
                             (unless (%push-audio p gen (list (subseq aac aac-pos end)))
                               (return-from pump-audio-to nil))
                             (setf aac-pos end)))
                  t)
                 (at
                  (loop
                    (multiple-value-bind (pcm ts) (cassette:next-audio-frame wp)
                      (unless pcm (return t))
                      (when (>= ts (- start 0.0105d0))
                        (multiple-value-bind (frames c) (%pcm->mono-frames pcm carry)
                          (setf carry c)
                          (unless (%push-audio p gen frames) (return nil))))
                      (when (> ts target) (return t)))))
                 (t t))))
      (loop
        (unless (%live-p p gen) (return))
        (let ((pic (and vt (handler-case (cassette:next-video-frame wp)
                             (serious-condition (e) (%video-gave-up p gen e (plusp no))
                               (setf vt nil) nil)))))
          (cond
            (pic
             (let ((ts (or (cassette:picture-timestamp pic) 0d0)))
               (unless (pump-audio-to (+ ts 1d0)) (return))
               (when (>= ts (- start 0.017d0))
                 (unless (%push-video p gen (%picture->frame pic (incf no))) (return)))))
            (t
             (pump-audio-to most-positive-double-float)
             (return))))))))

;;; ---- MP3: an index, so a seek is arithmetic -------------------------------------------------------------
;;;
;;; MP3 has no index of its own.  What it has is one of three things, in order of how good they are:
;;; a Xing/Info frame with a frame count and a 100-point TOC (every LAME/ffmpeg VBR file), a Xing
;;; frame with a count but no TOC, or nothing — in which case the file is CBR and bytes ARE time.
;;; Read once per track from the first frame; duration and seek both come out of it.

(defstruct (mp3-index (:conc-name mi-))
  (first 0) (end 0)                             ; audio bytes: after the tag/Xing frame, before ID3v1
  (rate 44100) (samples 1152) (bitrate 0)       ; of the first frame
  (frames nil)                                  ; Xing frame count, or NIL
  (toc nil)                                     ; 100 bytes: percent of audio -> byte position / 256
  (duration nil))                               ; seconds

(defun %build-mp3-index (bytes)
  (let* ((pos (reed::skip-id3v2 bytes)) (end (reed::end-offset bytes)))
    (multiple-value-bind (off h) (reed::find-frame-sync bytes pos end)
      (unless h (error "no MPEG frame found"))
      (let ((idx (make-mp3-index :first off :end end :rate (reed::fh-sample-rate h)
                                 :samples (reed::fh-samples h) :bitrate (reed::fh-bitrate h))))
        (when (reed::xing/info/vbri-frame-p bytes off h)
          (let* ((mpeg1p (eq (reed::fh-version h) :mpeg1)) (mono (= (reed::fh-channels h) 1))
                 (x (+ off 4 (cond ((and mpeg1p (not mono)) 32) (mpeg1p 17) (mono 9) (t 17)))))
            (when (and (< (+ x 8) end)
                       (or (= (aref bytes x) (char-code #\X)) (= (aref bytes x) (char-code #\I))))
              (let* ((flags (reed::u32be bytes (+ x 4))) (q (+ x 8)))
                (when (logtest flags 1) (setf (mi-frames idx) (reed::u32be bytes q)) (incf q 4))
                (when (logtest flags 2) (incf q 4))                    ; byte count: we have the file
                (when (and (logtest flags 4) (<= (+ q 100) end))
                  (setf (mi-toc idx) (subseq bytes q (+ q 100))))))
            ;; the tag frame carries no audio: audio starts after it
            (setf (mi-first idx) (+ off (reed::fh-frame-length h)))))
        (setf (mi-duration idx)
              (if (mi-frames idx)
                  (/ (* (mi-frames idx) (mi-samples idx)) (float (mi-rate idx) 1d0))
                  (/ (* 8d0 (- end (mi-first idx))) (mi-bitrate idx))))
        idx))))

(defun %mp3-offset (idx seconds)
  "The byte offset SECONDS into the audio: by TOC when there is one, else proportionally."
  (let* ((dur (max 0.001d0 (mi-duration idx)))
         (frac (max 0d0 (min 0.999d0 (/ seconds dur))))
         (span (- (mi-end idx) (mi-first idx)))
         (toc (mi-toc idx)))
    (+ (mi-first idx)
       (if toc
           (let* ((pct (* frac 100d0)) (i (floor pct)) (a (aref toc i))
                  (b (if (< i 99) (aref toc (1+ i)) 256))
                  (v (+ a (* (- pct i) (- b a)))))
             (floor (* v span) 256))
           (floor (* frac span))))))

(defun %mp4-aac-mono (path)
  "The AAC track of an MP4 or M4A, demuxed by cassette and decoded by reed, as mono s16 at 48 kHz.

   The layering is the point.  cassette finds the AUDIO track and hands over its
   AudioSpecificConfig and its access units; reed decodes access units given a config.  Neither
   has to re-read the other's half, and a file whose video track comes first — which is most of
   them — does not defeat the search for the config."
  (let* ((m (cassette:parse-mp4 (cassette::slurp-file path)))
         (tr (cassette:mp4-audio-track m)))
    (unless tr
      (error "~a has no audio track~@[ (its video is ~a, which reel does not decode)~]"
             (file-namestring path)
             (let ((v (cassette:mp4-video-track m))) (and v (cassette:track-codec-id v)))))
    (let ((asc (cassette:track-codec-private tr)))
      (unless (and asc (plusp (length asc)))
        (error "~a: the audio track carries no AudioSpecificConfig" (file-namestring path)))
      (multiple-value-bind (aot sri chan) (reed::aac-parse-asc asc 0 (length asc))
        (declare (ignore aot))
        (let* ((rate (let ((r (aref reed::+aac-sample-rates+ sri)))
                       (if (plusp r) r (round (or (cassette:track-sample-rate tr) 44100)))))
               (channels (if (plusp chan) chan (max 1 (cassette:track-channels tr))))
               (aus '())
               (r (cassette:make-mp4-reader m)))
          (loop for f = (cassette:read-next-mp4-frame r)
                while f
                do (when (eq (cassette:frame-track f) tr) (push (cassette:frame-data f) aus)))
          (let ((pcm (reed::aac-decode-access-units (nreverse aus) sri channels rate)))
            (%pcm->mono-48k pcm)))))))

;;; ---- audio files: reed ----------------------------------------------------------------------------------

(defun %run-audio-file (p gen kind path from)
  (ecase kind
    (:mp3
     (let* ((bytes (cassette::slurp-file path))
            (idx (let ((c (%mp3-index-for p path)))
                   (or c (let ((i (%build-mp3-index bytes)))
                           (with-player (p) (setf (%mp3-index p) (cons path i))) i))))
            (off (if (plusp from) (%mp3-offset idx from) (mi-first idx)))
            (rp (reed:make-mp3-player bytes :rate +rate+ :frame-samples +frame-samples+ :start off)))
       (%go-live p gen :has-video nil :has-audio t :duration (mi-duration idx))
       (loop
         (unless (%live-p p gen) (return))
         (let ((f (reed:player-next-frame rp)))
           (when (null f) (return))
           (unless (%push-audio p gen (list (%as-s16 f))) (return))))))
    ((:opus :aac)
     ;; whole-file decode, once per track: these are songs, and a seek into a song is an index
     (let* ((mono (or (%pcm-for p path)
                      (let ((m (ecase kind
                                 (:opus (%pcm->mono-48k (reed:decode-opus-file path)))
                                 (:aac (%pcm->mono-48k (reed:decode-aac-file path)))
                                 (:mp4 (%mp4-aac-mono path)))))
                        (with-player (p) (setf (%pcm-cache p) (cons path m)))
                        m)))
            (n (length mono)))
       (%go-live p gen :has-video nil :has-audio t :duration (/ n (float +rate+ 1d0)))
       (let ((pos (min n (floor (* from +rate+)))))
         (loop while (and (%live-p p gen) (< pos n))
               do (let ((end (min n (+ pos +frame-samples+))))
                    (unless (%push-audio p gen (list (subseq mono pos end))) (return))
                    (setf pos end))))))))

(defun %pcm-for (p path)
  (let ((c (with-player (p) (%pcm-cache p)))) (and c (equal (car c) path) (cdr c))))
(defun %mp3-index-for (p path)
  (let ((c (with-player (p) (%mp3-index p)))) (and c (equal (car c) path) (cdr c))))

(defun %as-s16 (v)
  (if (typep v '(simple-array (signed-byte 16) (*)))
      v
      (let ((out (make-array (length v) :element-type '(signed-byte 16))))
        (dotimes (i (length v) out)
          (setf (aref out i) (max -32768 (min 32767 (round (let ((x (aref v i))) (if (floatp x) (* x 32767) x))))))))))

(defun %pcm->mono-48k (pcm)
  "Any reed PCM -> mono s16 at 48 kHz."
  (let* ((mono (reed:downmix (reed:pcm-samples pcm) (reed:pcm-channels pcm)))
         (rate (reed:pcm-sample-rate pcm))
         (at-rate (if (= rate +rate+)
                      mono
                      (reed:resample (reed:make-resampler rate +rate+) mono :final t))))
    (%as-s16 at-rate)))
