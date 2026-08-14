;;;; demo/serve-both.lisp — two apps, one link: the device manager and the file browser at once.
;;;;
;;;; This is the local stand-in for what the gateway does on stream 102, and it is deliberately the
;;;; SAME code: `serve-dom` takes a default projection and an :APPS alist, hands both to
;;;; `warp-dom:make-mux`, and the routing — which app a client message is for, which app a frame
;;;; goes back labelled with — is warp-dom's, not this file's and not the gateway's.  What can be
;;;; driven by a browser here is therefore what runs there, with an SCTP stream in place of a
;;;; WebSocket.
;;;;
;;;; The device manager is the DEFAULT app: no label on its messages, no label on its frames, and
;;;; byte for byte the link it had before the file browser existed.  The file browser is `files`.
;;;;
;;;;   sbcl --load demo/serve-both.lisp [port] [root]
;;;;
;;;; ROOT defaults to $WARP_FILES_ROOT and then to HOME, exactly as the gateway's does.  The live
;;;; WebRTC gateway is not touched, loaded, started or contacted by any of this.

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream)))
    (asdf:load-system :warp-monitor)
    (asdf:load-system :warp-files/dom)
    (asdf:load-system :warp-dom/serve)))

(defpackage #:warp-both-demo (:use #:cl)) (in-package #:warp-both-demo)

;;; ---- app one: the device manager, over a fixture file in /tmp -------------------------------

(setf warp-monitor::*devices-file* "/tmp/warp-both-demo-devices")
(with-open-file (s warp-monitor::*devices-file* :direction :output :if-exists :supersede
                                                :if-does-not-exist :create)
  (format s "aa11bb22cc33 0~%dd33ee44ff55 0~%"))

(defvar *n* 0)
(defvar *order* nil)

(defun rows ()
  "The device manager's QUERY — the same fixture demo/serve-dom.lisp uses, so the panel driving it
sees exactly what it has always seen."
  (let ((stats (loop for i below 16
                     collect (make-instance 'warp-monitor::stat
                                            :name (format nil "stat~2,'0d" i)
                                            :value (if (= i 3)
                                                       (format nil "~d" (* 7 *n*))
                                                       (format nil "~d" i))
                                            :trend (cond ((= i 3) :warn) ((= i 9) :bad) (t :ok))))))
    (append (warp-monitor::read-devices)
            (if *order* (reverse stats) stats))))

(defvar *devices* (warp:make-projection #'rows :type-fn #'warp-monitor:row-type))

;;; ---- app two: the file browser ---------------------------------------------------------------

(defvar *root* (let ((arg (third sb-ext:*posix-argv*)))
                 (if (and arg (plusp (length arg)))
                     (truename (uiop:ensure-directory-pathname arg))
                     (warp-files:default-root))))
(defvar *browser* (warp-files:make-browser *root*))
(defvar *files* (warp-files:browse-projection *browser*))

;;; ---- one server, one socket per browser, two consumers on each ------------------------------

(defvar *port* (or (ignore-errors (parse-integer (second sb-ext:*posix-argv*))) 8788))

(defvar *srv*
  (warp-dom::serve-dom *devices*
                       :port *port* :view 'warp-monitor::monitor-view
                       :rows 14 :budget 100000 :invoker :allowlist :hz 8
                       :apps (list (cons "files"
                                         (list :projection *files*
                                               :view 'warp-files:files-view
                                               :attach #'warp-files-dom:attach-dom
                                               :rows 40 :budget 100000)))))

(format t "~&warp :: dom consumer on http://127.0.0.1:~a/~%" *port*)
(format t "~&warp :: apps — (default) device manager, `files` rooted at ~a~%" *root*)
(finish-output)

;; the device-manager fixture moves, so its delta stream has something to say; the file browser's
;; moves when the filesystem does, which is the honest version of the same thing
(loop
  (sleep 2)
  (incf *n*)
  (when (zerop (mod *n* 5)) (setf *order* (not *order*)))
  (format t "~&[warp-dom] consumers ~a  queries ~a/~a~%"
          (length (warp-dom::ds-consumers *srv*))
          (warp:projection-queries *devices*) (warp:projection-queries *files*))
  (finish-output))
