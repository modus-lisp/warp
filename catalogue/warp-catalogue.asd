;;;; warp-catalogue.asd — every widget warp has, rendered as itself.
;;;;
;;;; Not a mock: each sample is presented under the REAL presentation type and travels as real
;;;; deltas through the real reconciler, painted by the client that paints every other app.  A
;;;; catalogue rendered from a fixture would agree with itself and with nothing else.

(defsystem "warp-catalogue"
  :description "warp's widget catalogue -- client five, and the only one whose subject is warp."
  :version "0.1.0"
  :author "ynniv"
  :license "MIT"
  :depends-on ("warp")
  :serial t
  :components ((:module "." :serial t
                :components ((:file "package") (:file "catalogue")))))

(defsystem "warp-catalogue/dom"
  :description "The catalogue as nested sibling lists: one container per widget."
  :depends-on ("warp-catalogue" "warp-dom")
  :serial t
  :components ((:module "." :components ((:file "dom")))))
