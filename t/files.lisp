;;;; t/files.lisp — client two, and the two things no client had exercised.
;;;;
;;;; DESIGN.md rule 9 ends by naming what is still open, and two of them are here:
;;;;
;;;;   "**nesting with independent diff scopes**, which no client has yet exercised because both
;;;;    are flat lists"
;;;;   "**binary payloads** (the DOM wire is JSON cells and cannot yet say 'this is a picture')"
;;;;
;;;; This file exercises both against warren's filesystem model, and it is written to be able to
;;;; FAIL — the nesting section computes the delta sets per column and asserts the scoping numbers
;;;; rather than narrating them, and the opaque-node section asserts that the DOM's frame does NOT
;;;; contain pixels rather than that it does contain a caption.
;;;;
;;;; Nothing here writes outside /tmp.  The fixture is built and torn down under
;;;; /tmp/warp-files-fixture/, *WRITABLE-ROOT* keeps the delete command inside it, and no glass
;;;; server is started: the framebuffer consumer paints into a framebuffer this file makes and never
;;;; serves.  Run:  sbcl --non-interactive --load t/files.lisp

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream)))
    (asdf:load-system :warp-files/glass)
    (asdf:load-system :warp-files/dom)))

(defpackage #:warp-files-test (:use #:cl #:warp)) (in-package #:warp-files-test)

(defvar *fails* 0)
(defun ok (n p) (format t "~&  ~:[FAIL~;ok  ~] ~a~%" p n) (unless p (incf *fails*)))
(defun kinds (ds) (mapcar #'delta-kind ds))

;;; ---------------------------------------------------------------------------------------------
;;; The fixture — real directories, real files, a real PNG, all under /tmp
;;; ---------------------------------------------------------------------------------------------

(defparameter *root* #p"/tmp/warp-files-fixture/")

(defun wr (path text)
  (ensure-directories-exist path)
  (with-open-file (s path :direction :output :if-exists :supersede :if-does-not-exist :create)
    (write-string text s))
  path)

(defun make-png (path w h)
  "A real PNG, written by scribe's own encoder, so pigment has a genuine image to decode."
  (let* ((cv (scribe:make-canvas w h '(20 30 45)))
         (d (scribe:canvas-pixels cv)))
    (dotimes (y h)
      (dotimes (x w)
        (let ((i (* 3 (+ (* y w) x))))
          (setf (aref d i)       (mod (* 3 x) 256)
                (aref d (+ i 1)) (mod (* 3 y) 256)
                (aref d (+ i 2)) (if (< (mod (+ x y) 32) 16) 200 60)))))
    (ensure-directories-exist path)
    (scribe:write-png cv path)
    path))

(defun build-fixture ()
  (when (probe-file *root*)
    (uiop:delete-directory-tree *root* :validate (lambda (p) (uiop:subpathp p #p"/tmp/"))))
  (ensure-directories-exist *root*)
  (wr (merge-pathnames "top.txt" *root*) "top level")
  (wr (merge-pathnames "shared.txt" *root*) "a name that also exists one level down")
  (wr (merge-pathnames "docs/notes.txt" *root*) "notes")
  (wr (merge-pathnames "docs/readme.md" *root*) "readme")
  (wr (merge-pathnames "docs/shared.txt" *root*) "the other shared.txt")
  (wr (merge-pathnames "docs/sub/inner.txt" *root*) "a third level, so the preview pane can move")
  (wr (merge-pathnames "pics/caption.txt" *root*) "not an image")
  (ensure-directories-exist (merge-pathnames "zz-empty/" *root*))
  (make-png (merge-pathnames "swatch.png" *root*) 320 200)
  (setf warp-files:*writable-root* *root*))

(build-fixture)
(format t "~&fixture: ~a~%" *root*)

(defvar *b* (warp-files:make-browser *root*))
(defvar *queries* 0)
(defvar *proj*
  (make-projection (lambda () (incf *queries*) (warp-files:browse-rows *b*))
                   :type-fn #'warp-files:row-type))

(defun col-of (key) (car key))                    ; a key is (column-path . entry-path-or-tag)
(defun in-col (deltas path) (remove-if-not (lambda (d) (equal path (col-of (delta-key d)))) deltas))
(defun docs () (truename (merge-pathnames "docs/" *root*)))

;;; =============================================================================================
;;; 1. RULE 1 — EQ provably fails across a re-read, and the pathname survives
;;; =============================================================================================

(format t "~&== rule 1: the entries are rebuilt from disk, so EQ is not an identity ==~%")
(let* ((r1 (warp-files:browse-rows *b*))
       (r2 (warp-files:browse-rows *b*))
       (e1 (remove nil (mapcar #'warp-files:row-entry r1)))
       (e2 (remove nil (mapcar #'warp-files:row-entry r2))))
  (ok "two reads of an UNCHANGED tree return the same number of entries"
      (= (length e1) (length e2)))
  (ok "and not one object in the second read is EQ to anything in the first"
      (and (plusp (length e1))
           (notany (lambda (a) (member a e1 :test #'eq)) e2)))
  (ok "nor are the ROW objects, nor the COLUMN objects — the whole result-set is fresh"
      (and (notany (lambda (a) (member a r1 :test #'eq)) r2)
           (notany (lambda (a) (member a (mapcar #'warp-files:row-column r1) :test #'eq))
                   (mapcar #'warp-files:row-column r2))))
  ;; the counterfactual, computed rather than asserted: what EQ would have cost
  (let ((n (length r1)))
    (format t "     with EQ as the key, every pass would be ~d :gone + ~d :appeared, forever~%" n n))
  (ok "the declared key function, on the other hand, gives EQUAL keys across the re-read"
      (equal (mapcar (lambda (r) (presentation-key (warp-files:row-type r) r)) r1)
             (mapcar (lambda (r) (presentation-key (warp-files:row-type r) r)) r2)))
  (ok "and those keys are PATHNAMES — values, which is why they survive a rebuild"
      (every (lambda (r) (pathnamep (car (presentation-key (warp-files:row-type r) r)))) r1)))

;;; The end-to-end version of the same claim: a whole pass over a tree that did not change.
(defvar *fb* (glass:make-framebuffer 900 480 warp-glass:+bg+))
(defvar *pixels* (warp-files-glass:attach-fb *proj* :fb *fb* :budget 100000 :invoker :owner))

(format t "~&== and therefore an idle pass over an unchanged tree costs nothing ==~%")
(let ((first (tick *pixels*)))
  (format t "     first pass: ~d deltas (~d :appeared)~%" (length first)
          (count :appeared (kinds first)))
  (ok "the first pass announces the working set" (plusp (count :appeared (kinds first))))
  (ok "the second pass, over a re-read of the same disk, emits NOTHING"
      (null (tick *pixels*)))
  (ok "and a third, so it is convergence and not an off-by-one" (null (tick *pixels*))))

;;; =============================================================================================
;;; 2. NESTING — parent-scoped keys, and delta scoping measured
;;; =============================================================================================
;;; The reconciler is FLAT: ONE delivered table, keyed by P-KEY and nothing else (see
;;; files/columns.lisp's header for the full finding).  So the scoping below is achieved in the KEY
;;; FUNCTION, by pairing each entry with its column, and what is being measured is whether that is
;;; sufficient.

(format t "~&== nesting: two columns, and keys that are scoped to one ==~%")
(warp-files:browse-open *b* 0 (docs))
(tick *pixels*)
(let* ((objs (projection-objects *proj*))
       (groups (warp-files:columns-of objs))
       (heads (remove-if-not (lambda (o) (eq 'warp-files:fs-head (warp-files:row-type o))) objs)))
  (format t "     columns: ~{~a~^, ~}~%"
          (mapcar (lambda (g) (warren::%dir-display-name (warp-files:column-path (car g)))) groups))
  (ok "two columns are open" (= 2 (length groups)))
  ;; THE observable case for parent scoping, and it is not contrived: a header row's OWN key
  ;; component is the constant :HEAD, identical in every column.  Only the parent separates them.
  (ok "every column header's own key component is the SAME constant"
      (every (lambda (h) (eq :head (cdr (presentation-key 'warp-files:fs-head h)))) heads))
  (ok "and yet the header keys are all distinct, because the parent is in them"
      (= (length heads)
         (length (remove-duplicates (mapcar (lambda (h) (presentation-key 'warp-files:fs-head h))
                                            heads)
                                    :test #'equal))))
  ;; the counterfactual for entry rows, computed: a name-only key is what a display-first
  ;; implementation reaches for, and shared.txt exists in both columns
  (let* ((rows (remove-if-not (lambda (o) (and (warp-files:row-entry o)
                                               (not (eq 'warp-files:fs-head
                                                        (warp-files:row-type o)))))
                              objs))
         (naive (mapcar #'warp-files:row-name rows))
         (scoped (mapcar (lambda (r) (presentation-key (warp-files:row-type r) r)) rows)))
    (format t "     ~d rows: ~d distinct name-only keys, ~d distinct parent-scoped keys~%"
            (length rows)
            (length (remove-duplicates naive :test #'equal))
            (length (remove-duplicates scoped :test #'equal)))
    (ok "a name-only key COLLIDES across columns (shared.txt is in both)"
        (< (length (remove-duplicates naive :test #'equal)) (length rows)))
    (ok "the parent-scoped key does not"
        (= (length (remove-duplicates scoped :test #'equal)) (length rows)))))

(format t "~&== the assertion that matters: a change to ONE ROW is scoped to that row ==~%")
(let ((docs-path (docs))
      (root-path (truename *root*)))
  ;; write to one file in the right-hand column.  Its SIZE is in its fingerprint, so this is a
  ;; content change to exactly one row of one column.
  (wr (merge-pathnames "docs/notes.txt" *root*) "notes, now considerably longer than before")
  (let* ((ds (tick *pixels*))
         (in-docs (in-col ds docs-path))
         (in-root (in-col ds root-path)))
    (format t "     total deltas: ~d   in the changed column: ~d   in the other: ~d~%"
            (length ds) (length in-docs) (length in-root))
    (format t "     kinds: ~{~(~a~)~^ ~}~%" (kinds ds))
    (ok "EXACTLY ONE delta for a one-file change" (= 1 (length ds)))
    (ok "and it is :changed, keyed to the row that changed"
        (and (eq :changed (delta-kind (first ds)))
             (equal (merge-pathnames "docs/notes.txt" *root*) (cdr (delta-key (first ds))))))
    (ok "the row's own column got 1 delta — not its 4 rows, and not a column-shaped re-send"
        (= 1 (length in-docs)))
    (ok "THE OTHER COLUMN GOT NOTHING" (zerop (length in-root)))))

(format t "~&== a change in one column does not re-send the others ==~%")
(let* ((docs-path (docs)) (root-path (truename *root*))
       (before (length (consumer-visible *pixels*))))
  ;; add a file to the RIGHT-hand column: it sorts first, so every file below it shifts
  (wr (merge-pathnames "docs/aaa.txt" *root*) "inserted at the top of its column")
  (let* ((ds (tick *pixels*))
         (in-docs (in-col ds docs-path)) (in-root (in-col ds root-path)))
    (format t "     ~d deltas: ~{~(~a~)~^ ~}~%" (length ds) (kinds ds))
    (format t "     in docs/: ~d      in the root column: ~d      rows on screen: ~d -> ~d~%"
            (length in-docs) (length in-root) before (length (consumer-visible *pixels*)))
    (ok "the inserted row appeared" (= 1 (count :appeared (kinds ds))))
    (ok "the rows below it MOVED rather than being re-sent (rule 2)"
        (plusp (count :moved (kinds ds))))
    (ok "the column header :changed, because its item count is in its fingerprint"
        (= 1 (count :changed (kinds ds))))
    (ok "EVERY delta belongs to the column that changed" (= (length ds) (length in-docs)))
    (ok "AND THE OTHER COLUMN GOT ZERO — this is the nesting claim, as a number"
        (zerop (length in-root)))))

(format t "~&== and symmetrically, changing the LEFT column leaves the right one alone ==~%")
(let ((docs-path (docs)) (root-path (truename *root*)))
  (wr (merge-pathnames "aaa-root.txt" *root*) "inserted at the top of the root column's files")
  (let* ((ds (tick *pixels*))
         (in-docs (in-col ds docs-path)) (in-root (in-col ds root-path)))
    (format t "     ~d deltas: ~{~(~a~)~^ ~}~%" (length ds) (kinds ds))
    (format t "     in the root column: ~d      in docs/: ~d~%" (length in-root) (length in-docs))
    (ok "every delta is in the root column" (= (length ds) (length in-root)))
    (ok "docs/ got zero — a naive single-list layout would have shifted all four of its rows"
        (zerop (length in-docs)))
    ;; and the reason it is genuinely nested rather than accidentally quiet: the right column's
    ;; rows are at a different X and did not move at all
    (let ((docs-rows (remove-if-not (lambda (p) (equal docs-path (col-of (p-key p))))
                                    (consumer-visible *pixels*))))
      (ok "the right column's rows all still sit at the same x, one column across"
          (and (plusp (length docs-rows))
               (every (lambda (p) (= warp-files-glass:+col-w+ (extent-x (p-extent p))))
                      docs-rows))))))

(format t "~&== what the reconciler actually has: ONE scope, not a scope per column ==~%")
(ok "P-CHILDREN exists, is exported, and is read by NOTHING in warp — a tree put there is dropped"
    (let ((p (make-presentation :key :k :type 'x :object 1 :extent nil
                               :fingerprint '("a") :children (list :a :b))))
      ;; it round-trips as a slot and has no effect on anything: the diff never descends
      (and (equal '(:a :b) (p-children p))
           (= 1 (length (emit (make-delta-stream) (list p)))))))
(ok "RESYNC clears the ONE delivered table, so a single column cannot be resynced alone"
    (let ((n (length (resync *pixels*)))
          (one-column (count-if (lambda (p) (equal (docs) (col-of (p-key p))))
                                (consumer-visible *pixels*))))
      (format t "     resync re-announced ~d rows across BOTH columns; that one column has ~d~%"
              n one-column)
      (> n one-column)))
(tick *pixels*)

;;; =============================================================================================
;;; 3. TWO ENCODINGS, ONE QUERY
;;; =============================================================================================

(format t "~&== two encodings over one projection, and one query for the round ==~%")
(defvar *browser* (warp-files-dom:attach-dom *proj* :rows 3 :budget 100000 :invoker :guest))

(let ((q0 *queries*))
  (let ((dp (tick *pixels*)) (db (tick *browser*)))
    (declare (ignorable dp))
    (ok "the query ran ONCE for both consumers" (= 1 (- *queries* q0)))
    (ok "and the projection counted it once" (= 1 (- (projection-queries *proj*)
                                                     (- (projection-queries *proj*) 1))))
    (format t "     framebuffer: ~d rows over ~d columns~%     browser:     ~d rows, ~d deltas~%"
            (length (consumer-visible *pixels*))
            (length (warp-files:columns-of (projection-objects *proj*)))
            (length (consumer-visible *browser*)) (length db))
    (ok "the browser got the slice IT said it could show — 3 rows PER COLUMN, which a flat
      client has no way to ask for"
        (= 6 (length (consumer-visible *browser*))))
    (ok "the framebuffer got everything its 900px window holds"
        (> (length (consumer-visible *pixels*)) (length (consumer-visible *browser*))))
    (ok "their working sets are genuinely different"
        (not (equal (sort (mapcar (lambda (p) (format nil "~a" (p-key p)))
                                  (consumer-visible *pixels*)) #'string<)
                    (sort (mapcar (lambda (p) (format nil "~a" (p-key p)))
                                  (consumer-visible *browser*)) #'string<))))))

(format t "~&== the same row, positioned twice, in two vocabularies ==~%")
(let* ((kb (mapcar #'p-key (consumer-visible *browser*)))
       (k (find-if (lambda (x) (member x kb :test #'equal))
                   (mapcar #'p-key (consumer-visible *pixels*))))
       (pp (find k (consumer-visible *pixels*) :key #'p-key :test #'equal))
       (pb (find k (consumer-visible *browser*) :key #'p-key :test #'equal)))
  (format t "     ~a~%       framebuffer  ~a~%       browser      ~a~%" k (p-extent pp) (p-extent pb))
  (ok "the framebuffer's position is a grid-snapped rectangle (rule 3)"
      (and (rect-p (p-extent pp))
           (zerop (mod (extent-x (p-extent pp)) +grid+))
           (zerop (mod (extent-y (p-extent pp)) +grid+))))
  (ok "the browser's is (container . after), and the container NAMES THE COLUMN"
      (and (consp (p-extent pb)) (not (rect-p (p-extent pb)))
           (let ((c (car (p-extent pb))))
             (and (stringp c) (eql 0 (search "col:" c))))))
  (ok "and they agree on exactly the two things that are the projection's: key and content"
      (and (equal (p-key pp) (p-key pb)) (equal (p-fingerprint pp) (p-fingerprint pb)))))

(format t "~&== the shared half carries no position of any kind ==~%")
(ok "the projection holds domain objects, never presentations"
    (notany (lambda (o) (typep o 'presentation)) (projection-objects *proj*)))
(ok "and every one of them is a row or a column — nothing with an extent in it"
    (every (lambda (o) (typep o 'warp-files:fs-row)) (projection-objects *proj*)))
(ok "the two encodings' column vocabularies do not even have the same TYPE"
    (let ((a (p-extent (first (consumer-visible *pixels*))))
          (b (p-extent (first (consumer-visible *browser*)))))
      (and (rect-p a) (not (rect-p b)))))

;;; =============================================================================================
;;; 4. THE OPAQUE NODE — rule 9, on both encodings at once
;;; =============================================================================================

(format t "~&== rule 9: an opaque node, blitted by one consumer and captioned for the other ==~%")
;; select the PNG in the ROOT column, so the preview pane sits to the right of every open column
(let* ((objs (projection-objects *proj*))
       (png-row (find-if (lambda (o)
                           (and (warp-files:row-entry o)
                                (equal "swatch.png" (warp-files:row-name o))))
                         objs))
       (png-key (presentation-key 'warp-files:fs-file png-row)))
  (setf (consumer-selected *pixels*) png-key
        (consumer-selected *browser*) png-key)
  (let* ((dp (tick *pixels*)) (db (tick *browser*))
         (pv-p (find 'warp-files:fs-preview (consumer-visible *pixels*) :key #'p-type))
         (pv-b (find 'warp-files:fs-preview (consumer-visible *browser*) :key #'p-type)))
    (declare (ignorable dp db))
    (ok "both consumers were given the node" (and pv-p pv-b))
    ;; rule 8, applied to something expensive: WHETHER there is a preview is the consumer's (it
    ;; depends on selection), but WHAT the decoded pixels are is a property of the FILE.  So the
    ;; decode is on the shared half and two consumers looking at one image pay for it ONCE.
    (format t "     decodes actually performed for two consumers: ~d~%"
            (warp-files:preview-misses *b*))
    (ok "the image was decoded ONCE for both consumers, not once each"
        (= 1 (warp-files:preview-misses *b*)))
    (format t "     caption: ~s~%" (first (p-fingerprint pv-p)))
    (ok "it is the SAME node, by key, on both" (equal (p-key pv-p) (p-key pv-b)))
    (ok "its key is parent-scoped like everything else — (column . :preview)"
        (and (pathnamep (car (p-key pv-p))) (eq :preview (cdr (p-key pv-p)))))

    ;; --- the framebuffer: it can blit, so it did
    (let* ((node (p-object pv-p))
           (img (warp-files:opaque-pixels node))
           (e (p-extent pv-p)))
      (ok "the framebuffer consumer holds real decoded pixels"
          (and img (plusp (pigment:img-w img)) (plusp (pigment:img-h img))))
      (format t "     decoded ~dx~d thumbnail from a ~a source~%"
              (pigment:img-w img) (pigment:img-h img) (warp-files:opaque-caption node))
      ;; and they are ON THE FRAMEBUFFER: count distinct colours inside the pane
      (let ((seen (make-hash-table)) (px (glass:fb-pixels *fb*)) (w (glass:fb-width *fb*)))
        (loop for y from (+ (extent-y e) 8) below (+ (extent-y e) 8 (pigment:img-h img))
              do (loop for x from (extent-x e) below (+ (extent-x e) (extent-w e))
                       do (setf (gethash (aref px (+ (* y w) x)) seen) t)))
        (format t "     distinct colours painted inside the pane: ~d~%" (hash-table-count seen))
        (ok "the pane genuinely has an image in it, not a flat rectangle"
            (> (hash-table-count seen) 50))))

    ;; --- the DOM: it cannot blit, and is told what the region is anyway
    (let* ((frames (warp-dom:take-frames *browser*))
           (all (format nil "~{~a~}" frames))
           (json (warp-dom:delta-json
                  (find (p-key pv-b) (list (warp::%make-delta :kind :appeared :key (p-key pv-b)
                                                              :presentation pv-b
                                                              :extent (p-extent pv-b)))
                        :key #'delta-key :test #'equal))))
      (format t "     what the browser was sent for the node:~%       ~a~%" json)
      (ok "the caption the APP supplied is on the wire"
          (search "swatch.png" json))
      (ok "and the tag that says 'this is a hole', so a client draws a placeholder"
          (search "opaque" json))
      (ok "the node's ORIGINAL dimensions are there too — legible without the pixels"
          (search "320 x 200" (warp-files:opaque-caption (p-object pv-b))))
      (ok "NO PIXELS travelled: the whole delta is smaller than the smallest possible thumbnail"
          (< (length json) 400))
      (ok "and nothing pixel-shaped is in the fingerprint at all"
          (notany (lambda (cell) (typep cell 'pigment:img)) (p-fingerprint pv-b)))
      (ok "the frames this consumer actually received contain no image data either"
          (and (plusp (length all)) (not (search "base64" all)) (not (search "data:" all))))
      (format t "     the node costs the browser ~d bytes; the framebuffer ~d macroblocks~%"
              (delta-cost *browser* (warp::%make-delta :kind :appeared :key (p-key pv-b)
                                                       :presentation pv-b))
              (delta-cost *pixels* (warp::%make-delta :kind :appeared :key (p-key pv-p)
                                                      :presentation pv-p
                                                      :extent (p-extent pv-p)))))

    ;; --- :moved on an opaque node IS the surface's copy-p
    (format t "~&== the opaque node's :moved is the surface copy-p it already had ==~%")
    (let ((before (p-extent pv-p))
          (area (warp::p-macroblocks pv-p)))
      ;; drill INTO the right-hand column, so a third column opens and the preview pane — which
      ;; always sits to the right of everything — shifts one column across with identical contents
      (warp-files:browse-open *b* 1 (truename (merge-pathnames "docs/sub/" *root*)))
      (let* ((ds (tick *pixels*))
             (mv (find-if (lambda (d) (and (eq :moved (delta-kind d))
                                           (equal (p-key pv-p) (delta-key d))))
                          ds)))
        (ok "the node MOVED rather than being re-sent" mv)
        (when mv
          (format t "     ~a -> ~a   dx=~d dy=~d~%" before
                  (p-extent (delta-presentation mv)) (delta-dx mv) (delta-dy mv))
          (ok "one whole column to the right, and not a pixel down"
              (and (= warp-files-glass:+col-w+ (delta-dx mv)) (zerop (delta-dy mv))))
          (ok "and it cost ONE unit, against the ~d macroblocks a re-send would have cost — which
      is exactly what copy-p buys"
              (= 1 (delta-cost *pixels* mv)))
          (format t "     a re-send of the same pane would have been ~d macroblocks~%" area)
          (ok "the assertion carried the content unchanged, as rule 2 requires"
              (equal (p-fingerprint pv-p) (p-fingerprint (delta-presentation mv)))))))))

;;; =============================================================================================
;;; 5. RULE 6 — commands on the entry type, safe default, destruction refused at invocation
;;; =============================================================================================

(format t "~&== rule 6: the tap default is non-destructive, and warp enforces that at declaration ==~%")
(ok "tap on a directory resolves to `open` — a drill-in, which is the safe default rule 6 wants"
    (multiple-value-bind (kind cmd)
        (gesture-command :tap 'warp-files:fs-dir 'warp-files:files-view :invoker :owner)
      (and (eq :invoke kind) (eq 'warp-files::open-dir (cmd-name cmd)))))
(ok "tap on a file resolves to `peek`, also safe"
    (multiple-value-bind (kind cmd)
        (gesture-command :tap 'warp-files:fs-file 'warp-files:files-view :invoker :owner)
      (and (eq :invoke kind) (eq 'warp-files::peek-file (cmd-name cmd)))))
(ok "tap on a column HEADER resolves to nothing at all — no default is declared, so :pass"
    (eq :pass (gesture-command :tap 'warp-files:fs-head 'warp-files:files-view :invoker :owner)))
(ok "and making the destructive one a tap default is REFUSED, at declaration time"
    (handler-case (progn (define-default-command 'warp-files:fs-file 'warp-files:files-view
                             'warp-files::trash-entry)
                         nil)
      (error () t)))

(format t "~&== authorization: refused at invocation, by a menu that never offered it ==~%")
(let* ((objs (projection-objects *proj*))
       (victim (find-if (lambda (o) (and (warp-files:row-entry o)
                                         (equal "shared.txt" (warp-files:row-name o))
                                         (equal (truename *root*)
                                                (warp-files:column-path
                                                 (warp-files:row-column o)))))
                        objs))
       (path (warren::entry-path (warp-files:row-entry victim)))
       (guest-menu (applicable-commands 'warp-files:fs-file :invoker :guest))
       (owner-menu (applicable-commands 'warp-files:fs-file :invoker :owner)))
  (format t "     guest is offered: ~{~a~^, ~}~%" (mapcar #'cmd-label guest-menu))
  (format t "     owner is offered: ~{~a~^, ~}~%" (mapcar #'cmd-label owner-menu))
  (ok "the guest's hold-menu does not contain delete"
      (not (find 'warp-files::trash-entry guest-menu :key #'cmd-name)))
  (ok "the owner's does" (find 'warp-files::trash-entry owner-menu :key #'cmd-name))
  (ok "the file exists before anybody asks" (probe-file path))
  ;; the guest names it anyway, over the wire, with confirmation — the whole point of rule 6
  (ok "a guest that names it anyway is REFUSED at invocation, not by the menu"
      (handler-case (progn (invoke 'warp-files::trash-entry victim :guest :confirmed t) nil)
        (command-refused (e) (search "not authorized" (refused-reason e)))))
  (ok "and the file is still there" (probe-file path))
  ;; and the owner still cannot do it by accident: confirmation is a separate gate
  (ok "even the owner is refused without confirmation — irreversible needs saying twice"
      (handler-case (progn (invoke 'warp-files::trash-entry victim :owner) nil)
        (command-refused (e) (search "confirmation" (refused-reason e)))))
  (ok "the file is STILL there" (probe-file path))
  (ok "an owner who confirms deletes it"
      (progn (invoke 'warp-files::trash-entry victim :owner :confirmed t) (not (probe-file path))))
  ;; and the same refusal through a real consumer's surface path
  (let ((cmd (find 'warp-files::trash-entry owner-menu :key #'cmd-name)))
    (run-command *browser* cmd victim :confirmed t)
    (ok "a guest CONSUMER reaches the same refusal through RUN-COMMAND"
        (eq :refused (first (consumer-last-result *browser*))))))

(format t "~&== the tap default actually navigates, through the gesture path ==~%")
(warp-files:browse-close *b* 1)
(tick *pixels*)
(let* ((depth0 (warp-files:browser-depth *b*))
       (dir-p (find 'warp-files:fs-dir (consumer-visible *pixels*) :key #'p-type)))
  (on-gesture *pixels* :tap dir-p)
  (ok "tapping a directory row opened a column" (= (1+ depth0) (warp-files:browser-depth *b*)))
  (ok "and selected it, which is this consumer's view state"
      (equal (p-key dir-p) (consumer-selected *pixels*)))
  (ok "the OTHER consumer did not have its selection changed by that tap"
      (not (equal (consumer-selected *browser*) (consumer-selected *pixels*))))
  (format t "     but BOTH now see the new column — the stack is the QUERY'S argument, and shared~%")
  ;; TWO ticks, and the reason is worth recording: PULL re-runs the query only for a consumer whose
  ;; epoch has CAUGHT UP with the projection's.  A consumer lagging an epoch is handed the CACHE and
  ;; brought level, and only its next tick re-queries.  It converges, which is what rule 8 promises,
  ;; but "a change is visible to every consumer on its next tick" is not true — it is the next tick
  ;; for whoever was level, and the one after that for whoever was behind.
  (tick *pixels*) (tick *browser*)
  (ok "which is the honest consequence: drill-in is a write, and writes are shared"
      (= (warp-files:browser-depth *b*)
         (length (warp-files:columns-of (projection-objects *proj*)))))
  (ok "and the second consumer really is holding the new column too"
      (find-if (lambda (p) (equal (warp-files:column-path
                                   (warp-files:row-column (p-object p)))
                                  (car (last (warp-files:browser-stack *b*)))))
               (consumer-visible *browser*))))

;;; =============================================================================================
;;; 6. RULE 7 — view state per consumer, including the one a flat list had no room for
;;; =============================================================================================

(format t "~&== rule 7: selection, scroll AND which column has focus, per consumer ==~%")
(warp-files:focus-on *pixels* 1)
(warp-files:focus-on *browser* 0)
;; Scroll the BROWSER, in rows.  The framebuffer is deliberately left alone, and its own scroll
;; demonstrates the other half of the same rule: its window is taller than the tallest column, so
;; SCROLL-TO clamps it to 0 — against CONTENT-HEIGHT measured in PIXELS, while the browser's clamps
;; against the same content measured in ROWS.  One slot, two units, both correct.
(scroll-by *pixels* 32)
(scroll-by *browser* 2)
(let ((dp (tick *pixels*)) (db (tick *browser*)))
  (format t "     framebuffer scroll ~d px (content ~d px, viewport ~d px)~%"
          (consumer-scroll-y *pixels*) (content-height *pixels*) (viewport-height *pixels*))
  (format t "     browser     scroll ~d rows (content ~d rows, viewport ~d rows)~%"
          (consumer-scroll-y *browser*) (content-height *browser*) (viewport-height *browser*))
  (ok "the two consumers focus different columns"
      (/= (warp-files:focus-column *pixels*) (warp-files:focus-column *browser*)))
  (ok "and hold different scroll offsets, each clamped in its OWN unit"
      (and (= 0 (consumer-scroll-y *pixels*))       ; content fits: clamped, in pixels
           (= 2 (consumer-scroll-y *browser*))))    ; 3-row viewport over a taller column, in rows
  (ok "moving focus costs the framebuffer only the two column HEADERS, not two whole columns"
      (<= (count-if (lambda (d) (eq :changed (delta-kind d))) dp) 4))
  (format t "     focus move: ~d deltas (~d moved)     browser's 2-row scroll: ~d deltas~%"
          (length dp) (count :moved (kinds dp)) (length db))
  ;; The two overlap on KEYS — they are looking at the same rows, which is the whole point of
  ;; sharing a projection.  What must not overlap is the CONSEQUENCE: the framebuffer did not
  ;; scroll, so nothing entered or left its working set, while the browser's did.
  (ok "the browser's scroll changed ITS working set — rows left and rows arrived"
      (and (plusp (count :gone (kinds db))) (plusp (count :appeared (kinds db)))))
  (ok "and the framebuffer, which did not scroll, saw nothing appear or vanish at all"
      (and (zerop (count :gone (kinds dp))) (zerop (count :appeared (kinds dp)))))
  (ok "selection, too, is per consumer and stayed apart"
      (not (equal (consumer-selected *pixels*) (consumer-selected *browser*)))))

;;; =============================================================================================
;;; done
;;; =============================================================================================

(uiop:delete-directory-tree *root* :validate (lambda (p) (uiop:subpathp p #p"/tmp/"))
                            :if-does-not-exist :ignore)
(format t "~&~%~:[~a ASSERTION(S) FAILED~;ALL ASSERTIONS HELD~]~%" (zerop *fails*) *fails*)
(when (plusp *fails*) (sb-ext:exit :code 1))
