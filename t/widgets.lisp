;;;; t/widgets.lisp — the widget set, and whether it actually covers the apps.
;;;;
;;;; The question this answers is "do we have a primitive widget set yet", and it answers it by
;;;; counting rather than by asserting.  Two things are checked:
;;;;
;;;;   1. COVERAGE.  Every presentation type that any shipping app PRESENTS must have a
;;;;      declaration, and every real row of the demo document must RESOLVE against it.  An
;;;;      undeclared type is not an error at runtime -- an encoding falls back to a plain row --
;;;;      which is exactly why it needs a test: the failure is invisible.
;;;;   2. THE SET IS SMALL AND EARNED.  Every core widget must be in use by a shipping client.
;;;;      A base set that grew by anticipation would pass every other check in this file.
;;;;
;;;; Run:  sbcl --non-interactive --load t/widgets.lisp

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream)))
    (asdf:load-system :warp-monitor)
    (asdf:load-system :warp-files/dom)
    (asdf:load-system :warp-media)
    (asdf:load-system :warp-quire/dom)
    (asdf:load-system :warp-catalogue/dom)))

(defpackage #:warp-widget-test (:use #:cl #:warp)) (in-package #:warp-widget-test)

(defvar *fails* 0)
(defun ok (n p &optional d)
  (format t "~&  ~:[FAIL~;ok  ~] ~a~@[   ~a~]~%" p n d)
  (unless p (incf *fails*)))

;;; The core set, named here so adding one is a deliberate act that shows up in a diff.
(defparameter *core*
  '(menu-item row entry opaque heading prose button meter
    table-head table-row table-total chip))

(format t "~&~%== the widget set ==~%")

;;; ---- 1. the core set is small, and every member is in use ---------------------
(format t "~&~%-- what core declares --~%")
(let ((declared (loop for k being the hash-keys of warp::*widgets* collect k)))
  (format t "     core widgets  : ~{~(~a~)~^ ~}~%" (sort (copy-list *core*) #'string<))
  (format t "     total declared: ~a (core + the app types that map onto them)~%"
          (length declared))
  (ok "every core widget is declared" (every #'widget-of *core*))
  (ok "the core set is still small — twelve, not a toolkit"
      (<= (length *core*) 14) (length *core*)))

;;; ---- 2. coverage: every app type resolves against a real row ------------------
;;; The document is the strictest case available in-image: it is the only app whose whole row
;;; set can be built without a socket, a framebuffer or a filesystem.
(format t "~&~%-- every row of the demo document resolves --~%")
(let* ((doc (warp-quire:example-document))
       (rows (warp-quire:document-rows doc))
       (bad '()))
  (dolist (r rows)
    (let* ((ty (class-name (class-of r)))
           (cells (present r ty 'warp-quire:quire-view)))
      (unless (widget-layout ty (length cells))
        (push (list ty (length cells)) bad))))
  (format t "     rows: ~a   distinct types: ~a~%" (length rows)
          (length (remove-duplicates (mapcar (lambda (r) (class-name (class-of r))) rows))))
  (ok "no row is undeclared or the wrong width for its declaration"
      (null bad) bad))

;;; ---- 3. the n-ary widgets resolve from both ends ------------------------------
(format t "~&~%-- the repeat resolves from both ends --~%")
(ok "a five-cell table row is label + three values + total"
    (equal '(:label :value :value :value :total) (widget-layout 'table-row 5)))
(ok "a two-cell one is label + total, the repeat absorbing nothing"
    (equal '(:label :total) (widget-layout 'table-row 2)))
(ok "an opaque node takes an optional detail in the middle"
    (equal '(:caption :dimensions :detail :kind) (widget-layout 'opaque 4)))
(ok "and without it, the tag is still last"
    (equal '(:caption :dimensions :kind) (widget-layout 'opaque 3)))
(ok "a row too narrow for its declaration resolves to NIL, not to a guess"
    (null (widget-layout 'table-row 1)))
(ok "an undeclared type resolves to NIL, so an encoding falls back rather than refusing"
    (null (widget-layout 'no-such-widget-type 3)))

;;; ---- 4. the two control widgets media gave us --------------------------------
(format t "~&~%-- the controls, lifted from warp-media --~%")
(ok "a button is a glyph and what it means" (equal '(:glyph :kind) (widget-layout 'button 2)))
(ok "a meter segment is one state" (equal '(:state) (widget-layout 'meter 1)))
(ok "media's own types map onto them"
    (and (equal (widget-cells 'warp-media::media-control) (widget-cells 'button))
         (equal (widget-cells 'warp-media::media-seek) (widget-cells 'meter))))

;;; ---- 5. two apps agreed about ENTRY without sharing code ----------------------
(format t "~&~%-- the widget that was invented twice --~%")
(ok "warp-files and warp-media declare the same three cells"
    (equal (widget-cells 'warp-files::fs-file) (widget-cells 'warp-media::media-track)))
(ok "and that shape is core's ENTRY"
    (equal (widget-cells 'warp-files::fs-file) (widget-cells 'entry)))
(ok "which is NOT core's ROW — same arity, opposite emphasis"
    (not (equal (widget-cells 'entry) (widget-cells 'row))))

;;; ---- 6. the browser's mirrored table names every declared type ----------------
;;;
;;; WHY THIS IS A TEST AND NOT A HABIT.  client.js carries a copy of the registry, because the
;;; browser has to know a layout to paint one.  Two copies drift, and this pair drifts SILENTLY:
;;; a type missing from the JS table has no layout, so every named-cell lookup returns null, the
;;; painter for its kind never fires, and the row falls through to the generic three-cell shape.
;;; It renders.  It just renders as something else.
;;;
;;; FS-PREVIEW and MEDIA-PICTURE were exactly that for as long as the widget layer existed: both
;;; declared here, neither in the table, so rule 9's opaque node -- the one node whose whole point
;;; is to say "there are pixels here this surface cannot show" -- drew as an ordinary row.
(format t "~&~%-- the browser's table mirrors the registry --~%")
(let* ((path (merge-pathnames "dom/client.js" (asdf:system-source-directory :warp)))
       (js (with-open-file (s path)
             (let ((b (make-string (file-length s)))) (subseq b 0 (read-sequence b s)))))
       (missing '()) (wrong '()))
  (flet ((js-cells (nm)
           ;; The names quoted on that key's own line, in order.  The table puts one type per
           ;; line, which is what makes this readable rather than a JS parser.
           (let ((at (search (format nil "\"~a\":" nm) js)))
             (when at
               (let* ((eol (or (position #\Newline js :start at) (length js)))
                      (line (subseq js at eol)) (out '()) (i 0))
                 (loop (let ((a (position #\" line :start i)))
                         (unless a (return))
                         (let ((b (position #\" line :start (1+ a))))
                           (unless b (return))
                           (push (subseq line (1+ a) b) out)
                           (setf i (1+ b)))))
                 (rest (nreverse out)))))))            ; drop the key itself
    (loop for ty being the hash-keys of warp::*widgets*
          for nm = (string-downcase (symbol-name ty))
          for want = (mapcar (lambda (c) (string-downcase (symbol-name (if (consp c) (second c) c))))
                             (widget-cells ty))
          for got = (js-cells nm)
          do (cond ((null got) (push nm missing))
                   ((not (equal want got)) (push (list nm want got) wrong)))))
  (format t "     types declared in Lisp: ~a~%" (hash-table-count warp::*widgets*))
  (ok "every declared type is in the browser's table" (null missing) missing)
  (ok "and with the same cells, in the same order" (null wrong) wrong))

(format t "~&~%== ~[all checks passed~:;~:*~d FAILED~] ==~%~%" *fails*)
(sb-ext:exit :code (if (zerop *fails*) 0 1))
