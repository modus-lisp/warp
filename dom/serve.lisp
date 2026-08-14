;;;; dom/serve.lisp — a local WebSocket server, so a real browser can be a warp consumer today.
;;;;
;;;; ===========================================================================================
;;;; THE SWAP THIS HEADER USED TO DESCRIBE HAS HAPPENED — see channel.lisp
;;;; ===========================================================================================
;;;;
;;;; This header said the move onto the gateway's real data channel was three lines, because the
;;;; encoding never learned what a socket is.  That was right, and it was also not the whole bill.
;;;; Doing it found four things around those three lines — a clock, one lock over ticks and
;;;; messages, a send that must not signal, and a close that runs on every unwind path — which are
;;;; IDENTICAL for a WebSocket and for an SCTP stream and which this file had quietly written out
;;;; by hand.  They are channel.lisp now, and this file is one of its two callers:
;;;;
;;;;   (open-channel projection :send #'put-a-string-somewhere :invoker <the peer's> :budget <bytes>)
;;;;   (channel-receive ch text)
;;;;   (channel-close ch)
;;;;
;;;; Two things the swap confirmed, both of them predicted here:
;;;;
;;;;   * BUDGET is the one number that must change with the transport, and it changes on its own
;;;;     terms: this file's default is generous because localhost is; the data channel is handed a
;;;;     small one.  It is bytes either way, which is the whole reason DELTA-COST was made generic.
;;;;   * INVOKER is the peer's, not the server's — and INVOKER-FOR below, which lets a query string
;;;;     NARROW it, is exactly the thing that does not exist on the other side: there it comes from
;;;;     the authenticated Nostr identity, and a browser is not trusted more for having a nicer
;;;;     client.
;;;;
;;;; This file keeps its own accept/read loops rather than being rewritten in terms of the channel,
;;;; because a listening socket has a shape a data channel does not — a page to serve, an upgrade
;;;; to negotiate, and a blocking read that IS its clock.  What it no longer has is a second copy
;;;; of the four disciplines above.

(in-package #:warp-dom)

(defvar *server-stop* nil)

(defun client-file (name)
  (with-open-file (in (asdf:system-relative-pathname "warp-dom" name))
    (let ((s (make-string (file-length in))))
      (subseq s 0 (read-sequence s in)))))

(defun client-page () (client-file "client.html"))

(defstruct (dom-server (:conc-name ds-))
  socket port projection thread (consumers '()) (stop nil) (hz 8)
  view rows budget invoker (apps '()))

(defun serve-dom (projection &key (port 8787) view (rows 14) (budget 100000)
                                  (invoker :allowlist) (hz 8) (apps '()))
  "Serve PROJECTION to browsers on PORT.  Every connection is its OWN consumer — its own stream, its
own budget, its own scroll, its own menu — which is rule 8 arriving for free: two tabs are two
consumers over one query, exactly as two glass windows are.

APPS are FURTHER projections on the same connection, as (id . plist) with :PROJECTION and optionally
:VIEW :ATTACH :ROWS :BUDGET — the multiplex the gateway needs, driven here so it can be checked
without one.  PROJECTION is the default app, the one a message with no `a` routes to and the one
whose frames go back unlabelled.

Returns a DOM-SERVER; STOP-DOM shuts it down."
  (let* ((sock (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp))
         (srv (make-dom-server :socket sock :port port :projection projection :hz hz
                               :view view :rows rows :budget budget :invoker invoker :apps apps)))
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
             ;; client.js is served rather than inlined because it is SHARED: the glass-webrtc
             ;; phone client loads the same file, and a page that inlined its own copy would be
             ;; the second client this encoding is not going to have.
             ((and (string= method "GET") (eql 0 (search "/client.js" path)))
              (http-respond stream "200 OK" "application/javascript; charset=utf-8"
                            (client-file "client.js")))
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

(defun %app-channel (srv stream lock invoker app)
  "Open the channel for APP on this connection, or NIL if this server does not serve it.  This is
the whole of what a host supplies to MAKE-MUX, on either side of the line."
  (let ((spec (and app (cdr (assoc app (ds-apps srv) :test #'equal)))))
    (when (or (null app) spec)
      (open-channel (if spec (getf spec :projection) (ds-projection srv))
                    :send (lambda (frame)
                            (bt:with-lock-held (lock) (ws-send-text stream frame)))
                    :view (if spec (getf spec :view) (ds-view srv))
                    :rows (if spec (getf spec :rows (ds-rows srv)) (ds-rows srv))
                    :budget (if spec (getf spec :budget (ds-budget srv)) (ds-budget srv))
                    :attach (or (and spec (getf spec :attach)) #'attach-dom)
                    :app app
                    :invoker invoker :hz (ds-hz srv)
                    :name (format nil "ws:~a~@[/~a~]" (ds-port srv) app)
                    :log (lambda (m) (format *error-output* "~&[warp-dom] ~a~%" m))))))

(defun run-consumer (srv stream &optional (invoker (ds-invoker srv)))
  "One browser, one consumer PER APP.  The socket is the SEND and nothing more: the encoding hands
the channel a string and this lambda puts it on the wire.

The lock is this function's and not the channel's, because it guards THE SOCKET — two threads
interleaving WebSocket frames on one stream is a framing bug, and only the thing that owns the
stream knows that.  With two apps on one socket there are two ticking threads writing to it, which
is the same bug arriving from a second direction and is answered by the same lock.  Everything else
about running consumers on a link is MUX-RECEIVE's and MUX-CLOSE's, which is the same code the
gateway runs."
  (let* ((lock (bt:make-lock "warp-dom-write"))
         (mux (make-mux (lambda (app) (%app-channel srv stream lock invoker app)))))
    (unwind-protect
         ;; the read loop: recognized gestures and viewport reports, coming back by KEY.  The pass
         ;; loop is each channel's own thread, at HZ.
         (loop
           (multiple-value-bind (text opcode) (ws-read-message stream)
             (when (or (null text) (eql opcode 8)) (return))
             (when (eql opcode 1)
               (let ((ch (mux-receive mux text)))
                 (when ch
                   (let ((c (channel-consumer ch)))
                     (pushnew c (ds-consumers srv))))))))
      (dolist (cell (mux-channels mux))
        (setf (ds-consumers srv) (remove (channel-consumer (cdr cell)) (ds-consumers srv))))
      (mux-close mux)
      (ws-send-close stream))))
