;;;; demo/serve-dom.lisp — the DOM consumer, live, in a browser, on a free local port.
;;;;
;;;; Run it and open the URL it prints.  It serves a projection over a WebSocket of its own; the
;;;; live WebRTC gateway is not touched, loaded or restarted, and serve.lisp's header says exactly
;;;; what the three-line swap onto the real data channel would be.
;;;;
;;;; The fixture ticks: one row's value changes every couple of seconds, one row lapses and returns,
;;;; and rows re-sort — so a watcher sees :changed, :gone/:appeared and :moved arriving separately
;;;; rather than as a re-render.
;;;;
;;;;   sbcl --load demo/serve-dom.lisp [port]

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream)))
    (asdf:load-system :warp-monitor)
    (asdf:load-system :warp-dom/serve)))

(defpackage #:warp-dom-demo (:use #:cl)) (in-package #:warp-dom-demo)
(setf warp-monitor::*devices-file* "/tmp/warp-dom-demo-devices")
(with-open-file (s warp-monitor::*devices-file* :direction :output :if-exists :supersede
                                                :if-does-not-exist :create)
  (format s "aa11bb22cc33 0~%dd33ee44ff55 0~%"))

(defvar *n* 0)
(defvar *order* nil)

(defun rows ()
  "The QUERY.  Domain objects, no layout, no viewport, no idea a browser exists."
  (let ((stats (loop for i below 16
                     collect (make-instance 'warp-monitor::stat
                                            :name (format nil "stat~2,'0d" i)
                                            :value (if (= i 3)
                                                       (format nil "~d" (* 7 *n*))
                                                       (format nil "~d" i))
                                            :trend (cond ((= i 3) :warn) ((= i 9) :bad) (t :ok))))))
    (append (warp-monitor::read-devices)
            (if *order* (reverse stats) stats))))

(defvar *proj* (warp:make-projection #'rows :type-fn #'warp-monitor:row-type))
(defvar *port* (or (ignore-errors (parse-integer (second sb-ext:*posix-argv*))) 8787))

(defvar *srv* (warp-dom::serve-dom *proj* :port *port* :view 'warp-monitor::monitor-view
                                          :rows 14 :budget 100000 :invoker :allowlist :hz 8))

(format t "~&warp :: dom consumer on http://127.0.0.1:~a/~%" *port*)
(finish-output)

;; the fixture moves, so the delta stream has something to say
(loop
  (sleep 2)
  (incf *n*)
  (when (zerop (mod *n* 5)) (setf *order* (not *order*)))
  (format t "~&[warp-dom] consumers ~a  queries ~a~%"
          (length (warp-dom::ds-consumers *srv*)) (warp:projection-queries *proj*))
  (finish-output))
