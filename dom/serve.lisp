;;;; dom/serve.lisp — a local WebSocket server, so a real browser can be a warp consumer today.
;;;;
;;;; ===========================================================================================
;;;; HOW THIS ATTACHES TO THE REAL CHANNEL, once somebody wants it there
;;;; ===========================================================================================
;;;;
;;;; The gateway already runs a WebRTC peer connection to the phone with a data channel called
;;;; `control` carrying the gesture/command traffic beside the video.  A DOM consumer belongs on a
;;;; second channel beside it — call it `warp` — and the swap is THREE LINES, because the encoding
;;;; never learned what a socket is:
;;;;
;;;;   1. on datachannel open, seat one:
;;;;          (setf *c* (warp-dom:attach-dom *projection*
;;;;                                         :view 'monitor-view :rows 14 :budget 4096
;;;;                                         :invoker (invoker-for-peer peer)
;;;;                                         :sink (lambda (frame) (dc-send channel frame))))
;;;;      DOM-SINK is a function of one string.  `dc-send` is whatever the gateway already calls to
;;;;      put a string on a data channel; nothing in warp-dom knows or cares which it is.
;;;;   2. on message:   (warp-dom:on-message *c* text)
;;;;   3. on close:     (warp:detach *c*)
;;;;
;;;; and the pass loop below (TICK at some Hz) is unchanged.  Two things are worth saying because
;;;; they are what makes that swap safe rather than merely short:
;;;;
;;;;   * BUDGET is the one number that must change with the transport, and it changes in the right
;;;;     direction on its own terms: this file's default is generous because localhost is, and a
;;;;     cellular data channel would be handed a smaller one.  It is bytes either way, which is the
;;;;     whole reason DELTA-COST was made generic.
;;;;   * INVOKER is the peer's, not the server's.  The gateway already knows whether a peer is on
;;;;     the allowlist or is an enrolled device; that value goes in here and rule 6 does the rest at
;;;;     invocation.  A browser is not trusted more for having a nicer client.
;;;;
;;;; None of that is exercised here on purpose.  The live gateway is carrying a user's session and
;;;; is not something to prove a JSON delta against.

(in-package #:warp-dom)

(defvar *server-stop* nil)

(defun client-page ()
  (with-open-file (in (asdf:system-relative-pathname "warp-dom" "client.html"))
    (let ((s (make-string (file-length in))))
      (subseq s 0 (read-sequence s in)))))

(defstruct (dom-server (:conc-name ds-))
  socket port projection thread (consumers '()) (stop nil) (hz 8)
  view rows budget invoker)

(defun serve-dom (projection &key (port 8787) view (rows 14) (budget 100000)
                                  (invoker :allowlist) (hz 8))
  "Serve PROJECTION to browsers on PORT.  Every connection is its OWN consumer — its own stream, its
own budget, its own scroll, its own menu — which is rule 8 arriving for free: two tabs are two
consumers over one query, exactly as two glass windows are.

Returns a DOM-SERVER; STOP-DOM shuts it down."
  (let* ((sock (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp))
         (srv (make-dom-server :socket sock :port port :projection projection :hz hz
                               :view view :rows rows :budget budget :invoker invoker)))
    (setf (sb-bsd-sockets:sockopt-reuse-address sock) t)
    (sb-bsd-sockets:socket-bind sock #(127 0 0 1) port)
    (sb-bsd-sockets:socket-listen sock 8)
    (setf (ds-thread srv)
          (bt:make-thread
           (lambda ()
             (loop until (ds-stop srv) do
               (handler-case
                   (let ((conn (sb-bsd-sockets:socket-accept sock)))
                     (bt:make-thread (lambda () (serve-connection srv conn))
                                     :name "warp-dom-conn"))
                 (error (e)
                   (unless (ds-stop srv)
                     (format *error-output* "~&[warp-dom] accept: ~a~%" e))
                   (return)))))
           :name "warp-dom-accept"))
    srv))

(defun stop-dom (srv)
  (setf (ds-stop srv) t)
  (dolist (c (ds-consumers srv)) (setf (consumer-stop c) t) (detach c))
  (handler-case (sb-bsd-sockets:socket-close (ds-socket srv)) (error () nil))
  srv)

(defun serve-connection (srv conn)
  (let ((stream (sb-bsd-sockets:socket-make-stream conn :input t :output t
                                                        :element-type '(unsigned-byte 8))))
    (unwind-protect
         (multiple-value-bind (method path headers) (read-http-request stream)
           (cond
             ((null method) nil)
             ((and (string= method "GET") (eql 0 (search "/warp" path)))
              (when (ws-accept stream headers)
                (run-consumer srv stream (invoker-for path (ds-invoker srv)))))
             ((string= method "GET")
              (http-respond stream "200 OK" "text/html; charset=utf-8" (client-page)))
             (t (http-respond stream "405 Method Not Allowed" "text/plain" "no"))))
      (handler-case (close stream) (error () nil))
      (handler-case (sb-bsd-sockets:socket-close conn) (error () nil)))))

(defun invoker-for (path default)
  "The invoker for a connection at PATH.  `/warp?as=device` NARROWS to :device; there is no query
string that widens anything, and there never must be.

A client picking its own authority is the second enforcement point rule 6 refuses, so this exists
only so the demo can seat an owner and a guest at one projection from one browser.  In the gateway,
the invoker comes from the AUTHENTICATED PEER — the allowlist npub or the enrolled device's bearer —
and this function does not exist."
  (if (search "as=device" path) :device default))

(defun run-consumer (srv stream &optional (invoker (ds-invoker srv)))
  "One browser, one consumer.  The socket is the SINK and nothing more: the encoding hands it a
string and this function puts it on the wire."
  (let* ((lock (bt:make-lock "warp-dom-write"))
         (c (attach-dom (ds-projection srv)
                        :view (ds-view srv) :rows (ds-rows srv)
                        :budget (ds-budget srv) :invoker invoker
                        :sink (lambda (frame)
                                (bt:with-lock-held (lock)
                                  (handler-case (ws-send-text stream frame)
                                    (error () nil)))))))
    (push c (ds-consumers srv))
    ;; the pass loop: a tick is a pass, and a pass emits only what the budget affords
    (let ((ticker (bt:make-thread
                   (lambda ()
                     (loop until (or (consumer-stop c) (ds-stop srv)) do
                       (handler-case (tick c)
                         (error (e) (format *error-output* "~&[warp-dom] tick: ~a~%" e)))
                       (sleep (/ 1.0 (ds-hz srv)))))
                   :name "warp-dom-tick")))
      (unwind-protect
           ;; and the read loop: recognized gestures and viewport reports, coming back by KEY
           (loop
             (multiple-value-bind (text opcode) (ws-read-message stream)
               (when (or (null text) (eql opcode 8)) (return))
               (when (eql opcode 1)
                 (bt:with-lock-held ((consumer-lock c))
                   (handler-case (on-message c text)
                     (error (e) (format *error-output* "~&[warp-dom] message: ~a~%" e)))))))
        (setf (consumer-stop c) t)
        (detach c)
        (setf (ds-consumers srv) (remove c (ds-consumers srv)))
        (ignore-errors (bt:join-thread ticker :timeout 2))
        (ws-send-close stream)))))
