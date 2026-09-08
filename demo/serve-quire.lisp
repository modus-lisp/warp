;;;; demo/serve-quire.lisp — the compound document, live, in a browser.
;;;;
;;;; Run it and open the URL it prints.  It serves warp-quire over a WebSocket of its own on a
;;;; free local port; the live WebRTC gateway is not touched, loaded or restarted.
;;;;
;;;;   sbcl --load demo/serve-quire.lisp [port]
;;;;
;;;; WHAT TO LOOK AT, since a screenshot of a document looks like a document and the point is
;;;; what is underneath it:
;;;;
;;;;   * the pivot is a REAL TABLE with one column per quarter, drawn by a client that was
;;;;     written for flat lists.  Nothing about the encoding changed; the row is still a row of
;;;;     cells.  What changed is that the client asks the declared TYPE what the cells mean
;;;;     instead of testing the third one.
;;;;   * TAP A ROW to drill in, and the rows below it become different rows -- gone/appeared,
;;;;     scoped to that part's container, while the prose around it does not move.
;;;;   * HOLD THE HEADER for the measure and pivot commands.  A phone has tap, hold and
;;;;     two-finger and nothing else, so a desktop's drag-a-dimension is a menu here.
;;;;   * THE PAGE IS QUIET when nothing is touched.  A document that is half prose emits zero
;;;;     deltas per pass; the counter below stops moving and stays stopped.
;;;;
;;;; The projection ticks on its own only because the cube does not change -- there is nothing
;;;; to animate and that is the point of section 2 in t/quire.lisp.  The loop below prints the
;;;; query count so an idle document can be SEEN to be idle.

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream)))
    (asdf:load-system :warp-quire/dom)
    (asdf:load-system :warp-dom/serve)))

(defpackage #:warp-quire-demo (:use #:cl)) (in-package #:warp-quire-demo)

(defvar *doc* (warp-quire:example-document))
(defvar *proj* (warp-quire:quire-projection *doc*))
(defvar *port* (or (ignore-errors (parse-integer (second sb-ext:*posix-argv*))) 8788))

;;; :ATTACH is how a consumer gets made, and this document needs the one that claims a container
;;; per part.  Without it every row lands in `rows' and the document is flat -- correct, and not
;;; what it is for.  The per-app specs always had this key; the default app did not until now.
(defvar *srv* (warp-dom::serve-dom *proj* :port *port*
                                          :attach #'warp-quire-dom:attach-dom
                                          :view 'warp-quire:quire-view
                                          :rows 60 :budget 100000
                                          :invoker :allowlist :hz 4))

(format t "~&warp :: quire on http://127.0.0.1:~a/~%" *port*)
(finish-output)

(loop
  (sleep 3)
  (format t "~&[quire] consumers ~a  queries ~a~%"
          (length (warp-dom::ds-consumers *srv*)) (warp:projection-queries *proj*))
  (finish-output))
