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
;;;; THE WORKER NEVER WRITES THE PLAYER.  It talks to it through a LINK -- one per track: an
;;;; inbox of messages, a cancel flag, and the counts of frames the player has taken (for
;;;; backpressure) -- and the player DRAINS the inbox whenever it is read (the thunk, the
;;;; presenter, the position).  So only the thread that owns the player ever writes it.  That is
;;;; what lets it run where threads share no memory (modus: a thread may not store its own objects
;;;; into memory another thread owns): the link and every message are SHARED on the way over
;;;; (%SHARE), frames are made in shared memory to begin with, and the worker is started from a
;;;; global function with its inputs as arguments, never a closure.  Elsewhere %SHARE is the
;;;; identity and nothing changes but the shape.
;;;;
;;;; PAUSE IS NIL, as in spool: the thunk returns NIL and the mixer plays silence, its clock never
;;;; stops, and no consumer has to be told anything.

(in-package #:warp-media)

;;; ---- handing values between threads ------------------------------------------------------------
;;;
;;; THE WORKER SENDS, IT DOES NOT SHARE.  The decode worker never writes the player's slots: it posts
;;; messages to its track's LINK -- frames, samples, the numbers and strings it learns about the file
;;; -- and the player drains them into its own slots when it is read (the LINK, below).  On SBCL
;;; that is ordinary locking.  On modus, threads share no memory: a thread's objects die with its
;;; region, and storing one where another thread can reach it is refused (the shared-store guard).
;;; There a message is copied into shared memory (%SHARE = MODUS:SHARE), and a picture is decoded
;;; straight into a MODUS:MAKE-SHARED-ARRAY buffer, so the 700 KB of it is never copied.

(defun %share (x)
  #+modus (modus:share x)
  #-modus x)

(defun %shared-octets (n)
  "An octet vector other threads may hold: made in shared memory on modus, so a picture is
   not copied on its way to the presenter."
  #+modus (modus:make-shared-array n :element-type '(unsigned-byte 8))
  #-modus (make-array n :element-type '(unsigned-byte 8)))

(defconstant +rate+ 48000)
(defconstant +frame-samples+ 960 "20 ms at 48 kHz — one mixer tick.")
(defparameter *audio-queue-max* 64 "Audio frames decoded ahead: 1.28 s.")
(defparameter *video-queue-max* 6 "Video frames decoded ahead.")

;;; ---- a decoded picture ---------------------------------------------------------------------------

(defvar *frame-format* :rgb
  "What a decoded picture becomes: :RGB (packed 8-bit RGB, VF-RGB) or :I420 (its own planes,
   VF-Y/-U/-V, tightly packed) -- for a framebuffer that is Y'CbCr itself (glass :I420), so a
   picture goes from the decoder to the screen without ever being RGB.")

;;; COOPERATIVE MODE: a machine with no threads.  The decoder is a GENERATOR either way (each call
;;; demuxes and decodes the next item: a video frame, or a run of audio frames, and posts what it
;;; learns -- live, a note, the base -- to the track's LINK).  With threads one worker drains it
;;; into the link and blocks while the player has a full queue's worth untaken; with *COOPERATIVE*
;;; nothing is spawned and PLAYER-FRAME-CURRENT, at UI rate, runs PLAYER-PUMP, which decodes until
;;; the link is full or *PUMP-BUDGET* seconds have gone.  A bare-metal board (kiln zero) without
;;; threads sets it; everything else leaves it NIL.
(defvar *cooperative* nil "True on a machine without threads: decode on the caller's thread.")
(defparameter *pump-budget* 0.03d0 "Seconds one PLAYER-PUMP may spend decoding.")

;;; THE FRAME POOL: frames the UI's thread makes, which the decoder fills.  On modus's bare-metal
;;; threads a picture made in shared memory (%SHARED-OCTETS) comes out of the runtime lock's arena,
;;; which only a stop-the-world collection gives back -- 4 MB on a Pi Zero, six RGB pictures.  With
;;; *FRAME-POOL* (and :I420 pictures) the UI's thread makes *FRAME-POOL-SIZE* frames of up to
;;; *FRAME-POOL-MAX* when a track opens; the decoder copies each picture's planes into a free one
;;; (bytes into the UI's arrays: numbers, not pointers) and the presenter gives frames back.
(defvar *frame-pool* nil "True: decoded pictures are copied into frames the UI's thread made.")
(defparameter *frame-pool-size* 8 "Frames in the pool: the video queue's six, the shown, a spare.")
(defparameter *frame-pool-max* '(640 368) "The largest picture (w h) a pool frame holds.")

;;; *READ-ON-UI*: the UI's thread reads a WebM/MP4 file and hands the decoder its bytes, rather than
;;; a path -- on modus's bare metal the filesystem's caches are the UI thread's objects, which the
;;; decoder may not fill.
(defvar *read-on-ui* nil "True: the UI's thread reads the file; the decoder opens bytes.")

(defstruct (video-frame (:conc-name vf-))
  (w 0 :type fixnum) (h 0 :type fixnum)
  (rgb nil)                                     ; packed 8-bit RGB, w*h*3 octets, or NIL
  (y nil) (u nil) (v nil)                       ; :I420 planes, w*h and ceil(w/2)*ceil(h/2)
  (no 0 :type fixnum)                           ; monotonically increasing; the fingerprint's part
  (timestamp 0d0 :type double-float)            ; seconds
  (pool -1 :type fixnum))                       ; its index in the player's frame pool, or -1

;;; ---- what crosses threads ------------------------------------------------------------------------

(defun %shared-s16 (v)
  "V, a (signed-byte 16) vector, where other threads may hold it."
  #+modus (let ((y (modus:make-shared-array (length v) :element-type '(signed-byte 16))))
            (replace y v) y)
  #-modus v)

(defstruct (link (:conc-name lk-))
  "Between one track's worker and the player: the worker posts, the player drains."
  (lock (bt:make-lock "warp-media-link"))
  (inbox '())                                   ; messages, newest first
  (cancelled nil)                               ; set by the player: superseded, stop
  (audio-posted 0) (audio-taken 0)              ; posted by the worker, taken by the player
  (video-posted 0) (video-taken 0)
  (pool nil) (pool-free nil))                   ; the player's frame pool, when *FRAME-POOL*

(defun %make-link () (%share (make-link)))

(defun %post (lk msg)
  (bt:with-lock-held ((lk-lock lk))
    (setf (lk-inbox lk) (%share (cons msg (lk-inbox lk)))))
  msg)

(defun %take (lk)
  (bt:with-lock-held ((lk-lock lk))
    (prog1 (reverse (lk-inbox lk)) (setf (lk-inbox lk) nil))))

(defun %spawn-decoder (&rest args)
  "Start a worker running %RUN-WORKER on ARGS.  A global function and its arguments, not a
   closure: on modus a closure cannot be handed to another thread, the arguments are copied."
  #+modus (sb-thread:make-thread #'%run-worker :arguments args :name "warp-media-decode")
  #-modus (bt:make-thread (lambda () (apply #'%run-worker args)) :name "warp-media-decode"))

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
   (link :initform nil :accessor %link :documentation "The current track's LINK, or NIL.")
   (coop :initform nil :accessor %coop
         :documentation "Cooperative mode: (link generator pending-item), or NIL.")
   ;; *FRAME-POOL*: frames made by the UI's thread, and a fixnum per frame: 1 free, 0 taken
   (pool :initform nil :accessor %pool)
   (pool-free :initform nil :accessor %pool-free)
   (pending-ended :initform nil :accessor %pending-ended
                  :documentation "A track ended under the lock; tell ON-CHANGE once it is released.")
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
   ;; RECURSIVE: reading a slot the worker reports drains the inbox first (see below), and
   ;; that read can happen with the lock already held.
   (lock :initform (bt:make-recursive-lock "warp-media-player") :reader %lock))
  (:documentation "Shared playback state — the query's argument.  One per window group, not per seat."))

(defun make-player (&key mixer (mixer-name "media"))
  (let ((p (make-instance 'player)))
    (when mixer (attach-mixer p mixer :name mixer-name))
    p))

(defmacro with-player ((p) &body body) `(bt:with-recursive-lock-held ((%lock ,p)) ,@body))

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
             (%drain-locked p)
             (let ((f (and (not (%has-audio p)) (player-frame p))))
               (if f (max (%base p) (vf-timestamp f)) (player-clock-seconds p))))))
    (if (player-duration p) (min s (player-duration p)) s)))

;; Both run on whichever thread changes the state -- the decoder going live, the end of a track --
;; so the doubles they store are shared (%SHARE).
(defun %wall-run (p) (unless (%wall-start p) (setf (%wall-start p) (%share (%now)))))
(defun %wall-hold (p)
  (when (%wall-start p)
    (setf (%wall-accum p) (%share (+ (%wall-accum p) (- (%now) (%wall-start p)))))
    (setf (%wall-start p) nil)))

;;; ---- the source thunk: the mixer's end -----------------------------------------------------------

(defun player-source (p)
  "P as a source thunk.  Hand it to a mixer once; it stays valid across tracks, pauses and seeks."
  (lambda ()
    (handler-case
        (prog1
         (with-player (p)
          (%drain-locked p)
          (when (eq (player-state p) :playing)
            (let ((f (pop (%audio-q p))))
              (cond
                (f (decf (%audio-n p)) (incf (%emitted p) (length f))
                   (let ((lk (%link p))) (when lk (incf (lk-audio-taken lk))))
                   f)
                ;; nothing queued: either the decoder is behind (silence, ask again) or it is
                ;; finished, in which case the track has ended once the picture has caught up —
                ;; promote what the clock allows first, since nobody else may be looking
                ((and (%worker-done p) (%has-audio p))
                 (%present-locked p)
                 ;; THE SOUND IS THE CLOCK AND IT HAS STOPPED, so a picture stamped past the
                 ;; last sample can never come due by it (a 6.5 s Vorbis track whose last frame
                 ;; is at 6.519 played to the end and never ENDED).  Within a tenth of a second
                 ;; of the clock, put it up now; a picture that outlasts its sound by more than
                 ;; that still waits, as before.
                 (let ((clock (player-clock-seconds p)) (shown nil))
                   (loop while (and (%video-q p)
                                    (<= (vf-timestamp (first (%video-q p))) (+ clock 0.1d0)))
                         do (setf shown (pop (%video-q p))) (decf (%video-n p)))
                   (when shown (setf (player-frame p) shown (player-frame-no p) (vf-no shown))))
                 (when (null (%video-q p)) (%finish-locked p))
                 nil)
                (t nil)))))
         (%fire-pending p))
      (serious-condition (e)
        ;; this runs on the mixer's 20 ms thread: a decode problem is one silent frame and a
        ;; state, never an escaping condition
        (setf (player-state p) :error (player-error p) (%share (princ-to-string e)))
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

;;; ---- the frame pool (*FRAME-POOL*) -------------------------------------------------------------

(defun %pool-ensure (p)
  "Make P's pool, on the calling thread (the UI's), if it has none.  The pool or NIL."
  (when (and *frame-pool* (eq *frame-format* :i420) (null (%pool p)))
    (destructuring-bind (mw mh) *frame-pool-max*
      (let* ((n *frame-pool-size*)
             (pool (make-array n))
             (free (make-array n :initial-element 1))
             (cw (ceiling mw 2)) (ch (ceiling mh 2)))
        (dotimes (i n)
          (setf (svref pool i)
                (make-video-frame :w 0 :h 0 :pool i
                                  :y (make-array (* mw mh) :element-type '(unsigned-byte 8))
                                  :u (make-array (* cw ch) :element-type '(unsigned-byte 8))
                                  :v (make-array (* cw ch) :element-type '(unsigned-byte 8)))))
        (setf (%pool-free p) free (%pool p) pool))))
  (%pool p))

(defun %pool-release (p f)
  "F is neither queued nor shown any more: back to the pool (a no-op for a frame not from it)."
  (when (and f (>= (vf-pool f) 0) (%pool-free p))
    (setf (svref (%pool-free p) (vf-pool f)) 1)))

(defun %pool-release-all (p)
  (let ((free (%pool-free p)))
    (when free (dotimes (i (length free)) (setf (svref free i) 1)))))

(defun %pool-take (lk w h)
  "A free pool frame big enough for W x H, taken; waits while all are in use (cooperative mode
   never does: the presenter runs between pumps).  NIL when there is no pool, the picture does
   not fit, every frame is taken in cooperative mode, or the track is superseded."
  (let ((pool (lk-pool lk)) (free (lk-pool-free lk)))
    (when (and pool (<= w (first *frame-pool-max*)) (<= h (second *frame-pool-max*)))
      (loop
        (unless (%live-p lk) (return nil))
        (let ((i (position 1 free)))
          (when i
            (setf (svref free i) 0)
            (return (svref pool i))))
        (when *cooperative* (return nil))
        (sleep 0.005)))))

(defun %fill-plane (out src off stride w h)
  "Rows W wide of a plane at OFF, STRIDE apart, into OUT, tightly."
  (dotimes (r h out)
    (replace out src :start1 (* r w) :start2 (+ off (* r stride)) :end2 (+ off (* r stride) w))))

;;; ---- the presenter: which frame is current ---------------------------------------------------------

(defun %present-locked (p)
  "Promote every queued frame whose time has come; the last of them is what is shown."
  (%drain-locked p)
  (let ((clock (player-clock-seconds p)) (shown nil) (taken 0))
    ;; the first picture of a track goes up at once, whatever its timestamp: a player that shows
    ;; black until the clock catches a 7 ms offset looks broken for exactly that long
    (when (and (null (player-frame p)) (%video-q p))
      (setf shown (pop (%video-q p))) (decf (%video-n p)) (incf taken))
    (loop while (and (%video-q p) (<= (vf-timestamp (first (%video-q p))) clock))
          do (when shown (%pool-release p shown))        ; passed over: never shown
             (setf shown (pop (%video-q p))) (decf (%video-n p)) (incf taken))
    (let ((lk (%link p))) (when (and lk (plusp taken)) (incf (lk-video-taken lk) taken)))
    (when shown
      (unless (eq shown (player-frame p)) (%pool-release p (player-frame p)))
      (setf (player-frame p) shown (player-frame-no p) (vf-no shown)))
    ;; a silent film ends when its last frame has been shown
    (when (and (%worker-done p) (null (%video-q p)) (not (%has-audio p))
               (eq (player-state p) :playing)
               (or (null (player-duration p)) (>= clock (player-duration p))))
      (%finish-locked p))
    shown))

(defun player-frame-current (p)
  "The frame to show now — promotes queued frames first.  Called from the query, at UI rate.
   In cooperative mode this is also where the decoder runs (PLAYER-PUMP)."
  (when *cooperative* (player-pump p))
  (prog1 (with-player (p) (%present-locked p) (player-frame p))
    (%fire-pending p)))

;;; READING WHAT THE WORKER REPORTS IS UP TO DATE.  The worker's news reaches the player only
;;; when the inbox is drained, so each slot it can change drains first when read -- the API reads
;;; exactly as it did when the worker wrote the slots itself.
(macrolet ((drains (&rest readers)
             `(progn ,@(loop for r in readers
                             collect `(defmethod ,r :before ((p player))
                                        (with-player (p) (%drain-locked p)))))))
  (drains player-state player-error player-duration player-has-video-p player-title
          player-frame player-frame-no))

(defun player-sync (p)
  "Apply what the worker has reported (state, duration, frames).  The thunk, the presenter and
   the position do this themselves; a caller that only reads PLAYER-STATE calls this first."
  (with-player (p) (%drain-locked p))
  (%fire-pending p)
  p)

;;; ---- state changes -----------------------------------------------------------------------------------

(defun %finish-locked (p)
  (setf (player-state p) :ended)
  (%wall-hold p)
  ;; ON-CHANGE may start the next track, which takes the lock: it runs once the lock is
  ;; released (%FIRE-PENDING), on the thread that noticed -- not on a thread of its own, which
  ;; would need a closure handed across.
  (setf (%pending-ended p) t))

(defun %fire-pending (p)
  "Run ON-CHANGE for a track that ended under the lock.  Called with the lock released."
  (when (%pending-ended p)
    (setf (%pending-ended p) nil)
    (let ((cb (player-on-change p)))
      (when cb (ignore-errors (funcall cb p :ended))))))

(defun %reset-locked (p)
  (incf (%generation p))
  (%pool-release-all p)
  (setf (%coop p) nil)
  (let ((lk (%link p))) (when lk (setf (lk-cancelled lk) t (%link p) nil)))
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
    (cond ((member type '("webm" "mkv") :test #'string=) :webm)
          ;; program and transport streams: cassette demuxes them and reel decodes what is inside,
          ;; which is MPEG-1, MPEG-2 or H.264 depending on the decade the file is from
          ((member type '("mpg" "mpeg" "vob" "ts" "m2ts") :test #'string=) :mpegsys)
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
      (%drain-locked p)                 ; the outgoing track's news first: its caches above all
      (%reset-locked p)
      (setf (player-state p) :loading
            (player-track p) (%share (pathname path))
            (player-title p) (%share (pathname-name path))
            (player-duration p) nil
            (player-has-video-p p) nil (%has-audio p) nil
            (player-frame p) nil
            (%base p) (%share (float from 1d0))
            (%worker-done p) nil)
      (let* ((lk (%make-link))
             ;; keyed by namestring: the worker is handed one (a string crosses threads; a
             ;; caller may pass a pathname)
             (name (namestring path))
             (pcm (let ((c (%pcm-cache p))) (and c (equal (car c) name) (cdr c))))
             (idx (let ((c (%mp3-index p))) (and c (equal (car c) name) (cdr c))))
             ;; *READ-ON-UI*: the bytes, read here, on the UI's thread
             (src (if (and *read-on-ui* (member kind '(:webm :mp4 :mpegsys)))
                      (cassette::slurp-file path)
                      name)))
        (setf (%link p) lk)
        (when (%pool-ensure p)
          (setf (lk-pool lk) (%pool p) (lk-pool-free lk) (%pool-free p)))
        (if *cooperative*
            ;; opening the file -- demux headers, go live -- happens now, on this thread
            (%coop-start p lk kind name from (and (player-mixer p) t) pcm idx src)
            ;; The caches go to the worker as arguments.  On modus they are left behind: a
            ;; whole song's PCM would be copied to get there, and a re-decode is cheaper.
            (setf (%worker p) (%spawn-decoder lk kind name from (and (player-mixer p) t)
                                              #+modus nil #-modus pcm
                                              #+modus nil #-modus idx
                                              src)))))
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
          (loop repeat 200 until (eq (player-state (player-sync p)) :playing) do (sleep 0.005))
          (pause p))))
    (player-position p)))

(defun seek-fraction (p fraction)
  "Jump to FRACTION (0..1) of a track whose duration is known."
  (let ((dur (player-duration p)))
    (when dur (seek p (* dur (max 0d0 (min 1d0 fraction)))))))

(defun skip (p delta) (seek p (+ (player-position p) delta)))

;;; ---- the worker: demux, decode, post -------------------------------------------------------------
;;;
;;; Everything below runs on the worker and touches only its LINK.  The player applies what it
;;; posts in %DRAIN-LOCKED.

(defun %live-p (lk) (not (lk-cancelled lk)))

(defun %push-audio (lk frames)
  "Post mono frames, blocking while the player has a full queue's worth untaken.  NIL when
   superseded."
  (dolist (f frames t)
    (loop
      (unless (%live-p lk) (return-from %push-audio nil))
      (when (< (- (lk-audio-posted lk) (lk-audio-taken lk)) *audio-queue-max*)
        (%post lk (list :audio (%shared-s16 f)))
        (incf (lk-audio-posted lk))
        (return))
      (sleep 0.01))))

(defun %push-video (lk frame)
  (loop
    (unless (%live-p lk) (return-from %push-video nil))
    (when (< (- (lk-video-posted lk) (lk-video-taken lk)) *video-queue-max*)
      (%post lk (list :video frame))
      (incf (lk-video-posted lk))
      (return t))
    (sleep 0.005)))

(defun %go-live (lk &key has-video has-audio duration title)
  "The worker knows what the file is: tell the player, which starts the clock."
  (when (%live-p lk)
    (%post lk (list :live has-video has-audio duration title))))

(defun %fail (lk e)
  (when (%live-p lk) (%post lk (list :error (princ-to-string e)))))

(defvar *draining* nil "True inside %DRAIN-LOCKED, so a slot read it makes does not drain again.")

(defun %drain-locked (p)
  "Apply every message the current track's worker has posted.  The player's lock is held."
  (let ((lk (and (not *draining*) (%link p))) (*draining* t))
    (when lk
      (dolist (m (%take lk))
        (case (first m)
          (:base (setf (%base p) (second m)))
          (:live
           (destructuring-bind (has-video has-audio duration title) (rest m)
             (setf (player-has-video-p p) has-video
                   (%has-audio p) (and has-audio (player-mixer p) t)
                   (player-duration p) duration)
             (when title (setf (player-title p) title))
             (when (eq (player-state p) :loading)
               (setf (player-state p) :playing)
               (%wall-run p))
             (let ((cb (player-on-change p)))
               (when cb (ignore-errors (funcall cb p :started))))))
          (:audio (setf (%audio-q p) (nconc (%audio-q p) (list (second m))))
                  (incf (%audio-n p)))
          (:video (setf (%video-q p) (nconc (%video-q p) (list (second m))))
                  (incf (%video-n p)))
          (:error (setf (player-state p) :error (player-error p) (second m)))
          (:note (setf (player-error p) (second m)))
          (:no-video (setf (player-has-video-p p) nil))
          (:pcm-cache (setf (%pcm-cache p) (cons (second m) (third m))))
          (:mp3-index (setf (%mp3-index p) (cons (second m) (third m))))
          (:done (setf (%worker-done p) t)))))))

(defun %make-generator (lk kind path from has-mixer pcm idx &optional (src path))
  "Open the track and go live; the thunk that yields the next item -- (:VIDEO . frame) or
   (:AUDIO . mono-frames) -- or NIL when the track is done or superseded.  SRC is PATH, or the
   file's bytes (*READ-ON-UI*)."
  (ecase kind
    ((:webm :mp4 :mpegsys) (%container-generator lk path from has-mixer pcm src))
    ((:mp3 :opus :aac) (%audio-file-generator lk kind path from pcm idx))))

(defun %run-worker (lk kind path from has-mixer pcm idx &optional (src path))
  "The decode thread: drain the generator into the link, blocking while the player has a full
   queue's worth untaken."
  ;; reed's decoder tables are built on first use; this thread gets its own (on modus a worker
  ;; may not fill the loading thread's).
  (handler-case
      (reed:with-thread-state ()
        (let ((next (%make-generator lk kind path from has-mixer pcm idx src)))
          (loop for item = (funcall next)
                while item
                do (unless (if (eq (car item) :video)
                               (%push-video lk (cdr item))
                               (%push-audio lk (cdr item)))
                     (return)))))
    (serious-condition (e) (%fail lk e)))
  (when (%live-p lk) (%post lk (list :done))))

;;; ---- cooperative mode: the same generator, drained by the UI ----------------------------------

(defun %coop-start (p lk kind path from has-mixer pcm idx src)
  (handler-case
      (let ((next (%make-generator lk kind path from has-mixer pcm idx src)))
        (with-player (p) (when (eq (%link p) lk) (setf (%coop p) (list lk next nil)))))
    (serious-condition (e) (%fail lk e) (%post lk (list :done)))))

(defun %try-post (lk item)
  "Post as much of ITEM as the player has room for, without waiting.  What is left, or NIL."
  (cond ((not (%live-p lk)) nil)
        ((eq (car item) :video)
         (if (< (- (lk-video-posted lk) (lk-video-taken lk)) *video-queue-max*)
             (progn (%post lk (list :video (cdr item))) (incf (lk-video-posted lk)) nil)
             item))
        (t
         (let ((frames (cdr item)))
           (loop while (and frames (< (- (lk-audio-posted lk) (lk-audio-taken lk)) *audio-queue-max*))
                 do (%post lk (list :audio (%shared-s16 (pop frames))))
                    (incf (lk-audio-posted lk)))
           (and frames (cons :audio frames))))))

(defun player-pump (p &optional (budget *pump-budget*))
  "Cooperative mode: decode until the player's queues are full, the track is done, or BUDGET
   seconds have passed.  T while there is more to decode."
  (let ((c (%coop p)))
    (when c
      (destructuring-bind (lk next pending) c
        (let ((deadline (+ (%now) budget)))
          (handler-case
              (loop
                (cond ((not (%live-p lk)) (setf (%coop p) nil) (return))
                      (pending
                       (setf pending (%try-post lk pending))
                       (when pending (return)))                     ; full: later
                      (t
                       (let ((item (funcall next)))
                         (if item
                             (setf pending item)
                             (progn (%post lk (list :done)) (setf (%coop p) nil) (return))))))
                (when (> (%now) deadline) (return)))
            (serious-condition (e)
              (%fail lk e) (%post lk (list :done)) (setf (%coop p) nil)))
          (when (eq (%coop p) c) (setf (third c) pending))))))
  (and (%coop p) t))

;;; ---- WebM: video and Opus, interleaved --------------------------------------------------------------

;;; RATE CONVERSION FOR PLAYBACK.  reed's resampler is the right one -- a windowed sinc, stateful
;;; across packets -- and on modus it makes 32 000 samples a second, short of the 48 000 a second
;;; it must make (double-float arithmetic is modus's slow path today).  So on modus the player
;;; converts by linear interpolation in 16.16 fixed point: fixnum arithmetic only, and good enough
;;; for a phone's speaker.  Everywhere else it is reed's.
(defstruct (%lin-rs (:constructor %make-lin-rs (step)))
  (step 0 :type fixnum)      ; input samples per output sample, 16.16
  (pos 0 :type fixnum)       ; next output's position, 16.16, counted from PREV
  (prev 0 :type fixnum))     ; the last input sample of the previous block

(defun %make-rate-converter (in out)
  #+modus (%make-lin-rs (floor (* in 65536) out))
  #-modus (reed:make-resampler in out))

(defun %lin-resample (rs raw)
  "RAW (s16) through linear converter RS; returns the s16 output it makes now."
  (declare (type (simple-array (signed-byte 16) (*)) raw))
  (let* ((n (length raw)) (step (%lin-rs-step rs)) (pos (%lin-rs-pos rs)) (prev (%lin-rs-prev rs))
         (count (if (< pos (* n 65536)) (ceiling (- (* n 65536) pos) step) 0))
         (out (make-array count :element-type '(signed-byte 16))))
    (declare (type fixnum n step pos prev count))
    ;; the stream is PREV, RAW[0], RAW[1], ...: index I of it is RAW[I-1]
    (dotimes (k count)
      (let* ((i (ash pos -16)) (f (logand pos #xFFFF))
             (a (if (= i 0) prev (aref raw (1- i))))
             (b (aref raw i)))
        (declare (type fixnum i f a b))
        (setf (aref out k) (ash (+ (* a (- 65536 f)) (* b f)) -16))
        (incf pos step)))
    (when (plusp n)
      (setf (%lin-rs-prev rs) (aref raw (1- n))
            (%lin-rs-pos rs) (- pos (* n 65536))))
    out))

(defun %convert-rate (rs raw)
  (if (%lin-rs-p rs) (%lin-resample rs raw) (reed:resample rs raw)))

(defun %pcm->mono-frames (pcm carry &optional rs)
  "reed's float32 PCM struct (interleaved) -> a list of 960-sample s16 mono frames at 48 kHz.
   CARRY is the partial frame left over from last time; returns (values frames new-carry).

   RS, a reed resampler from the decoder's rate to +RATE+, when the two differ.  The frames ARE
   the clock (PLAYER-POSITION counts the samples the mixer took), so 22.05 kHz Vorbis framed as
   if it were 48 kHz did not just play fast: the clock ran at less than half speed, every
   picture came due late, and once the picture queue filled the decoder stopped -- sound and
   all.  Stateful, so the caller keeps one for the stream."
  (let* ((samples (reed:pcm-samples pcm))
         (ch (reed:pcm-channels pcm))
         (n (floor (length samples) ch))
         (raw (make-array n :element-type '(signed-byte 16)))
         (frames '()))
    ;; THE PCM SAYS ITS SCALE (reed's FORMAT tag): :FLOAT32 is [-1,1] (Vorbis, Opus), :PCM16 is
    ;; already 16-bit (FLAC).  Scaling the second by 32767 too clipped every FLAC sample to the
    ;; rails -- a tone became a square wave.  The integer case stays integer, which is also the
    ;; fast one on modus.
    (if (eq (reed:pcm-format pcm) :pcm16)
        (dotimes (i n)
          (let ((acc 0))
            (dotimes (c ch) (incf acc (aref samples (+ (* i ch) c))))
            (setf (aref raw i) (max -32768 (min 32767 (floor acc ch))))))
        (dotimes (i n)
          (let ((acc 0d0))
            (dotimes (c ch) (incf acc (aref samples (+ (* i ch) c))))
            (setf (aref raw i)
                  (let ((v (round (* (/ acc ch) 32767))))
                    (max -32768 (min 32767 v)))))))
    (let* ((conv (if rs (%convert-rate rs raw) raw))
           (mono (make-array (+ (length carry) (length conv)) :element-type '(signed-byte 16)))
           (pos 0) (total (+ (length carry) (length conv))))
      (replace mono carry)
      (replace mono conv :start1 (length carry))
      (loop while (<= (+ pos +frame-samples+) total)
            do (push (subseq mono pos (+ pos +frame-samples+)) frames)
               (incf pos +frame-samples+))
      (values (nreverse frames) (subseq mono pos)))))

(defun %copy-plane (src off stride w h)
  "Rows W wide of a plane at OFF, STRIDE apart, as one tight W*H vector (a copy: the decoder
   reuses its planes as references for the frames after)."
  (let ((out (%shared-octets (* w h))))
    (dotimes (r h out)
      (replace out src :start1 (* r w) :start2 (+ off (* r stride)) :end2 (+ off (* r stride) w)))))

(defun %picture->frame (pic no &optional lk)
  "PIC as a VIDEO-FRAME: copied into a frame of the player's pool when LK carries one (and it
   fits), else a fresh frame in shared memory.  NIL when the pool has no free frame in cooperative
   mode, or the track is superseded."
  (let* ((w (cassette:picture-width pic)) (h (cassette:picture-height pic))
         (ts (float (or (cassette:picture-timestamp pic) 0d0) 1d0))
         (pooled (and lk (eq *frame-format* :i420) (lk-pool lk) (%pool-take lk w h))))
    (when pooled
      ;; BYTES into the UI's frame; the one number that is not a fixnum goes shared
      (let ((cw (ceiling w 2)) (ch (ceiling h 2))
            (cs (cassette:picture-uv-stride pic)) (co (cassette:picture-uv-offset pic)))
        (%fill-plane (vf-y pooled) (cassette:picture-y pic) (cassette:picture-y-offset pic)
                     (cassette:picture-y-stride pic) w h)
        (%fill-plane (vf-u pooled) (cassette:picture-u pic) co cs cw ch)
        (%fill-plane (vf-v pooled) (cassette:picture-v pic) co cs cw ch)
        (setf (vf-w pooled) w (vf-h pooled) h (vf-no pooled) no
              (vf-timestamp pooled) (%share ts))
        (return-from %picture->frame pooled)))
    (when (and lk (lk-pool lk) (eq *frame-format* :i420)
               (<= w (first *frame-pool-max*)) (<= h (second *frame-pool-max*)))
      ;; the pool would have held it: no free frame (cooperative) or superseded -- skip it
      (return-from %picture->frame nil))
    ;; Not %SHARE'd here: the frame travels in a message, and %POST shares the message.  Its
    ;; planes or pixels are %SHARED-OCTETS already, so the big part is never copied.
    (if (eq *frame-format* :i420)
        (let ((cw (ceiling w 2)) (ch (ceiling h 2))
              (cs (cassette:picture-uv-stride pic)) (co (cassette:picture-uv-offset pic)))
          (make-video-frame
           :w w :h h :no no :timestamp ts
           :y (%copy-plane (cassette:picture-y pic) (cassette:picture-y-offset pic)
                           (cassette:picture-y-stride pic) w h)
           :u (%copy-plane (cassette:picture-u pic) co cs cw ch)
           :v (%copy-plane (cassette:picture-v pic) co cs cw ch)))
        (let ((rgb (%shared-octets (* w h 3))))
          (cassette:picture->rgb-into pic rgb)
          (make-video-frame :w w :h h :rgb rgb :no no :timestamp ts)))))

(defun %audio-gave-up (lk e)
  "The audio track would not decode.  Say so where the transport shows it, and play the picture."
  (when (%live-p lk) (%post lk (list :note (format nil "audio stopped: ~a" e)))))

(defun %video-gave-up (lk e any-frames-p)
  "The video track stopped decoding part way through.  Keep playing the sound.

   This is the difference between a media player and a decoder test.  A file can carry a picture
   this decoder does not do yet — H.264 P slices are the live example — and the sound in it is
   still perfectly good sound.  Going silent over a picture nobody asked about is the worse
   failure, so the picture is dropped, the reason is put where the transport shows it, and the
   audio runs to the end.  ANY-FRAMES-P keeps the last decoded picture on screen when some frames
   did land; when none did, the layout gives the space back."
  (when (%live-p lk)
    (unless any-frames-p (%post lk (list :no-video)))
    (%post lk (list :note (format nil "video stopped: ~a" e)))))

(defun %container-generator (lk path from has-mixer pcm &optional (src path))
  "A WebM or an MP4 as a generator (%MAKE-GENERATOR): video through cassette (VP8 or H.264), audio
   through whichever decoder the track needs.  SRC is PATH or the file's bytes.

   Written against cassette's PUBLIC api rather than its internals, which is what lets one
   function cover both containers and both video codecs: NEXT-VIDEO-FRAME already knows whether
   it is feeding a VP8 or an H.264 decoder, and the caller does not have to.

   The one thing cassette cannot do per packet is AAC, so an MP4's audio is decoded whole, once,
   and paced against the picture here.  That is why the interleave is explicit: the worker has to
   keep sound ahead of vision, or the bounded video queue stalls the audio it is meant to stay in
   step with."
  (let* ((wp (cassette:open-media src :audio has-mixer))
         (vt (cassette:player-video-track wp))
         (at (cassette:player-audio-track wp))
         (duration (cassette:player-duration wp))
         (landed (if (plusp from) (or (cassette:seek-media wp from) 0d0) 0d0))
         (start (max (float from 1d0) landed))
         ;; an MP4's AAC track: cassette demuxes it, reed decodes it, cached per track
         (aac (when (and (null at) has-mixer
                         (member (string-downcase (or (pathname-type path) ""))
                                 '("mp4" "m4a") :test #'string=))
                (or pcm
                    ;; NOT ignore-errors.  A file whose sound will not decode is worth saying out
                    ;; loud: swallowing it here is indistinguishable from a file that has no sound,
                    ;; and the two want different things from whoever is listening.
                    (let ((m (handler-case (%mp4-aac-mono path)
                               (serious-condition (e) (%audio-gave-up lk e) nil))))
                      #-modus (when m (%post lk (list :pcm-cache path m)))
                      m))))
         (aac-pos (if aac (min (length aac) (floor (* start +rate+))) 0))
         (carry (make-array 0 :element-type '(signed-byte 16)))
         (rs nil)                         ; the audio's rate -> +RATE+, made on first packet
         (no 0))
    (declare (type fixnum aac-pos no))
    ;; a video track the container refused outright — a codec we do not decode, or parameter sets
    ;; we cannot parse — reports itself the same way one that gives up part way does
    (let ((note (cassette:player-video-note wp)))
      (when (and note (null vt) (%live-p lk))
        (%post lk (list :note (format nil "video stopped: ~a" note)))))
    (when (%live-p lk) (%post lk (list :base start)))
    (%go-live lk :has-video (and vt t) :has-audio (or (and at t) (and aac t))
              :duration (or duration (and aac (/ (length aac) (float +rate+ 1d0)))))
    (let ((out '()) (tail nil) (finished nil))
      (labels ((emit (item)
                 (let ((cell (list item)))
                   (if out (setf (cdr tail) cell) (setf out cell))
                   (setf tail cell)))
               (emit-audio (frames) (when frames (emit (cons :audio frames))))
               (pump-audio-to (target)
                 (cond
                   (aac
                    (loop while (and (< (/ aac-pos (float +rate+ 1d0)) target)
                                     (< aac-pos (length aac)))
                          do (let ((end (min (length aac) (+ aac-pos +frame-samples+))))
                               (emit-audio (list (subseq aac aac-pos end)))
                               (setf aac-pos end))))
                   (at
                    (loop
                      (multiple-value-bind (pcm ts) (cassette:next-audio-frame wp)
                        (unless pcm (return))
                        (when (>= ts (- start 0.0105d0))
                          (when (and (null rs) (/= (reed:pcm-sample-rate pcm) +rate+))
                            (setf rs (%make-rate-converter (reed:pcm-sample-rate pcm) +rate+)))
                          (multiple-value-bind (frames c) (%pcm->mono-frames pcm carry rs)
                            (setf carry c)
                            (emit-audio frames)))
                        (when (> ts target) (return)))))))
               (step-once ()
                 (let ((pic (and vt (handler-case (cassette:next-video-frame wp)
                                      (serious-condition (e) (%video-gave-up lk e (plusp no))
                                        (setf vt nil) nil)))))
                   (cond
                     (pic
                      (let ((ts (or (cassette:picture-timestamp pic) 0d0)))
                        ;; sound ahead of vision: the bounded video queue must not stall it
                        (pump-audio-to (+ ts 1d0))
                        (when (>= ts (- start 0.017d0))
                          (let ((f (%picture->frame pic (incf no) lk)))
                            (when f (emit (cons :video f)))))))
                     (t
                      (pump-audio-to most-positive-double-float)
                      (setf finished t))))))
        (lambda ()
          (loop
            (when out (return (pop out)))
            (when (or finished (not (%live-p lk))) (return nil))
            (step-once)))))))

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

(defun %audio-file-generator (lk kind path from pcm idx)
  (ecase kind
    (:mp3
     (let* ((bytes (cassette::slurp-file path))
            (idx (or idx (let ((i (%build-mp3-index bytes)))
                           (%post lk (list :mp3-index path i))
                           i)))
            (off (if (plusp from) (%mp3-offset idx from) (mi-first idx)))
            (rp (reed:make-mp3-player bytes :rate +rate+ :frame-samples +frame-samples+ :start off)))
       (%go-live lk :has-video nil :has-audio t :duration (mi-duration idx))
       (lambda ()
         (when (%live-p lk)
           (let ((f (reed:player-next-frame rp)))
             (and f (cons :audio (list (%as-s16 f)))))))))
    ((:opus :aac)
     ;; whole-file decode, once per track: these are songs, and a seek into a song is an index
     (let* ((mono (or pcm
                      (let ((m (ecase kind
                                 (:opus (%pcm->mono-48k (reed:decode-opus-file path)))
                                 (:aac (%pcm->mono-48k (reed:decode-aac-file path)))
                                 (:mp4 (%mp4-aac-mono path)))))
                        #-modus (%post lk (list :pcm-cache path m))
                        m)))
            (n (length mono))
            (pos (min n (floor (* from +rate+)))))
       (%go-live lk :has-video nil :has-audio t :duration (/ n (float +rate+ 1d0)))
       (lambda ()
         (when (and (%live-p lk) (< pos n))
           (let ((end (min n (+ pos +frame-samples+))))
             (prog1 (cons :audio (list (subseq mono pos end)))
               (setf pos end)))))))))

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
