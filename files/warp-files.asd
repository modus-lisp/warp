;;;; warp-files — warp's client two: a Miller-column projection of warren's filesystem model.
;;;;
;;;; warren is a WORKING pixel app (gesso onto a glass framebuffer, its own layout, its own hit
;;;; testing).  This is NOT a port of it and does not touch it: warren's `fs.lisp` is 198 lines of
;;;; model with no drawing in it at all, and that model is what this projects.  Both can run at
;;;; once over the same directories, which is the point — an app's DATA facet and its PIXEL facet
;;;; are different facets of one thing (DESIGN.md rule 9), not two versions of it.
;;;;
;;;; Client two exists to test the two things client one could not, because client one and the
;;;; monitor are both FLAT LISTS WITH NO PIXELS:
;;;;
;;;;   * NESTING with independent diff scopes — Miller columns.  Named in DESIGN.md rule 9 as one
;;;;     of the two things "no client has yet exercised".
;;;;   * OPAQUE NODES — an image preview, which the framebuffer blits and the DOM cannot, so the
;;;;     DOM must get the caption the app supplied and nothing else.
;;;;
;;;; The dependency on warren is real and is not free: warren's own system depends on gesso, glass,
;;;; scribe and pigment, so loading THIS loads a pixel stack.  That is fine for an optional client
;;;; system and would not be fine for core — :warp still depends on bordeaux-threads and nothing
;;;; else, and t/core.lisp is still the standing proof of it.

(defsystem "warp-files"
  :description "A Miller-column projection of warren's filesystem model — warp's client two, and the
first client to nest and the first to carry a node it cannot describe in cells."
  :version "0.1.0"
  :author "ynniv"
  :license "MIT"
  :depends-on ("warp" "warren")
  :serial t
  :components
  ((:module "."
    :serial t
    :components
    ((:file "package")
     (:file "model")        ; the domain over warren's fs.lisp: columns, rows, keys, present, commands
     (:file "columns")))))  ; the Miller layout: one walk, and the positional claim left to the encoding

;; The framebuffer encoding.  Separate so the model and the column walk can be loaded — and
;; measured — without a framebuffer, exactly as warp-monitor is separate from warp-monitor/glass.
(defsystem "warp-files/glass"
  :description "Miller columns as framebuffer writes: paint, and the rectangle that is this
encoding's positional claim.  The image preview is blitted here and nowhere else."
  :depends-on ("warp-files" "warp-glass")
  :serial t
  :components ((:module "." :components ((:file "glass")))))

;; The DOM encoding.  It receives the SAME projection and the same opaque node, cannot render the
;; node's pixels, and is entitled to know what the region is anyway — which is the whole of rule 9's
;; "opaque nodes, and the caption that cannot be derived".
(defsystem "warp-files/dom"
  :description "Miller columns as nested sibling lists: (parent . after) per column, and an opaque
node that arrives as its caption and a placeholder because the wire is JSON cells."
  :depends-on ("warp-files" "warp-dom")
  :serial t
  :components ((:module "." :components ((:file "dom")))))
