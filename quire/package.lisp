;;;; quire/package.lisp — a compound document over a cube: warp's fourth client, and the
;;;; first one that is not a list of one kind of thing.

(defpackage #:warp-quire
  (:use #:cl #:warp)
  (:export
   ;; the cube
   #:cube #:cube-facts #:cube-dims #:cube-measures
   #:sum-of #:count-of #:mean-of #:max-of
   #:dim-values #:dim-key #:measure-spec #:fact-matches-p #:fmt-number
   #:slice #:slice-rows-by #:slice-cols-by #:slice-measure #:slice-filter #:slice-limit
   #:slice-column-values #:rows-of
   #:slice-row #:slice-row-label #:slice-row-cells #:slice-row-total
   ;; the document
   #:part #:part-id #:part-title
   #:prose-part #:prose-level #:prose-text
   #:slice-part #:part-slice #:part-note
   #:document #:doc-title #:doc-cube #:doc-parts #:doc-part
   #:part-rows #:document-rows #:row-container
   ;; the rows
   #:doc-row #:row-part
   #:heading-row #:heading-level #:heading-text
   #:prose-row #:prose-row-text
   #:slice-head-row #:head-labels
   #:slice-data-row #:data-label #:data-cells #:data-total #:data-drill
   #:slice-total-row #:total-label #:total-value
   #:crumb-row #:crumb-path
   ;; the app
   #:quire-view #:quire-projection #:*document*
   #:drill-into #:pop-to #:measure-sum #:measure-count #:pivot-region #:pivot-quarter
   ;; the fixture
   #:example-cube #:example-document))
