;;;; app/serve-monitor.lisp — the monitor, on glass, over RFB.
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream)))
    (asdf:load-system :warp-monitor/glass)))
(defpackage #:warp-monitor-glass (:use #:cl))
(in-package #:warp-monitor-glass)

;; PAINT and the surface entry point live in glass-app.lisp so the standalone server and the
;; desktop app cannot drift apart.
(defvar *sf*
  (warp-glass:run :port (or (ignore-errors (parse-integer (second sb-ext:*posix-argv*))) 5910)
                  :width 480 :height 448 :name "warp :: glass monitor"
                  :view 'warp-monitor::monitor-view
                  ;; the projection is the QUERY; this seat lays it out to its own 480x448 window
                  :rows-fn #'warp-monitor:monitor-rows
                  :type-fn #'warp-monitor:row-type
                  :hz 4))
(format t "~&warp monitor serving on RFB ~a~%" (warp-glass::sf-port *sf*))
(finish-output)
;; report the protocol's own numbers periodically — the monitor measuring itself
(loop
  (sleep 10)
  (format t "~&[warp] passes ~a  deltas ~a  painted ~a  rows ~a~%"
          (warp-glass:sf-passes *sf*) (warp-glass:sf-emitted *sf*)
          (warp-glass:sf-painted *sf*) (length (warp-glass:sf-visible *sf*)))
  (finish-output))
