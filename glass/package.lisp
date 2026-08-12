(defpackage #:warp-glass
  (:use #:cl)
  (:local-nicknames (#:bt #:bordeaux-threads))
  (:export #:paint
           ;; DESIGN.md rule 8: the projection is the query and is shared; the consumer is the seat,
           ;; and present/layout/diff/encode — so view, scroll, viewport and extents — are its own
           #:projection #:make-projection #:projection-rows-fn #:projection-type-fn
           #:projection-objects #:projection-as-of
           #:projection-epoch #:projection-queries #:projection-consumers #:pull
           #:consumer #:attach #:detach #:tick #:tick-all #:resync #:hit
           #:lay-out #:apply-deltas #:scroll-to #:scroll-by #:content-height
           #:viewport-width #:viewport-height
           #:consumer-projection #:consumer-fb #:consumer-view #:consumer-rows-fn #:consumer-stream
           #:consumer-budget #:consumer-invoker #:consumer-selected #:consumer-menu
           #:consumer-scroll-y #:consumer-width #:consumer-viewport-h #:consumer-row-height
           #:consumer-visible #:consumer-last-result #:consumer-painted #:consumer-emitted
           #:consumer-passes #:consumer-deferred #:consumer-stop
           ;; the single-seat names, kept so every existing call site still works
           #:surface #:make-surface #:run #:sf-fb #:sf-visible #:sf-selected #:sf-scroll-y #:sf-view
           #:sf-painted #:sf-emitted #:sf-passes #:sf-deferred #:sf-stop
           #:menu-item #:mi-kind #:mi-command #:mi-target #:sf-menu #:sf-last-result
           #:make-surface-app #:on-pointer #:open-menu #:close-menu #:+menu-w+ #:+menu-row+
           #:+bg+ #:+row-bg+ #:+row-sel+ #:+fg+ #:+dim+ #:+ok+ #:+warn+ #:+bad+ #:trend-colour #:fb-text-baseline #:row-baseline #:text-ascent))
