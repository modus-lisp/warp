;;;; app/run-monitor.lisp — drive the monitor against LIVE data and report what it costs.
;;;;
;;;; The point of a practical client is to find out whether the protocol's economics survive real,
;;;; fast-changing data.  So this polls the real files, reconciles, and reports what actually
;;;; travelled versus what a naive full repaint would have cost.

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream))) (asdf:load-system :warp-monitor)))
(in-package #:warp-monitor)

(defun mb-of (extent)
  (if extent (* (ceiling (warp::extent-w extent) warp:+grid+)
                (ceiling (warp::extent-h extent) warp:+grid+))
      0))

(defun run (&key (seconds 20) (hz 4) (budget 400))
  (let* ((s (warp:make-delta-stream))
         (passes 0) (sent 0) (deferred-seen 0) (mb-sent 0) (mb-naive 0)
         (kinds (make-hash-table)))
    (loop repeat (* seconds hz) do
      (let ((ps (monitor-presentations)))
        (incf passes)
        (incf mb-naive (reduce #'+ (mapcar (lambda (p) (mb-of (warp:p-extent p))) ps)))
        (multiple-value-bind (deltas def) (warp:emit s ps :budget budget)
          (incf deferred-seen def)
          (dolist (d deltas)
            (incf sent)
            (incf (gethash (warp:delta-kind d) kinds 0))
            (incf mb-sent (if (eq (warp:delta-kind d) :moved) 1 (mb-of (warp:delta-extent d)))))))
      (sleep (/ 1.0 hz)))
    (format t "~&== monitor over ~a s at ~a Hz (budget ~a MB/pass) ==~%" seconds hz budget)
    (format t "rows now:            ~a~%" (length (monitor-rows)))
    (format t "passes:              ~a~%" passes)
    (format t "deltas emitted:      ~a  (~,1f per second)~%" sent (/ sent (float seconds)))
    (maphash (lambda (k v) (format t "  ~(~a~): ~a~%" k v)) kinds)
    (format t "deferred (cumulative): ~a~%" deferred-seen)
    (format t "macroblocks sent:    ~a~%" mb-sent)
    (format t "if fully repainted:  ~a~%" mb-naive)
    (format t "saving:              ~,1f x  (~,2f%% of naive)~%"
            (if (plusp mb-sent) (/ mb-naive (float mb-sent)) 0)
            (if (plusp mb-naive) (* 100 (/ mb-sent (float mb-naive))) 0))
    ;; what the rows currently say
    (format t "~%== current rows ==~%")
    (dolist (o (monitor-rows))
      (let ((c (warp:present o (row-type o) 'monitor-view)))
        (format t "  ~8a  ~22a ~(~a~)~%" (first c) (second c) (third c))))))

(run :seconds (or (ignore-errors (parse-integer (second sb-ext:*posix-argv*))) 20))
