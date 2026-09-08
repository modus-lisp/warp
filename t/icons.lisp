;;;; t/icons.lisp — the icon set, and the one way it can quietly rot.
;;;;
;;;; The path data lives twice: src/icons.lisp for Lisp encodings, and a mirrored table in
;;;; dom/client.js for the browser.  That is deliberate — a client draws what it has a renderer
;;;; for, so an icon it has never heard of is one it could not draw even if it were sent the path
;;;; — but two copies of anything drift, and this one drifts SILENTLY: a missing icon falls back
;;;; to text and looks like a design choice.
;;;;
;;;; So the test is the agreement, not the drawing.
;;;;
;;;; Run:  sbcl --non-interactive --load t/icons.lisp

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream))) (asdf:load-system :warp)))

(defpackage #:warp-icon-test (:use #:cl #:warp)) (in-package #:warp-icon-test)
(defvar *fails* 0)
(defun ok (n p &optional d)
  (format t "~&  ~:[FAIL~;ok  ~] ~a~@[   ~a~]~%" p n d) (unless p (incf *fails*)))

(format t "~&~%== icons ==~%")

(defparameter *client*
  (let ((path (merge-pathnames "dom/client.js"
                               (asdf:system-source-directory :warp))))
    (with-open-file (s path) (let ((b (make-string (file-length s))))
                               (subseq b 0 (read-sequence b s))))))

(format t "~&     icons declared: ~a~%" (length (icon-names)))

(ok "every icon has path data" (every (lambda (n) (plusp (length (icon-path (icon n))))) (icon-names)))
(ok "every icon has a text fallback, so a consumer with no geometry keeps the glyph"
    (every (lambda (n) (plusp (length (icon-fallback (icon n))))) (icon-names)))
(ok "every icon declares fill or stroke — an outlined play triangle is an arrow"
    (every (lambda (n) (member (icon-mode (icon n)) '(:fill :stroke))) (icon-names)))

;;; THE DRIFT CHECK: the browser's table must carry the same names AND the same paths.
(let ((missing '()) (wrong '()))
  (dolist (n (icon-names))
    (let ((nm (string-downcase (symbol-name n))))
      ;; JS quotes a hyphenated key and leaves a bare one unquoted, so both spellings count.
      (if (not (or (search (format nil "~a:" nm) *client*)
                   (search (format nil "\"~a\":" nm) *client*)))
          (push nm missing)
          (unless (search (icon-path (icon n)) *client*) (push nm wrong)))))
  (ok "the browser's mirrored table names every icon" (null missing) missing)
  (ok "and carries the same path data for each" (null wrong) wrong))

;;; A glyph is still allowed to be a plain string: warp-media's ASCII must keep working.
(ok "an unknown keyword resolves to NIL, so an encoding falls back to text"
    (null (icon :no-such-icon)))
(ok "a string is not an icon name" (null (icon "play")))

(format t "~&~%== ~[all checks passed~:;~:*~d FAILED~] ==~%~%" *fails*)
(sb-ext:exit :code (if (zerop *fails*) 0 1))
