;;;; warp — typed projections over a keyed delta protocol.  See DESIGN.md.

(defpackage #:warp
  (:use #:cl)
  (:export
   ;; presentations
   #:presentation #:make-presentation #:copy-presentation
   #:p-key #:p-type #:p-object #:p-extent #:p-as-of
   #:p-fingerprint #:p-state #:p-children #:p-cost
   #:define-presentation-key #:presentation-key
   #:+grid+ #:snap #:snap-extent #:extent-x #:extent-y #:extent-w #:extent-h
   ;; the delta stream
   #:delta #:delta-kind #:delta-key #:delta-presentation #:delta-dx #:delta-dy #:delta-extent
   #:delta-stream #:make-delta-stream #:ds-generation #:ds-pending-count
   #:emit #:snapshot
   ;; commands
   #:command #:cmd-name #:cmd-arg-type #:cmd-destructive #:cmd-confirm #:cmd-cost #:cmd-label
   #:define-command #:define-command-authorization #:find-command
   #:define-default-command #:default-command
   #:applicable-commands #:invoke #:command-refused #:refused-command #:refused-reason
   #:gesture-command
   ;; projections + layout
   #:present #:layout-list #:list-content-height
   ;; time as an input
   #:+tick-seconds+ #:now-tick))
