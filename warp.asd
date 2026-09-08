(defsystem "warp"
  :description "Typed projections over a keyed delta protocol: presentations, commands, a reconciler
that converges a consumer to current state under a budget, and the projection/consumer split that
lets N consumers share one query.  The renderer is one encoding, and it is not in here."
  :version "0.1.0"
  :author "ynniv"
  :license "MIT"
  ;; The whole protocol, and NOTHING that can see a pixel.  bordeaux-threads is the only dependency
  ;; because a projection is shared across consumers that tick on their own threads; glass is a
  ;; dependency of warp-glass, never of warp, and t/core.lisp is the standing proof.
  :depends-on ("bordeaux-threads")
  :serial t
  :components
  ((:module "src"
    :serial t
    :components
    ((:file "packages")
     (:file "presentation")     ; the record, per-type key functions, grid-snapped extents
     (:file "reconcile")        ; state->state diff, coalescing, budget + deferral, snapshots
     (:file "command")          ; commands on types: applicability, declared safe defaults, invocation
     (:file "widget")           ; what a row's cells MEAN: the declared layout per type
     (:file "icons")            ; a small vector set, as path data three encodings can share
     (:file "present")          ; present (object type view) + list layout
     (:file "projection")       ; rule 8, shared half: the query and the objects it returns
     (:file "consumer")         ; rule 8, per-consumer half: layout, budget, stream, the encoding seam
     (:file "menu")))))         ; the hold menu as presentations; what a recognized gesture means
