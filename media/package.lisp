;;;; media/package.lisp — warp's media player.

(defpackage #:warp-media
  (:use #:cl #:warp)
  (:local-nicknames (#:bt #:bordeaux-threads))
  (:export
   ;; the engine: shared playback state, the query's argument
   #:player #:make-player #:player-state #:player-error #:player-track #:player-position
   #:player-duration #:player-title #:player-frame #:player-frame-no #:player-has-video-p
   #:player-queue #:player-index #:player-mixer #:player-clock-seconds
   #:play-path #:play-index #:play-next #:play-prev #:toggle #:pause #:resume #:stop #:seek #:skip #:seek-fraction
   #:mp3-index #:mi-duration #:mi-toc #:mi-frames
   #:attach-mixer #:detach-mixer #:player-source #:shutdown
   #:video-frame #:video-frame-p #:vf-w #:vf-h #:vf-rgb #:vf-no #:vf-timestamp
   ;; the library and the domain objects
   #:*media-root* #:*extensions* #:default-media-root #:playable-p #:folder-tracks #:folder-subdirs
   #:library #:make-library #:library-player #:library-folder #:library-root #:library-rows
   #:library-projection #:library-open #:library-up
   #:media-row #:row-kind #:row-path #:row-library #:row-index
   #:transport #:transport-library #:media-button #:button-kind #:button-library
   #:seek-cell #:cell-index #:cell-count #:cell-library #:+seek-cells+
   #:picture-node #:node-caption #:node-frame #:node-library
   ;; presentation types and the view
   #:media-view #:media-head #:media-dir #:media-track #:media-transport #:media-control #:media-picture #:media-seek
   #:row-type #:mmss
   ;; the layout seam
   #:media-consumer #:picture-height #:has-picture-p #:list-top #:control-place #:transport-place
   #:picture-place #:row-place #:visible-list-rows #:seek-place))
