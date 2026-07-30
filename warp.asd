(defsystem "warp"
  :description "Typed projections over a keyed delta protocol: presentations, commands, and a
reconciler that converges a consumer to current state under a budget.  The renderer is one encoding."
  :version "0.1.0"
  :author "ynniv"
  :license "MIT"
  :serial t
  :components
  ((:module "src"
    :serial t
    :components
    ((:file "packages")
     (:file "presentation")     ; the record, per-type key functions, grid-snapped extents
     (:file "reconcile")        ; state->state diff, coalescing, budget + deferral, snapshots
     (:file "command")))))      ; commands on types: applicability, declared safe defaults, invocation
