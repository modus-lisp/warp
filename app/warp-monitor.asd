(defsystem "warp-monitor"
  :description "A live monitor for the glass pipeline — warp's first practical client."
  :depends-on ("warp")
  :serial t
  :components ((:file "package") (:file "monitor")))

;; The monitor as a glass window.  Kept separate from "warp-monitor" so the headless harness
;; (run-monitor.lisp) can still load the app without dragging in glass and a framebuffer.
(defsystem "warp-monitor/glass"
  :description "The pipeline monitor as a window in the glass desktop."
  :depends-on ("warp-monitor" "warp-glass")
  :serial t
  :components ((:file "glass-app")))
