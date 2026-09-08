;;;; warp-dom — warp's DOM encoding: deltas become node edits in somebody else's browser.
;;;;
;;;; The third encoding, and the one that tests whether rule 8's seam is real.  glass was written
;;;; first and core was carved out of it, so "encodings per consumer" could still have been a story
;;;; about one encoding with the pixels factored out.  This one was written from outside: it loads
;;;; :warp and NOTHING else — no glass, no framebuffer, no gesso — and supplies five methods.
;;;;
;;;; What it deliberately does not contain is a transport.  A DOM consumer over a WebRTC data
;;;; channel and a DOM consumer over a local WebSocket are the same encoding with a different sink,
;;;; so the sink is a function slot and the socket lives in warp-dom/serve.
;;;;
;;;; channel.lisp is the line between those two statements.  It owns everything a HOST would
;;;; otherwise have to write around the sink — a clock, one lock over ticks and messages, a send
;;;; that cannot signal, a close that runs on every path — with the transport still reduced to a
;;;; function of one string.  It is here rather than in /serve because a WebSocket and an SCTP
;;;; stream need identically all of it, and because the whole point is that it can be driven by a
;;;; fake transport in a test rather than by the gateway it is eventually for.

(defpackage #:warp-dom
  (:use #:cl)
  ;; bordeaux-threads arrives with :warp (a projection is shared across consumers that tick on their
  ;; own threads), so the nickname is available even though warp-dom itself does not name it as a
  ;; dependency.  channel.lisp uses it for one optional ticker thread and for the consumer's own
  ;; lock; warp-dom/serve — the transport — uses it for sockets.
  (:local-nicknames (#:bt #:bordeaux-threads))
  (:import-from #:warp
                #:consumer #:attach #:detach #:tick #:tick-all #:resync #:pull
                #:lay-out #:apply-deltas #:menu-presentations #:delta-cost #:moved-p
                #:viewport-width #:viewport-height #:content-height #:scroll-to #:scroll-by
                #:projection #:make-projection #:projection-rows-fn #:projection-type-fn
                #:projection-objects #:projection-as-of #:projection-epoch #:projection-queries
                #:projection-consumers
                #:consumer-projection #:consumer-view #:consumer-stream #:consumer-budget
                #:consumer-invoker #:consumer-selected #:consumer-menu #:consumer-scroll-y
                #:consumer-visible #:consumer-last-result #:consumer-landed #:consumer-emitted
                #:consumer-passes #:consumer-deferred #:consumer-stop #:consumer-name
                #:consumer-lock #:cmd-destructive #:cmd-cost #:cmd-label
                #:consumer-width #:consumer-viewport-h #:consumer-row-height
                #:presentation #:make-presentation #:presentation-key
                #:p-key #:p-type #:p-object #:p-extent #:p-as-of #:p-fingerprint #:p-state
                #:delta-kind #:delta-key #:delta-presentation #:delta-extent #:delta-dx #:delta-dy
                #:ds-generation
                #:present #:row-type-of #:now-tick
                #:menu-item #:mi-kind #:mi-command #:mi-target
                ;; the picker's half.  IMPORTED EXPLICITLY, like everything else here:
                ;; warp-dom does not :USE warp, so exporting a symbol from warp is not
                ;; enough to make it visible -- it has to be named in this list too.
                ;; Missing it reads as a fresh WARP-DOM::MI-LIVE and fails at runtime
                ;; inside MENU-PRESENTATIONS, where the error surfaces as an empty menu.
                #:mi-value #:mi-vlabel #:mi-live #:cmd-values-fn
                #:open-menu #:confirm-menu #:close-menu #:on-gesture #:run-command
                #:find-command #:applicable-commands #:cmd-name)
  (:export
   ;; the encoding
   #:dom-consumer #:attach-dom #:dom-sink #:dom-outbox #:take-frames
   #:dom-rows #:dom-container #:dom-after #:frame-for #:delta-json
   #:dom-sent-bytes #:dom-last-frame-bytes #:dom-app #:app-containers
   ;; what the browser sends back
   #:on-message #:client-message
   ;; the channel: a consumer, a clock and a link, where the link is a function of one string
   #:dom-channel #:open-channel #:channel-receive #:channel-tick #:channel-close
   #:channel-consumer #:channel-stats #:channel-send #:channel-hz #:channel-name
   #:channel-frames #:channel-bytes #:channel-received #:channel-send-errors
   #:channel-last-error #:channel-log
   ;; several projections over one link, routed by the label on the client's message
   #:dom-mux #:make-mux #:mux-receive #:mux-close #:mux-apps #:mux-channels #:message-app
   ;; JSON, because the wire is JSON and the tests read it
   #:to-json #:from-json #:json-get
   ;; re-exported so a caller never needs both packages open
   #:attach #:tick #:tick-all #:resync #:detach #:scroll-to #:scroll-by
   #:consumer-visible #:consumer-scroll-y #:consumer-selected #:consumer-menu
   #:consumer-emitted #:consumer-deferred #:consumer-landed #:consumer-passes
   #:consumer-last-result #:consumer-invoker #:consumer-budget))
