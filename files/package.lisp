;;;; files/package.lisp — warp's client two.
;;;;
;;;; Three packages, split on the same line everything else in warp is split on: the model and the
;;;; column walk know nothing about pixels or JSON, and each encoding is its own package that adds a
;;;; positional claim and a place to put deltas.

(defpackage #:warp-files
  (:use #:cl #:warp)
  (:export
   ;; the shared navigation state — the column STACK, which is the query's argument
   #:browser #:make-browser #:default-root #:browser-root #:browser-stack #:browser-depth
   #:browse-open #:browse-close #:browse-rows #:browse-projection #:row-type
   #:*writable-root*
   ;; the domain
   #:fs-column #:column-path #:column-index #:column-entries #:column-readable-p #:column-browser
   #:fs-row #:row-column #:row-entry #:row-index #:row-name
   ;; rule 9's opaque node: pixels for whoever can blit them, a caption for everyone else
   #:opaque #:opaque-caption #:opaque-pixels #:opaque-w #:opaque-h #:opaque-source #:opaque-column
   #:preview-for #:preview-misses
   ;; the view, and the presentation types commands are declared against
   #:files-view #:fs-head #:fs-dir #:fs-file #:fs-preview
   ;; the Miller consumer: one walk, and the seam an encoding fills in
   #:miller-consumer #:column-w #:focus-column #:columns-of #:max-column-rows
   #:row-place #:preview-place #:visible-rows #:column-visible-p #:focus-on))

;;; The two encodings' packages are NOT here.  They take local nicknames on WARP-GLASS and WARP-DOM,
;;; and a DEFPACKAGE with a nickname on a package that has not been loaded is a hard error at read
;;; time — so putting all three in one file makes the base system unloadable without both encodings,
;;; which is exactly the coupling this split exists to prevent.  Each encoding declares its own
;;; package at the top of its own file, in its own system.
