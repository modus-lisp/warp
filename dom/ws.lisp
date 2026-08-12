;;;; dom/ws.lisp — just enough WebSocket to prove the encoding is alive, and no more.
;;;;
;;;; THE TRANSPORT IS NOT THE POINT.  warp already has a transport that was tuned end to end under
;;;; cellular pressure — the WebRTC data channel the phone is holding right now — and the honest
;;;; place for a DOM consumer is a second channel beside `control` on that same peer connection.
;;;; See the note in serve.lisp for exactly what that swap is.  This file exists so the encoding can
;;;; be driven by a real browser today without touching a live gateway.
;;;;
;;;; It is a server-side subset: the opening handshake (which needs SHA-1 and base64, both written
;;;; out here rather than pulled in, because warp-dom/serve depending on ironclad to prove a JSON
;;;; delta arrived would be an odd way to spend a dependency), unfragmented text and close frames,
;;;; and client-to-server unmasking.  No extensions, no permessage-deflate, no fragmentation, no
;;;; ping/pong.  A browser talking to localhost needs none of them.

(in-package #:warp-dom)

;;; ---- SHA-1 (RFC 3174) --------------------------------------------------------

(defmacro %u32 (x) `(ldb (byte 32 0) ,x))
(defun %rotl (x n) (%u32 (logior (ash x n) (ash x (- n 32)))))

(defun sha1 (octets)
  "The 20-byte digest of OCTETS.  Here for one reason: Sec-WebSocket-Accept."
  (let* ((len (length octets))
         (bitlen (* 8 len))
         (padded (make-array (* 64 (ceiling (+ len 9) 64))
                             :element-type '(unsigned-byte 8) :initial-element 0))
         (h (make-array 5 :element-type '(unsigned-byte 32)
                          :initial-contents '(#x67452301 #xEFCDAB89 #x98BADCFE
                                              #x10325476 #xC3D2E1F0)))
         (w (make-array 80 :element-type '(unsigned-byte 32))))
    (replace padded octets)
    (setf (aref padded len) #x80)
    (loop for i below 8
          do (setf (aref padded (- (length padded) 1 i)) (ldb (byte 8 (* 8 i)) bitlen)))
    (loop for base from 0 below (length padded) by 64 do
      (loop for i below 16
            do (setf (aref w i)
                     (logior (ash (aref padded (+ base (* 4 i))) 24)
                             (ash (aref padded (+ base (* 4 i) 1)) 16)
                             (ash (aref padded (+ base (* 4 i) 2)) 8)
                             (aref padded (+ base (* 4 i) 3)))))
      (loop for i from 16 below 80
            do (setf (aref w i) (%rotl (logxor (aref w (- i 3)) (aref w (- i 8))
                                               (aref w (- i 14)) (aref w (- i 16)))
                                       1)))
      (let ((a (aref h 0)) (b (aref h 1)) (c (aref h 2)) (d (aref h 3)) (e (aref h 4)))
        (loop for i below 80
              do (multiple-value-bind (f k)
                     (cond ((< i 20) (values (logior (logand b c) (logand (lognot b) d)) #x5A827999))
                           ((< i 40) (values (logxor b c d) #x6ED9EBA1))
                           ((< i 60) (values (logior (logand b c) (logand b d) (logand c d))
                                             #x8F1BBCDC))
                           (t (values (logxor b c d) #xCA62C1D6)))
                   (let ((tmp (%u32 (+ (%rotl a 5) (%u32 f) e k (aref w i)))))
                     (setf e d d c c (%rotl b 30) b a a tmp))))
        (setf (aref h 0) (%u32 (+ (aref h 0) a)) (aref h 1) (%u32 (+ (aref h 1) b))
              (aref h 2) (%u32 (+ (aref h 2) c)) (aref h 3) (%u32 (+ (aref h 3) d))
              (aref h 4) (%u32 (+ (aref h 4) e)))))
    (let ((out (make-array 20 :element-type '(unsigned-byte 8))))
      (loop for i below 5
            do (loop for j below 4
                     do (setf (aref out (+ (* 4 i) j)) (ldb (byte 8 (* 8 (- 3 j))) (aref h i)))))
      out)))

;;; ---- base64 ------------------------------------------------------------------

(defparameter +b64+ "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

(defun base64 (octets)
  (with-output-to-string (s)
    (loop for i from 0 below (length octets) by 3
          do (let* ((n (min 3 (- (length octets) i)))
                    (b (logior (ash (aref octets i) 16)
                               (if (> n 1) (ash (aref octets (+ i 1)) 8) 0)
                               (if (> n 2) (aref octets (+ i 2)) 0))))
               (write-char (char +b64+ (ldb (byte 6 18) b)) s)
               (write-char (char +b64+ (ldb (byte 6 12) b)) s)
               (write-char (if (> n 1) (char +b64+ (ldb (byte 6 6) b)) #\=) s)
               (write-char (if (> n 2) (char +b64+ (ldb (byte 6 0) b)) #\=) s)))))

;;; ---- HTTP, only as far as the upgrade ----------------------------------------

(defun read-http-request (stream)
  "Request line plus headers.  Returns (values method path headers-alist) with lowercased header
names, or NIL if the peer went away."
  (let ((line (read-crlf-line stream)))
    (when (and line (plusp (length line)))
      (let* ((sp1 (position #\Space line))
             (sp2 (and sp1 (position #\Space line :start (1+ sp1))))
             (method (and sp1 (subseq line 0 sp1)))
             (path (and sp2 (subseq line (1+ sp1) sp2)))
             (headers '()))
        (loop for h = (read-crlf-line stream)
              while (and h (plusp (length h)))
              do (let ((colon (position #\: h)))
                   (when colon
                     (push (cons (string-downcase (string-trim " " (subseq h 0 colon)))
                                 (string-trim " " (subseq h (1+ colon))))
                           headers))))
        (values method path headers)))))

(defun read-crlf-line (stream)
  (let ((out (make-string-output-stream)))
    (loop for b = (handler-case (read-byte stream nil nil) (error () nil))
          do (cond ((null b) (let ((s (get-output-stream-string out)))
                               (return (and (plusp (length s)) s))))
                   ((= b 13))                              ; CR: skip
                   ((= b 10) (return (get-output-stream-string out)))
                   (t (write-char (code-char b) out))))))

(defun write-string-bytes (stream string)
  (write-sequence (sb-ext:string-to-octets string :external-format :utf-8) stream))

(defun http-respond (stream status content-type body)
  (write-string-bytes
   stream
   (format nil "HTTP/1.1 ~a~c~aContent-Type: ~a~c~aContent-Length: ~a~c~aConnection: close~c~a~c~a"
           status #\Return #\Newline content-type #\Return #\Newline
           (length (sb-ext:string-to-octets body :external-format :utf-8))
           #\Return #\Newline #\Return #\Newline #\Return #\Newline))
  (write-string-bytes stream body)
  (finish-output stream))

(defparameter +ws-guid+ "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")

(defun ws-accept (stream headers)
  "Complete the opening handshake.  Returns T if this really was a WebSocket upgrade."
  (let ((key (cdr (assoc "sec-websocket-key" headers :test #'string=))))
    (when key
      (let ((accept (base64 (sha1 (sb-ext:string-to-octets (concatenate 'string key +ws-guid+)
                                                           :external-format :latin-1)))))
        (write-string-bytes
         stream
         (format nil "HTTP/1.1 101 Switching Protocols~c~aUpgrade: websocket~c~a~
Connection: Upgrade~c~aSec-WebSocket-Accept: ~a~c~a~c~a"
                 #\Return #\Newline #\Return #\Newline #\Return #\Newline
                 accept #\Return #\Newline #\Return #\Newline))
        (finish-output stream)
        t))))

;;; ---- frames ------------------------------------------------------------------

(defun ws-send-text (stream string)
  "One unfragmented text frame, unmasked (server to client)."
  (let* ((payload (sb-ext:string-to-octets string :external-format :utf-8))
         (n (length payload)))
    (write-byte #x81 stream)                                ; FIN + opcode 1
    (cond ((< n 126) (write-byte n stream))
          ((< n 65536) (write-byte 126 stream)
                       (write-byte (ldb (byte 8 8) n) stream)
                       (write-byte (ldb (byte 8 0) n) stream))
          (t (write-byte 127 stream)
             (loop for i from 7 downto 0 do (write-byte (ldb (byte 8 (* 8 i)) n) stream))))
    (write-sequence payload stream)
    (finish-output stream)))

(defun ws-send-close (stream)
  (handler-case (progn (write-byte #x88 stream) (write-byte 0 stream) (finish-output stream))
    (error () nil)))

(defun ws-read-message (stream)
  "One client frame.  Returns (values string opcode) or NIL at end of stream.  Client frames are
always masked; an unmasked one is a protocol violation and we simply drop the connection rather
than tolerating it, because a lenient parser here is a parser someone later feeds."
  (let ((b0 (read-byte stream nil nil)))
    (when b0
      (let* ((opcode (logand b0 #x0f))
             (b1 (read-byte stream nil nil)))
        (when b1
          (let ((masked (logtest b1 #x80))
                (len (logand b1 #x7f)))
            (cond ((= len 126) (setf len (logior (ash (read-byte stream) 8) (read-byte stream))))
                  ((= len 127) (setf len 0)
                               (dotimes (i 8) (setf len (logior (ash len 8) (read-byte stream))))))
            (unless masked (return-from ws-read-message nil))
            (let ((mask (make-array 4 :element-type '(unsigned-byte 8)))
                  (payload (make-array len :element-type '(unsigned-byte 8))))
              (read-sequence mask stream)
              (read-sequence payload stream)
              (dotimes (i len)
                (setf (aref payload i) (logxor (aref payload i) (aref mask (mod i 4)))))
              (values (if (= opcode 8) "" (sb-ext:octets-to-string payload :external-format :utf-8))
                      opcode))))))))
