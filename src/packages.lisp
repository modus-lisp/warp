;;;; warp — typed projections over a keyed delta protocol.  See DESIGN.md.

(defpackage #:warp
  (:use #:cl)
  (:local-nicknames (#:bt #:bordeaux-threads))
  (:export
   ;; presentations
   #:command-values #:command-current
   #:define-widget #:widget-of #:widget-cells #:widget-layout
   ;; THE CORE SET, BY NAME.  Exported because a vocabulary you cannot name is not a
   ;; vocabulary: an app declaring its own type wants to say "this is a BUTTON", and a test or
   ;; an encoding wants to compare against the shape core means.  The registry is keyed by
   ;; symbol identity, so an unexported name read in another package is a different widget --
   ;; which is the same cross-package trap that made cell names keywords.
   #:menu-item #:row #:entry #:opaque #:heading #:prose #:button #:meter
   #:table-head #:table-row #:table-total #:chip
   #:presentation #:make-presentation #:copy-presentation
   #:p-key #:p-type #:p-object #:p-extent #:p-as-of
   #:p-fingerprint #:p-state #:p-children #:p-cost
   #:define-presentation-key #:presentation-key
   #:+grid+ #:snap #:snap-extent #:rect-p #:extent-x #:extent-y #:extent-w #:extent-h
   ;; the delta stream
   #:delta #:delta-kind #:delta-key #:delta-presentation #:delta-dx #:delta-dy #:delta-extent
   #:delta-stream #:make-delta-stream #:ds-generation #:ds-pending-count
   #:emit #:snapshot
   ;; what a delta COSTS, and what MOVING looks like, are the encoding's: a budget is denominated in
   ;; the consumer's link, and a browser reorders siblings where a framebuffer translates pixels
   #:delta-cost #:moved-p
   ;; commands
   #:command #:cmd-name #:cmd-arg-type #:cmd-destructive #:cmd-confirm #:cmd-cost #:cmd-label
   #:define-command #:define-command-authorization #:find-command
   #:define-default-command #:default-command
   #:applicable-commands #:invoke #:command-refused #:refused-command #:refused-reason
   #:gesture-command
   ;; projections + layout
   #:present #:layout-list #:list-content-height #:row-type-of
   ;; rule 8: the projection is the QUERY and is shared
   #:projection #:make-projection #:projection-rows-fn #:projection-type-fn
   #:projection-objects #:projection-as-of #:projection-epoch #:projection-queries
   #:projection-consumers #:projection-lock #:pull
   ;; rule 8: the consumer is whatever owns an encoding target.  LAY-OUT, APPLY-DELTAS and
   ;; MENU-PRESENTATIONS are the seam a second encoding specialises.
   #:consumer #:attach #:detach #:tick #:tick-all #:resync
   #:lay-out #:apply-deltas #:menu-presentations
   #:viewport-width #:viewport-height #:content-height #:scroll-to #:scroll-by
   #:recording-consumer #:consumer-record #:take-record
   #:consumer-projection #:consumer-rows-fn #:consumer-name #:consumer-view #:consumer-stream
   #:consumer-budget #:consumer-invoker #:consumer-selected #:consumer-menu
   #:consumer-scroll-y #:consumer-width #:consumer-viewport-h #:consumer-row-height
   #:consumer-visible #:consumer-last-result #:consumer-epoch #:consumer-lock #:consumer-stop
   #:consumer-landed #:consumer-emitted #:consumer-passes #:consumer-deferred
   ;; menus are presentations too; gestures are recognized at the edge and mean the same everywhere
   #:menu-item #:make-menu-item #:mi-kind #:mi-command #:mi-target
   ;; the picker's half: a choice carries a value, a label and whether it is live
   #:mi-value #:mi-vlabel #:mi-live
   #:open-menu #:confirm-menu #:close-menu #:on-gesture #:run-command
   ;; time as an input
   #:+tick-seconds+ #:now-tick))
