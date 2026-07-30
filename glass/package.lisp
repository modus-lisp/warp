(defpackage #:warp-glass
  (:use #:cl)
  (:local-nicknames (#:bt #:bordeaux-threads))
  (:export #:paint #:surface #:run #:tick #:sf-fb #:sf-visible #:sf-selected
           #:sf-painted #:sf-emitted #:sf-passes #:sf-stop #:hit
           #:+bg+ #:+row-bg+ #:+row-sel+ #:+fg+ #:+dim+ #:+ok+ #:+warn+ #:+bad+ #:trend-colour))
