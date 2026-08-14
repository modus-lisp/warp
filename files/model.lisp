;;;; files/model.lisp — the domain, projected off warren's fs.lisp.
;;;;
;;;; warren's `fs.lisp` is 198 lines with no drawing in it at all: LIST-DIR returns ENTRY structs,
;;;; ENTRY-SIZE stats a file, HUMAN-SIZE and FILE-KIND format, IMAGE-FILE-P and
;;;; DECODE-PREVIEW-THUMB decode.  That is a model, and this file projects it.  warren's OTHER 640
;;;; lines — icons, layout, painting, hit-testing, the pump loop — are the pixel facet of the same
;;;; app (DESIGN.md rule 9) and are not touched, not read at run time, and not replaced.
;;;;
;;;; -------------------------------------------------------------------------------------------
;;;; WHAT IS SHARED AND WHAT IS THE LOOKER'S — the rule 8 question this client had to answer, and
;;;; the answer is not the one the rule's examples suggest.
;;;;
;;;; The COLUMN STACK — which directories are open — is on the BROWSER, which is shared, because it
;;;; is an ARGUMENT TO THE QUERY.  Rule 8 says view is the consumer's and a second view is no longer
;;;; a second projection; but a second column stack IS a second projection, because the rows come
;;;; back different.  Selection, scroll and which column has focus are the consumer's; where you
;;;; have NAVIGATED TO is not, any more than the device manager's file is.
;;;;
;;;; That has a consequence worth stating rather than discovering: the tap default on a directory is
;;;; `open`, and `open` MUTATES SHARED STATE.  Two consumers over one browser drill in together.
;;;; This is not a wart — it is the same shape as client one, where `revoke` writes the enrolment
;;;; file every consumer is reading — and it is what "reads are projections, writes are commands"
;;;; means when the write happens to be a navigation.  Two people who want to browse independently
;;;; want two browsers, exactly as two people who want different hold-menus want two windows.
;;;;
;;;; The PREVIEW is the other way round, and the split is exactly on the same line.  WHETHER there
;;;; is a preview depends on this consumer's SELECTION, so the node is built in LAY-OUT.  WHAT the
;;;; decoded pixels are is a property of the FILE, so the decode is cached on the browser and shared:
;;;; a decode is not a property of the one looking, and paying for it twice would be the mixer bug
;;;; in a slower coat.

(in-package #:warp-files)

;;; ---------------------------------------------------------------------------------------------
;;; REACHING INTO WARREN — every instance, in one block, deliberately
;;; ---------------------------------------------------------------------------------------------
;;; warren's package exports exactly four symbols: RUN, RENDER-TO-PNG, DESKTOP-SURFACE and
;;; *SHOW-HIDDEN*.  Its whole filesystem model is internal.  So this client cannot be written
;;; without WARREN::, and the honest thing is to do it ONCE, here, where it can be counted, rather
;;; than sprinkling double colons through four files where nobody would ever notice how deep the
;;; reach had got.  If warren ever exports its model, this block is the only thing that changes.
;;;
;;; Nothing below writes to warren, rebinds a warren special, or calls anything in its view, icon or
;;; app layers.  It is eleven readers and one decoder.

(declaim (inline entry-name entry-path entry-dir-p))
(defun entry-name  (e) (warren::entry-name e))
(defun entry-path  (e) (warren::entry-path e))
(defun entry-dir-p (e) (warren::entry-dir-p e))
(defun entry-size  (e) (warren::entry-size e))
(defun list-dir    (p) (warren::list-dir p))
(defun dir-display-name (p) (warren::%dir-display-name p))
(defun human-size  (n) (warren::human-size n))
(defun file-kind   (e) (warren::file-kind e))
(defun image-file-p (e) (warren::image-file-p e))
(defun decode-thumb (path w h) (warren::decode-preview-thumb path w h))
(defun pv-p   (x) (typep x 'warren::pv))
(defun pv-img (x) (warren::pv-img x))
(defun pv-ow  (x) (warren::pv-ow x))
(defun pv-oh  (x) (warren::pv-oh x))
(defconstant +preview-w+ 192)
(defconstant +preview-h+ 144)

;;; ---------------------------------------------------------------------------------------------
;;; The shared navigation state
;;; ---------------------------------------------------------------------------------------------
;;; CLOS rather than DEFSTRUCT, per the house preference: this is long-lived state that may well be
;;; redefined under a running image, and a class migrates its live instances where a struct strands
;;; them.

(defclass browser ()
  ((root  :initarg :root  :reader browser-root)
   (stack :initarg :stack :accessor browser-stack
          :documentation "Open directories, left to right.  The QUERY'S ARGUMENT, which is why it
lives on the shared half — see this file's header.")
   (previews :initform (make-hash-table :test 'equal) :reader browser-previews
             :documentation "(path . write-date) -> OPAQUE or :none.  A decode is a property of the
FILE, so it is shared; whether anyone is looking at it is the consumer's.")
   (preview-misses :initform 0 :accessor preview-misses
                   :documentation "Decodes actually performed.  The number that proves the cache is
shared rather than per consumer.")
   (lock :initform (bt:make-lock "warp-files-browser") :reader browser-lock))
  (:documentation "Where the browser has navigated to, and what it has already decoded."))

;;; ---- where it opens ---------------------------------------------------------------------------
;;;
;;; A DEFAULT, AND DELIBERATELY NOT A CONFINEMENT.  Nothing below stops a caller browsing anywhere
;;; the process can read, and pretending otherwise would be theatre: the desktop this ships beside
;;; puts a terminal in its root menu, so a credential that reaches the file browser already reaches
;;; a shell, and a root-confined browser next to an unconfined shell protects nobody while looking
;;; as though it does.  (The one thing that IS enforced is *WRITABLE-ROOT*, below, because deleting
;;; is a different question from looking.)
;;;
;;; So the only question this answers is where it is useful to OPEN, and the answer is the one
;;; warren already gives: `/` is a list of system directories nobody wants, and HOME is where a
;;; person's files are.  warren's own APP defaults to (USER-HOMEDIR-PATHNAME); the pixel facet and
;;; the data facet of one app opening in the same place is rule 9 being true in a small way rather
;;; than an argued one.  WARP_FILES_ROOT overrides it, because the box that serves this may want a
;;; particular tree and editing Lisp to say so is not a deployment step anybody should need.

(defun default-root ()
  "Where a browser opens when nobody says: $WARP_FILES_ROOT if it names a readable directory, and
HOME otherwise.  An unusable value falls back rather than signalling — this is a default, and a
gateway that refused to serve the file browser because an environment variable had a typo in it
would be answering the wrong question."
  (let ((env (uiop:getenv "WARP_FILES_ROOT")))
    (or (and env (plusp (length env))
             (ignore-errors (truename (uiop:ensure-directory-pathname env))))
        (user-homedir-pathname))))

(defun make-browser (&optional (root (default-root)))
  (let ((r (truename root)))
    (make-instance 'browser :root r :stack (list r))))

(defun browser-depth (b) (length (browser-stack b)))

(defun browse-open (b column-index dir)
  "Drill in: keep the columns up to and including COLUMN-INDEX, then open DIR to their right.
Everything that was further right is discarded, which is what a Miller column browser means by
navigating — and it is why this emits :gone for whole columns rather than :changed."
  (bt:with-lock-held ((browser-lock b))
    (let ((keep (subseq (browser-stack b) 0 (min (1+ column-index) (length (browser-stack b))))))
      (setf (browser-stack b) (append keep (list dir)))))
  dir)

(defun browse-close (b column-index)
  "Close COLUMN-INDEX and everything right of it.  Column 0 is the root and does not close."
  (when (plusp column-index)
    (bt:with-lock-held ((browser-lock b))
      (setf (browser-stack b) (subseq (browser-stack b) 0 column-index))))
  (browser-stack b))

;;; ---------------------------------------------------------------------------------------------
;;; The domain objects the query returns
;;; ---------------------------------------------------------------------------------------------
;;; A COLUMN is one directory's listing.  A ROW is one line in one column — and it exists as an
;;; object for a reason that is the sharpest thing this client found out about rule 1.
;;;
;;; PRESENTATION-KEY's signature is (TYPE OBJECT).  There is no parent in it.  Rule 1 says
;;; "reconcile matches on (parent, key)" and "keys are scoped to the parent", but a key function
;;; CANNOT SEE THE PARENT, so the only way to scope a key is for the object to carry its own parent.
;;; That is what FS-ROW is: an entry, plus the column it is in.  Scoping happens in the key
;;; function, where rule 1 says identity is declared — not in the reconciler, which has no idea any
;;; of this is nested.  See columns.lisp for what that costs.

(defclass fs-column ()
  ((path       :initarg :path       :reader column-path)
   (index      :initarg :index      :reader column-index)
   (entries    :initarg :entries    :reader column-entries)
   (readable-p :initarg :readable-p :reader column-readable-p)
   (browser    :initarg :browser    :reader column-browser))
  (:documentation "One directory's listing, rebuilt from disk on every read."))

(defclass fs-row ()
  ((column :initarg :column :reader row-column)
   (index  :initarg :index  :reader row-index
           :documentation "Position within the column.  0 is the header; entries are 1..n.")
   (entry  :initarg :entry  :initform nil :reader row-entry
           :documentation "warren's ENTRY struct, or NIL for the header row."))
  (:documentation "One line of one column: an entry AND the column it belongs to.  The pairing is
the whole point — see the commentary above."))

(defun row-name (r)
  (let ((e (row-entry r)))
    (if e (entry-name e) (dir-display-name (column-path (row-column r))))))

;;; ---- rule 9's opaque node ---------------------------------------------------------------------
;;; A node inside a data tree that offers only pixels.  The tree around it stays structured; only
;;; this node is a hole.  The CAPTION is what makes the hole legible to a consumer that cannot blit,
;;; and it is supplied by the app rather than derived from the pixels — rule 9 refuses to guess,
;;; because a plausible caption for the wrong thing is worse than an honest absence.
;;;
;;; The important detail is which slot the pixels are in.  PRESENT returns the caption and the
;;; dimensions and NOTHING ELSE, so the pixels are not in the fingerprint and therefore never on any
;;; wire.  An encoding that can blit reaches them through P-OBJECT; an encoding that cannot never
;;; sees them and is not charged for them.  That is the facet bundle written as two slots.

(defclass opaque ()
  ((caption :initarg :caption :reader opaque-caption
            :documentation "What this region IS, in words the app chose.")
   (w       :initarg :w       :reader opaque-w)
   (h       :initarg :h       :reader opaque-h)
   (pixels  :initarg :pixels  :initform nil :reader opaque-pixels
            :documentation "A decoded PIGMENT:IMG, or NIL.  Never in the fingerprint.")
   (source  :initarg :source  :reader opaque-source)
   (column  :initarg :column  :reader opaque-column
            :documentation "The column path this node hangs under — its parent, for the key."))
  (:documentation "A region that offers pixels and a caption, and from which nothing else can be
derived (DESIGN.md rule 9)."))

(defun preview-for (b entry column-path)
  "The OPAQUE node for ENTRY, decoded at most once per (path, write-date) and shared by every
consumer looking at it.  Returns NIL for a file that is not an image."
  (let* ((path (entry-path entry))
         (ck (cons path (or (ignore-errors (file-write-date path)) 0)))
         (hit (gethash ck (browser-previews b))))
    (cond
      ((eq hit :none) nil)
      (hit (make-instance 'opaque :caption (opaque-caption hit) :w (opaque-w hit)
                                  :h (opaque-h hit) :pixels (opaque-pixels hit)
                                  :source path :column column-path))
      ((not (image-file-p entry)) (setf (gethash ck (browser-previews b)) :none) nil)
      (t
       (incf (preview-misses b))
       (let* ((r (decode-thumb path +preview-w+ +preview-h+))
              (node (if (pv-p r)
                        (make-instance 'opaque
                                       :caption (format nil "~a — ~a, ~a x ~a"
                                                        (entry-name entry) (file-kind entry)
                                                        (pv-ow r) (pv-oh r))
                                       :w (pigment:img-w (pv-img r))
                                       :h (pigment:img-h (pv-img r))
                                       :pixels (pv-img r)
                                       :source path :column column-path)
                        ;; a preview that could not be decoded is STILL an opaque node with a
                        ;; caption: the honest statement is "an image we could not show", not
                        ;; silence.  Rule 9's asymmetry cuts both ways.
                        (make-instance 'opaque
                                       :caption (format nil "~a — ~a, no preview (~(~a~))"
                                                        (entry-name entry) (file-kind entry) r)
                                       :w 0 :h 0 :pixels nil
                                       :source path :column column-path))))
         (setf (gethash ck (browser-previews b)) node)
         node)))))

;;; ---------------------------------------------------------------------------------------------
;;; Rule 1: identity is a declared key function, and here it is PARENT-SCOPED BY CONSTRUCTION
;;; ---------------------------------------------------------------------------------------------
;;; The key is the PATHNAME, and it is scoped by consing it onto its column's pathname.
;;;
;;; EQ provably fails, and more thoroughly than it did for client one.  LIST-DIR calls
;;; UIOP:SUBDIRECTORIES and UIOP:DIRECTORY-FILES and MAKE-ENTRY on every result, every time — so the
;;; ENTRY structs are freshly consed on every single read and no two reads share one.  With EQ as
;;; the key, every row of every column would be :gone + :appeared on every pass forever, and the
;;; code would look completely correct.  The pathname survives because a pathname is a value.
;;;
;;; (SBCL happens to intern pathnames, so two reads of one directory yield EQ pathnames as well as
;;; EQUAL ones.  Nothing here relies on that — the delivered table is an EQUAL table and the keys
;;; are conses, which are never EQ across reads regardless.)

(define-presentation-key fs-head (r) (cons (column-path (row-column r)) :head))
(define-presentation-key fs-dir  (r) (cons (column-path (row-column r)) (entry-path (row-entry r))))
(define-presentation-key fs-file (r) (cons (column-path (row-column r)) (entry-path (row-entry r))))
(define-presentation-key fs-preview (o) (cons (opaque-column o) :preview))

(defun row-type (o)
  "What a row IS — a property of the result-set, not of any seat (rule 8)."
  (etypecase o
    (opaque 'fs-preview)
    (fs-row (let ((e (row-entry o)))
              (cond ((null e) 'fs-head)
                    ((entry-dir-p e) 'fs-dir)
                    (t 'fs-file))))))

;;; ---------------------------------------------------------------------------------------------
;;; PRESENT: designed rows, and a caption for the hole
;;; ---------------------------------------------------------------------------------------------
;;; The cells are the FINGERPRINT, so what is in them is exactly what a change is measured against.
;;; A file's size is in there deliberately: it means writing to a file changes that one row and
;;; nothing else, which is the delta-scoping claim made testable.

(defmethod present ((r fs-row) (type (eql 'fs-head)) (view (eql 'files-view)))
  (let ((col (row-column r)))
    (list (dir-display-name (column-path col))
          (if (column-readable-p col)
              (format nil "~d item~:p" (length (column-entries col)))
              "unreadable")
          :head)))

(defmethod present ((r fs-row) (type (eql 'fs-dir)) (view (eql 'files-view)))
  (list (entry-name (row-entry r)) "" :dir))

(defmethod present ((r fs-row) (type (eql 'fs-file)) (view (eql 'files-view)))
  (list (entry-name (row-entry r)) (human-size (entry-size (row-entry r))) :file))

(defmethod present ((o opaque) (type (eql 'fs-preview)) (view (eql 'files-view)))
  "The caption, the size, and a tag saying THIS IS A HOLE.  No pixels: they are on the object, and
a consumer that can blit fetches them from there.  This is rule 9's whole claim in three cells —
what travels is what every consumer can use, and the blit is a local privilege."
  (list (opaque-caption o)
        (if (plusp (opaque-w o)) (format nil "~d x ~d" (opaque-w o) (opaque-h o)) "—")
        :opaque))

;;; ---------------------------------------------------------------------------------------------
;;; Rule 6: commands against the entry TYPE, safe defaults, destruction behind hold + confirm
;;; ---------------------------------------------------------------------------------------------

(defparameter *writable-root* #p"/tmp/"
  "The app's own containment: TRASH-ENTRY refuses a path outside this tree.  Deliberately NOT the
authorization check — that is WARP:INVOKE's and is tested separately.  This is the ordinary
belt-and-braces an app owes a delete command, and keeping the two mechanisms distinguishable is the
point: one signals COMMAND-REFUSED, the other signals an ordinary error from inside the handler.")

(defun %under-root-p (path)
  (let ((p (namestring path)) (r (namestring *writable-root*)))
    (and (>= (length p) (length r)) (string= r p :end2 (length r)))))

(define-command (open-dir :arg-type fs-dir :cost :local :label "open") (r invoker)
  (declare (ignore invoker))
  (browse-open (column-browser (row-column r)) (column-index (row-column r))
               (entry-path (row-entry r)))
  (list :opened (entry-path (row-entry r))))

(define-command (peek-file :arg-type fs-file :cost :local :label "peek") (r invoker)
  (declare (ignore invoker))
  ;; Selection is set by WARP:ON-GESTURE before this runs, and the preview is derived from it in
  ;; LAY-OUT — so this command's whole job is to report.  A safe default that DOES nothing is still
  ;; the right default: rule 6 wants the tap to be non-destructive, not to be busy.
  (list :peeked (entry-path (row-entry r))))

(define-command (copy-path :arg-type fs-file :cost :local :label "copy path") (r invoker)
  (declare (ignore invoker))
  (list :path (namestring (entry-path (row-entry r)))))

(define-command (close-column :arg-type fs-head :cost :local :label "close column") (r invoker)
  (declare (ignore invoker))
  (browse-close (column-browser (row-column r)) (column-index (row-column r)))
  (list :closed (column-index (row-column r))))

(define-command (trash-entry :arg-type fs-file :cost :local
                             :destructive t :confirm t :label "delete") (r invoker)
  (declare (ignore invoker))
  (let ((path (entry-path (row-entry r))))
    (unless (%under-root-p path)
      (error "warp-files: ~a is outside ~a — refusing to delete." path *writable-root*))
    (delete-file path)
    (list :deleted path)))

;;; Policy, written once, next to the thing it protects — and enforced by WARP:INVOKE on every
;;; surface.  A guest may look and may open; only an owner may delete.
(define-command-authorization trash-entry (invoker) (eq invoker :owner))

;;; Rule 6: tap is non-destructive on every type that has a default, and DEFINE-DEFAULT-COMMAND
;;; refuses TRASH-ENTRY outright — try it and it signals.  FS-HEAD has no default at all, so a tap
;;; on a column header resolves to :pass and does nothing.
(define-default-command 'fs-dir  'files-view 'open-dir)
(define-default-command 'fs-file 'files-view 'peek-file)

;;; ---------------------------------------------------------------------------------------------
;;; The query
;;; ---------------------------------------------------------------------------------------------
;;; DESIGN.md: views subscribe to RESULT-SETS, not to objects they happen to enumerate.  So this is
;;; "the entries of the open columns", re-run from disk every epoch, and not an enumeration anybody
;;; is holding on to.  It returns a FLAT list in column-major order — header, then entries, per
;;; column — because that is what the reconciler can actually diff.  Why it must be flat, and what
;;; that says about rule 1, is columns.lisp's header.

(defun browse-rows (b)
  "The current result-set: every open column's listing, freshly read."
  (let ((stack (bt:with-lock-held ((browser-lock b)) (copy-list (browser-stack b)))))
    (loop for path in stack
          for ci from 0
          append (multiple-value-bind (entries readable) (list-dir path)
                   (let ((col (make-instance 'fs-column :path path :index ci :entries entries
                                                        :readable-p readable :browser b)))
                     (cons (make-instance 'fs-row :column col :index 0 :entry nil)
                           (loop for e in entries
                                 for i from 1
                                 collect (make-instance 'fs-row :column col :index i
                                                                :entry e))))))))

(defun browse-projection (b)
  "One projection over one browser.  Two consumers on it share the query and the column stack, and
share nothing else — not selection, not scroll, not focus, not budget, not stream."
  (make-projection (lambda () (browse-rows b)) :type-fn #'row-type))
