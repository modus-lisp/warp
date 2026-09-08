;;;; warp-quire.asd — a compound document over a cube: authored parts and live query slices.
;;;;
;;;; warp's fourth client, and the first that is not a list of one kind of thing.  Its job is
;;;; to put load on the widget question: three earlier clients each needed one row shape, so
;;;; the reference client could infer a row's kind by looking at its third cell.  This one
;;;; needs six kinds and two of them are n-ary, which that convention cannot express at any
;;;; width.

(defsystem "warp-quire"
  :description "A compound document -- authored prose and live OLAP slices in one surface --
                as a warp projection.  The client that asks what a widget set has to carry."
  :version "0.1.0"
  :author "ynniv"
  :license "MIT"
  :depends-on ("warp")
  :serial t
  :components ((:module "." :serial t
                :components ((:file "package")
                             (:file "cube")      ; facts, dimensions, measures, a slice
                             (:file "doc")       ; parts, rows, keys, the query
                             (:file "present")   ; six row kinds and their cell layouts
                             (:file "app")       ; drill, pop, pivot -- rule 5's closed vocabulary
                             (:file "example")))))

;;; The DOM half, separate for the reason warp-files splits its own: an encoding is optional,
;;; and a caller that wants the document model without a browser -- a test, a framebuffer, a
;;; text dump -- should not load warp-dom to get it.
(defsystem "warp-quire/dom"
  :description "The compound document as nested sibling lists: one container per part."
  :depends-on ("warp-quire" "warp-dom")
  :serial t
  :components ((:module "." :components ((:file "dom")))))
