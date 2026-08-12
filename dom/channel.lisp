;;;; dom/channel.lisp — a warp consumer on a channel, where a channel is a function that takes a
;;;; string.  No sockets, no WebRTC, no gateway, and nothing here knows which of those it is on.
;;;;
;;;; ===========================================================================================
;;;; WHY THIS FILE EXISTS AT ALL, GIVEN serve.lisp ALREADY DID THIS
;;;; ===========================================================================================
;;;;
;;;; serve.lisp's header says the swap onto a real data channel is three lines — ATTACH-DOM with a
;;;; different :SINK, ON-MESSAGE, DETACH — and that was true and is still true.  What it left
;;;; implicit is everything AROUND those three lines, and every one of those is a place a live
;;;; gateway can be broken:
;;;;
;;;;   * something has to TICK, on some clock, and stop ticking when the peer goes away;
;;;;   * ON-MESSAGE and TICK both touch this consumer's stream, so they need the same lock;
;;;;   * a SEND that raises — a closed association, a full queue, a peer that vanished mid-frame —
;;;;     must not take the tick loop down, and must not take the CALLER's thread down either;
;;;;   * DETACH has to happen on every exit path, including the ones nobody wrote.
;;;;
;;;; Those four are the whole of what a host has to get right, they are identical for a WebSocket
;;;; and for an SCTP stream, and they are exactly the part that cannot be tested from inside a
;;;; gateway.  So they live HERE, driven by a fake transport in t/channel.lisp, and what is left
;;;; over on the far side is: call OPEN-CHANNEL when the peer speaks, CHANNEL-RECEIVE when it
;;;; speaks again, CHANNEL-CLOSE when the session ends.  Three calls, none of which can signal.
;;;;
;;;; THE DESIGN CONSTRAINT IS THE SIZE OF WHAT IS LEFT.  A gateway is a thing we may not run, so
;;;; every line that ends up in one is a line verified by reading.  Minimising that count is not
;;;; tidiness, it is the only form of assurance available.
;;;;
;;;; WHAT A CHANNEL IS NOT.  It is not a session, not a peer, and not an authorization: INVOKER
;;;; arrives from whoever opened it and is never derived from anything the client said.  A client
;;;; that would like to be an owner may say so all it likes; rule 6 refuses it at invocation
;;;; regardless, and this file has no opinion because it has no information.

(in-package #:warp-dom)

(defclass dom-channel ()
  ((consumer :initarg :consumer :reader channel-consumer)
   (send :initarg :send :accessor channel-send
         :documentation "(lambda (frame-string)) — the whole of the transport, as one function.
A WebSocket write, SCTP-SEND-STRING on a stream id, an append to a list in a test.")
   (hz :initarg :hz :initform 8 :accessor channel-hz
       :documentation "Passes per second on this channel's own thread, or NIL for a channel the
caller ticks.  NIL is what the tests use: a clock is the one thing an assertion cannot share with
the code under test, and a host that already has a loop should keep using it.")
   (thread :initform nil :accessor channel-thread)
   (stop :initform nil :accessor channel-stop)
   (name :initarg :name :initform "warp" :accessor channel-name)
   ;; what this channel has actually done, so a host can log it without reaching inside
   (frames :initform 0 :accessor channel-frames)
   (bytes :initform 0 :accessor channel-bytes)
   (received :initform 0 :accessor channel-received)
   (send-errors :initform 0 :accessor channel-send-errors)
   (last-error :initform nil :accessor channel-last-error)
   (log :initarg :log :initform nil :accessor channel-log
        :documentation "(lambda (string)) for the things a host wants in its log, or NIL.  Errors
are COUNTED whether or not anyone is listening; this only decides who hears about them."))
  (:documentation "One DOM consumer, its clock, and its link — with the link reduced to a function."))

;;; ---- opening ------------------------------------------------------------------

(defun open-channel (projection &key send (view nil) (rows 12) (budget 4096)
                                     (invoker :device) (hz 8) (name "warp") log)
  "Seat a DOM consumer on PROJECTION and put its frames on SEND.  Returns a DOM-CHANNEL.

INVOKER IS THE CALLER'S AND HAS NO DEFAULT WORTH TRUSTING — it defaults to :DEVICE, the narrower
of the two, because a host that forgets to say who is asking should get the guest rather than the
owner.  Widening is a decision somebody has to make on purpose.

BUDGET IS BYTES.  That is DOM-CONSUMER's unit (DELTA-COST serialises to price), so the number here
is the number on the link, and it is the one thing that must change with the transport: a localhost
socket is handed a generous one and a cellular data channel a small one.

With HZ non-NIL this starts one thread that ticks until CHANNEL-CLOSE.  With HZ NIL nothing is
started and the caller drives CHANNEL-TICK."
  (let* ((c (attach-dom projection :view view :rows rows :budget budget :invoker invoker))
         (ch (make-instance 'dom-channel :consumer c :send send :hz hz :name name :log log)))
    ;; The sink is installed AFTER the consumer exists so it can close over the channel and count
    ;; what it puts on the link.  A frame that the transport refuses is still a frame the encoding
    ;; believes it delivered — the stream has already been advanced — so the counter that matters
    ;; is the one that saw the error, not the one that saw the frame.
    (setf (dom-sink c) (lambda (frame) (%channel-emit ch frame)))
    (when hz
      (setf (channel-thread ch)
            (bt:make-thread (lambda () (%channel-loop ch))
                            :name (format nil "warp-channel-~a" name))))
    ch))

(defun %channel-emit (ch frame)
  "Put one frame on the link.  Never signals: a transport that has gone away is an ordinary event
on a link, and the pass that produced this frame is not the place to find out about it."
  (incf (channel-frames ch))
  (incf (channel-bytes ch) (length frame))
  (let ((send (channel-send ch)))
    (when send
      (handler-case (funcall send frame)
        (error (e)
          (incf (channel-send-errors ch))
          (setf (channel-last-error ch) (princ-to-string e))
          ;; One report, then silence: a broken link breaks on every frame, and a log line per
          ;; frame at 8 Hz is how a diagnostic becomes the thing you have to diagnose.
          (when (and (channel-log ch) (= 1 (channel-send-errors ch)))
            (funcall (channel-log ch)
                     (format nil "warp channel ~a: send failed (~a)" (channel-name ch) e)))
          nil)))))

;;; ---- the clock -----------------------------------------------------------------

(defun channel-tick (ch)
  "One pass: whatever this consumer is owed, under its own budget, on its own link.  Returns the
deltas landed.  Safe to call from any thread — TICK takes the consumer's lock."
  (let ((c (channel-consumer ch)))
    (handler-case (tick c)
      (error (e)
        (setf (channel-last-error ch) (princ-to-string e))
        (when (channel-log ch)
          (funcall (channel-log ch) (format nil "warp channel ~a: tick ~a" (channel-name ch) e)))
        nil))))

(defun %channel-loop (ch)
  (let ((c (channel-consumer ch)))
    (loop until (or (channel-stop ch) (consumer-stop c)) do
      (channel-tick ch)
      (sleep (/ 1.0 (max 1 (channel-hz ch)))))))

;;; ---- the peer talking back ------------------------------------------------------

(defun channel-receive (ch text)
  "Apply one client message.  Returns (values kind detail) exactly as ON-MESSAGE does, and — like
everything else a host calls — NEVER SIGNALS: a malformed message from a peer is data, not a bug,
and a gateway thread must not unwind because somebody sent a `{`.

Held under the consumer's lock, which is the same lock TICK takes: a gesture that opens a menu and
a pass that would emit it cannot interleave, and neither can two messages arriving back to back."
  (incf (channel-received ch))
  (let ((c (channel-consumer ch)))
    (handler-case
        (bt:with-lock-held ((consumer-lock c)) (on-message c text))
      (error (e)
        (setf (channel-last-error ch) (princ-to-string e))
        (when (channel-log ch)
          (funcall (channel-log ch) (format nil "warp channel ~a: message ~a" (channel-name ch) e)))
        (values :error (princ-to-string e))))))

;;; ---- closing --------------------------------------------------------------------

(defun channel-close (ch)
  "Unseat the consumer and stop the clock.  Idempotent, and never signals — it is called from
unwind paths, which is the one place an error has nowhere to go.

DETACH is what makes a reconnect correct rather than merely possible: the consumer's stream is its
MEMORY of what the far end holds, and a peer that comes back is a peer holding nothing.  Keeping
the old consumer would hand it somebody else's high-water mark, which is rule 8's late-joiner bug
with the roles reversed."
  (setf (channel-stop ch) t)
  (let ((c (channel-consumer ch)))
    (ignore-errors (setf (consumer-stop c) t))
    (ignore-errors (setf (dom-sink c) nil))     ; nothing lands after the close, even mid-pass
    (ignore-errors (detach c)))
  (let ((th (channel-thread ch)))
    (when th
      (setf (channel-thread ch) nil)
      (ignore-errors (bt:join-thread th :timeout 2))))
  ch)

;;; ---- what a host wants to log ----------------------------------------------------

(defun channel-stats (ch)
  "A plist, so a host can report a channel without reaching into it."
  (let ((c (channel-consumer ch)))
    (list :name (channel-name ch)
          :invoker (consumer-invoker c)
          :rows (dom-rows c)
          :scroll (consumer-scroll-y c)
          :frames (channel-frames ch)
          :bytes (channel-bytes ch)
          :received (channel-received ch)
          :passes (consumer-passes c)
          :emitted (consumer-emitted c)
          :deferred (consumer-deferred c)
          :send-errors (channel-send-errors ch)
          :last-error (channel-last-error ch))))
