;;;; app/serve-monitor.lisp — the monitor, on glass, over RFB.
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream)))
    (asdf:load-system :warp-monitor) (asdf:load-system :warp-glass)))
(defpackage #:warp-monitor-glass (:use #:cl))
(in-package #:warp-monitor-glass)

;;; A designed row: the VALUE leads (that is what a glance is looking for), the name is secondary,
;;; and a colour bar carries the trend so it reads without being read.
(defmethod warp-glass:paint (fb p view)
  (declare (ignorable view))
  (let* ((e (warp:p-extent p))
         (x (warp::extent-x e)) (y (warp::extent-y e))
         (w (warp::extent-w e)) (h (warp::extent-h e))
         (c (warp:p-fingerprint p))
         (value (princ-to-string (first c)))
         (label (princ-to-string (second c)))
         (trend (third c)))
    (glass:fb-rect fb x y w h warp-glass:+row-bg+)
    (glass:fb-rect fb x y 4 h (warp-glass:trend-colour trend))
    (glass:fb-rect fb x (+ y h -1) w 1 warp-glass:+bg+)          ; hairline separator
    (glass:fb-text fb (+ x 14) (+ y 21) value :size 15 :color warp-glass:+fg+)
    (glass:fb-text fb (+ x 150) (+ y 20) label :size 12 :color warp-glass:+dim+)))

(defvar *sf*
  (warp-glass:run :port (or (ignore-errors (parse-integer (second sb-ext:*posix-argv*))) 5910)
                  :width 480 :height 448 :name "warp :: glass monitor"
                  :view 'warp-monitor::monitor-view
                  :rows-fn (lambda () (warp-monitor:monitor-presentations
                                       :width 480 :viewport-h 448))
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
