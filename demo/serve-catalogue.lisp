;;;; demo/serve-catalogue.lisp — the widget catalogue, live, in a browser.
;;;;
;;;;   sbcl --load demo/serve-catalogue.lisp [port]
;;;;
;;;; Every widget warp has, in every variant, rendered by the same client that paints every
;;;; other app -- so this page is evidence rather than illustration.  A widget that renders
;;;; wrong here renders wrong in warp-files.

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream)))
    (asdf:load-system :warp-catalogue/dom)
    (asdf:load-system :warp-dom/serve)))

(defpackage #:warp-catalogue-demo (:use #:cl)) (in-package #:warp-catalogue-demo)

(defvar *proj* (warp-catalogue:catalogue-projection))
(defvar *port* (or (ignore-errors (parse-integer (second sb-ext:*posix-argv*))) 8790))
(defvar *srv* (warp-dom::serve-dom *proj* :port *port*
                                          :attach #'warp-catalogue-dom:attach-dom
                                          :view 'warp-catalogue:catalogue-view
                                          :rows 120 :budget 200000
                                          :invoker :allowlist :hz 4))
(format t "~&warp :: catalogue on http://127.0.0.1:~a/~%" *port*)
(finish-output)
(loop (sleep 5)
      (format t "~&[catalogue] consumers ~a~%" (length (warp-dom::ds-consumers *srv*)))
      (finish-output))
