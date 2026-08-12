(defsystem "warp-dom"
  :description "warp's DOM encoding: deltas become node edits in a browser, priced in bytes."
  :version "0.1.0"
  :author "ynniv"
  :license "MIT"
  ;; :WARP AND NOTHING ELSE, and that is the claim being made.  glass was written first and core was
  ;; carved out of it, so "encodings per consumer" could still have been a story about one encoding
  ;; with the pixels factored out.  This system was written from outside the framebuffer: it must
  ;; not depend on warp-glass, must not load glass, and t/dom.lisp asserts both in the image.
  :depends-on ("warp")
  :serial t
  :components
  ((:module "."
    :serial t
    :components ((:file "package")
                 (:file "json")        ; the wire format, and why it is JSON
                 (:file "consumer")    ; lay-out, moved-p, delta-cost, apply-deltas, menu, input
                 ;; a consumer, a clock and a link — with the link still only a function of one
                 ;; string.  Everything a HOST would otherwise have to write around the sink, so
                 ;; that the part which cannot be tested offline is three calls that never signal.
                 (:file "channel")))))

;; The transport, kept OUT of the encoding.  A DOM consumer over a WebRTC data channel and one over
;; a local WebSocket are the same five methods with a different sink, so the socket is a separate
;; system and warp-dom itself has no I/O in it at all.
(defsystem "warp-dom/serve"
  :description "A local WebSocket + static-page server for the DOM encoding — liveness, not plumbing."
  :depends-on ("warp-dom" "bordeaux-threads")
  :serial t
  :components
  ((:module "."
    :serial t
    :components ((:file "ws")          ; sha1 + base64 + frames, in one file, no dependencies
                 (:file "serve")))))   ; the page, the socket, and the pass loop
