;;;; dom/json.lisp — the wire format, in about a hundred lines.
;;;;
;;;; WHY JSON, given that the deltas are already a perfectly good semantic wire format:
;;;;
;;;;   * the consumer at the far end is JavaScript, and `JSON.parse` is the one decoder it has
;;;;     without asking anyone's permission.  Any other framing means shipping a decoder to the
;;;;     browser, and a decoder in the client is a second place the protocol can be got wrong.
;;;;   * it is self-describing, so a version skew fails loudly on a missing key rather than
;;;;     silently on a shifted offset — and this stream carries a `revoke` menu.
;;;;   * the budget is BYTES, and the whole point of rule 4 is that the number the budget meters is
;;;;     the number that actually travels.  A framing whose size you cannot read in devtools makes
;;;;     the budget unauditable, which is exactly the property the pixel path spent a session
;;;;     earning.  Bytes of JSON are what the browser receives, so bytes of JSON are what we charge.
;;;;
;;;; What we give up is compactness, and we give it up knowingly: a delta is ~120 bytes where a
;;;; binary framing might be 40.  That is a constant factor on a stream whose whole design is about
;;;; sending asymptotically less, and it is recoverable later without touching a single rule —
;;;; DELTA-COST would return the compact size and nothing else would move.
;;;;
;;;; Written here rather than pulled from quicklisp because warp-dom's dependency list is part of
;;;; the claim: the encoding seam is real only if a second encoding needs nothing but :warp.

(in-package #:warp-dom)

;;; ---- writing ----------------------------------------------------------------

(defun %json-escape (s out)
  (write-char #\" out)
  (loop for ch across s
        do (case ch
             (#\" (write-string "\\\"" out))
             (#\\ (write-string "\\\\" out))
             (#\Newline (write-string "\\n" out))
             (#\Return (write-string "\\r" out))
             (#\Tab (write-string "\\t" out))
             (t (if (< (char-code ch) #x20)
                    (format out "\\u~4,'0x" (char-code ch))
                    (write-char ch out)))))
  (write-char #\" out))

(defun %json-write (v out)
  "V is a string, real, keyword, NIL, T, (:obj (k . v) ...) or a list (an array).

The two lisp values that need a decision are NIL and a keyword.  NIL is `null` — never the empty
array — because in a fingerprint it means 'this cell has no value', and an empty array there would
read to the client as a cell that is present but blank.  A keyword is a lowercase STRING: the
fingerprints carry :ok / :warn / :destructive / :gateway as enum tags, and a client comparing
`cell === 'destructive'` is doing the same thing the painter does when it picks a colour."
  (typecase v
    (null (write-string "null" out))
    ((eql t) (write-string "true" out))
    (string (%json-escape v out))
    (integer (format out "~d" v))
    (real (format out "~f" v))
    (symbol (%json-escape (string-downcase (symbol-name v)) out))
    (cons
     (cond
       ((eq (car v) :obj)
        (write-char #\{ out)
        (loop for (k . val) in (cdr v)
              for first = t then nil
              do (unless first (write-char #\, out))
                 (%json-escape (if (stringp k) k (string-downcase (string k))) out)
                 (write-char #\: out)
                 (%json-write val out))
        (write-char #\} out))
       (t
        (write-char #\[ out)
        (loop for x in v
              for first = t then nil
              do (unless first (write-char #\, out))
                 (%json-write x out))
        (write-char #\] out))))
    (t (%json-escape (princ-to-string v) out))))

(defun to-json (v)
  "Serialize V.  Objects are (:obj (key . value) ...) — an explicit tag, because a plain alist and
an array of pairs are indistinguishable and guessing between them is how wire formats acquire
undebuggable asymmetries."
  (with-output-to-string (s) (%json-write v s)))

;;; ---- reading ----------------------------------------------------------------
;;; Only what a client actually sends: objects, arrays, strings, numbers, true/false/null.  Objects
;;; come back as alists with STRING keys, read with JSON-GET.  Deliberately strict — a client
;;; message that does not parse is a client message that gets dropped, not one that gets guessed at.

(define-condition json-error (error) ((message :initarg :message :reader json-error-message))
  (:report (lambda (c s) (format s "warp-dom: bad JSON — ~a" (json-error-message c)))))

(defun %skip-ws (s i)
  (loop while (and (< i (length s)) (member (char s i) '(#\Space #\Tab #\Newline #\Return)))
        do (incf i))
  i)

(defun %read-value (s i)
  (setf i (%skip-ws s i))
  (when (>= i (length s)) (error 'json-error :message "ran out of input"))
  (let ((ch (char s i)))
    (cond
      ((char= ch #\{) (%read-object s (1+ i)))
      ((char= ch #\[) (%read-array s (1+ i)))
      ((char= ch #\") (%read-string s (1+ i)))
      ((and (<= (+ i 4) (length s)) (string= "true" s :start2 i :end2 (+ i 4)))
       (values t (+ i 4)))
      ((and (<= (+ i 5) (length s)) (string= "false" s :start2 i :end2 (+ i 5)))
       (values :false (+ i 5)))
      ((and (<= (+ i 4) (length s)) (string= "null" s :start2 i :end2 (+ i 4)))
       (values nil (+ i 4)))
      (t (%read-number s i)))))

(defun %read-string (s i)
  (let ((out (make-string-output-stream)))
    (loop
      (when (>= i (length s)) (error 'json-error :message "unterminated string"))
      (let ((ch (char s i)))
        (cond
          ((char= ch #\") (return (values (get-output-stream-string out) (1+ i))))
          ((char= ch #\\)
           (incf i)
           (when (>= i (length s)) (error 'json-error :message "trailing escape"))
           (let ((e (char s i)))
             (case e
               (#\n (write-char #\Newline out)) (#\r (write-char #\Return out))
               (#\t (write-char #\Tab out))     (#\b (write-char #\Backspace out))
               (#\f (write-char #\Page out))
               (#\u (let ((code (parse-integer s :start (1+ i) :end (+ i 5) :radix 16)))
                      (write-char (code-char code) out)
                      (incf i 4)))
               (t (write-char e out)))
             (incf i)))
          (t (write-char ch out) (incf i)))))))

(defun %read-number (s i)
  (let ((start i))
    (loop while (and (< i (length s))
                     (or (digit-char-p (char s i)) (member (char s i) '(#\- #\+ #\. #\e #\E))))
          do (incf i))
    (when (= start i) (error 'json-error :message (format nil "not a value at ~d" i)))
    (let ((text (subseq s start i)))
      (values (if (find-if (lambda (c) (member c '(#\. #\e #\E))) text)
                  (let ((*read-eval* nil) (*read-default-float-format* 'double-float))
                    (read-from-string text))
                  (parse-integer text))
              i))))

(defun %read-array (s i)
  (let ((out '()))
    (setf i (%skip-ws s i))
    (when (and (< i (length s)) (char= (char s i) #\])) (return-from %read-array (values '() (1+ i))))
    (loop
      (multiple-value-bind (v ni) (%read-value s i)
        (push v out) (setf i (%skip-ws s ni)))
      (when (>= i (length s)) (error 'json-error :message "unterminated array"))
      (case (char s i)
        (#\, (incf i))
        (#\] (return (values (nreverse out) (1+ i))))
        (t (error 'json-error :message "expected , or ]"))))))

(defun %read-object (s i)
  (let ((out '()))
    (setf i (%skip-ws s i))
    (when (and (< i (length s)) (char= (char s i) #\}))
      (return-from %read-object (values (list :obj) (1+ i))))
    (loop
      (setf i (%skip-ws s i))
      (unless (and (< i (length s)) (char= (char s i) #\"))
        (error 'json-error :message "expected a key"))
      (multiple-value-bind (k ni) (%read-string s (1+ i))
        (setf i (%skip-ws s ni))
        (unless (and (< i (length s)) (char= (char s i) #\:))
          (error 'json-error :message "expected :"))
        (multiple-value-bind (v ni2) (%read-value s (1+ i))
          (push (cons k v) out)
          (setf i (%skip-ws s ni2))))
      (when (>= i (length s)) (error 'json-error :message "unterminated object"))
      (case (char s i)
        (#\, (incf i))
        (#\} (return (values (cons :obj (nreverse out)) (1+ i))))
        (t (error 'json-error :message "expected , or }"))))))

(defun from-json (string)
  "Parse STRING.  Objects come back as (:obj (\"key\" . value) ...); read them with JSON-GET."
  (multiple-value-bind (v i) (%read-value string 0)
    (declare (ignore i))
    v))

(defun json-get (obj key &optional default)
  (let ((hit (and (consp obj) (eq (car obj) :obj) (assoc key (cdr obj) :test #'string=))))
    (if hit (cdr hit) default)))
