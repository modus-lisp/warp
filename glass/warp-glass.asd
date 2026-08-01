(defsystem "warp-glass"
  :description "warp's glass surface: deltas become framebuffer writes; RFB input becomes commands."
  :depends-on ("warp" "glass" "glass/text" "scribe" "bordeaux-threads")
  :serial t
  :components ((:file "package") (:file "surface")))
