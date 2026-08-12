;;;; warp-glass — warp's framebuffer encoding.
;;;;
;;;; The protocol lives in WARP.  What is left here is the encoding: paint, hit-testing, RFB input,
;;;; menu geometry, and a CONSUMER subclass whose encoding target is a glass framebuffer.
;;;;
;;;; The moved names are IMPORTED and re-exported rather than wrapped, so WARP-GLASS:TICK and
;;;; WARP:TICK are the same symbol and the same function.  A caller that still says WARP-GLASS:TICK
;;;; is not on a compatibility path — it is calling the protocol under the name it used to have.

(defpackage #:warp-glass
  (:use #:cl)
  (:local-nicknames (#:bt #:bordeaux-threads))
  (:import-from #:warp
                ;; the projection: the query, shared
                #:projection #:make-projection #:projection-rows-fn #:projection-type-fn
                #:projection-objects #:projection-as-of #:projection-epoch #:projection-queries
                #:projection-consumers #:pull
                ;; the consumer: the seat, and the protocol generic on it
                #:consumer #:detach #:tick #:tick-all #:resync
                #:lay-out #:apply-deltas #:menu-presentations
                #:viewport-width #:viewport-height #:content-height #:scroll-to #:scroll-by
                #:consumer-projection #:consumer-rows-fn #:consumer-view #:consumer-stream
                #:consumer-budget #:consumer-invoker #:consumer-selected #:consumer-menu
                #:consumer-scroll-y #:consumer-width #:consumer-viewport-h #:consumer-row-height
                #:consumer-visible #:consumer-last-result #:consumer-landed #:consumer-emitted
                #:consumer-passes #:consumer-deferred #:consumer-stop #:consumer-lock
                ;; menus and gestures: the model is warp's, the geometry is ours
                #:menu-item #:make-menu-item #:mi-kind #:mi-command #:mi-target
                #:open-menu #:confirm-menu #:close-menu #:on-gesture #:run-command)
  (:export #:paint
           ;; re-exported from warp: the protocol, under the names it had here
           #:projection #:make-projection #:projection-rows-fn #:projection-type-fn
           #:projection-objects #:projection-as-of
           #:projection-epoch #:projection-queries #:projection-consumers #:pull
           #:consumer #:attach #:detach #:tick #:tick-all #:resync
           #:lay-out #:apply-deltas #:scroll-to #:scroll-by #:content-height
           #:viewport-width #:viewport-height #:menu-presentations
           #:consumer-projection #:consumer-view #:consumer-rows-fn #:consumer-stream
           #:consumer-budget #:consumer-invoker #:consumer-selected #:consumer-menu
           #:consumer-scroll-y #:consumer-width #:consumer-viewport-h #:consumer-row-height
           #:consumer-visible #:consumer-last-result #:consumer-emitted
           #:consumer-passes #:consumer-deferred #:consumer-stop
           #:menu-item #:mi-kind #:mi-command #:mi-target #:open-menu #:close-menu #:on-gesture
           ;; this encoding's own: where the deltas land, and how they are reached
           #:fb-consumer #:consumer-fb #:consumer-port #:consumer-painted #:hit
           ;; the single-seat names, kept so every existing call site still works
           #:surface #:make-surface #:run #:sf-fb #:sf-visible #:sf-selected #:sf-scroll-y #:sf-view
           #:sf-painted #:sf-emitted #:sf-passes #:sf-deferred #:sf-stop
           #:sf-menu #:sf-last-result
           #:make-surface-app #:on-pointer #:+menu-w+ #:+menu-row+
           #:+bg+ #:+row-bg+ #:+row-sel+ #:+fg+ #:+dim+ #:+ok+ #:+warn+ #:+bad+ #:trend-colour #:fb-text-baseline #:row-baseline #:text-ascent))
