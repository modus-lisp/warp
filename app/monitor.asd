(defsystem "warp-monitor"
  :description "A live monitor for the glass pipeline — warp's first practical client."
  :depends-on ("warp")
  :serial t
  :components ((:file "package") (:file "monitor")))
