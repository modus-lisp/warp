(defpackage #:warp-glass
  (:use #:cl)
  (:local-nicknames (#:bt #:bordeaux-threads))
  (:export #:paint
           ;; DESIGN.md rule 8: the projection is shared, the consumer is the seat
           #:projection #:make-projection #:projection-rows-fn #:projection-view #:projection-rows
           #:projection-epoch #:projection-queries #:projection-consumers #:pull
           #:consumer #:attach #:detach #:tick #:tick-all #:resync #:hit
           #:consumer-projection #:consumer-fb #:consumer-view #:consumer-rows-fn #:consumer-stream
           #:consumer-budget #:consumer-invoker #:consumer-selected #:consumer-menu
           #:consumer-visible #:consumer-last-result #:consumer-painted #:consumer-emitted
           #:consumer-passes #:consumer-deferred #:consumer-stop #:consumer-presentation
           ;; the single-seat names, kept so every existing call site still works
           #:surface #:make-surface #:run #:sf-fb #:sf-visible #:sf-selected
           #:sf-painted #:sf-emitted #:sf-passes #:sf-deferred #:sf-stop
           #:menu-item #:mi-kind #:mi-command #:mi-target #:sf-menu #:sf-last-result
           #:make-surface-app #:on-pointer #:open-menu #:close-menu #:+menu-w+ #:+menu-row+
           #:+bg+ #:+row-bg+ #:+row-sel+ #:+fg+ #:+dim+ #:+ok+ #:+warn+ #:+bad+ #:trend-colour #:fb-text-baseline #:row-baseline #:text-ascent))
