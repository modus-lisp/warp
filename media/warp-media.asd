;;;; warp-media — a media player as a warp app: a playlist, a transport, a clock, and a picture.
;;;;
;;;; The arrangement is Winamp's, because it was the right one: the list is the thing you are
;;;; working with, the transport is four controls that never move, and the clock tells you where
;;;; you are.  What is new is what it is made of.  glass's music window was a McCLIM frame that
;;;; drew a playlist; this is a PROJECTION — the same rows, the same commands, one query — and the
;;;; picture is a rule-9 OPAQUE NODE: the framebuffer encoding blits the decoded frame, and any
;;;; other consumer receives the caption ("Big Buck Bunny — 640 x 360, frame 812") and nothing else.
;;;;
;;;; Decoding is cassette (VP8 + Opus, pure CL) and reed (MP3/AAC/Opus files).  Sound goes to the
;;;; glass SESSION MIXER as one source thunk, so whoever is listening to the session hears it — a
;;;; VNC viewer, a WebRTC peer — and the mixer's 20 ms clock is the clock the picture is paced by.
;;;; The player is shared state and the query's argument; which row is selected is the seat's.

(defsystem "warp-media"
  :description "A media player projected over a directory of files: playlist rows, a transport, a
clock, and the current video frame as an opaque node.  No pixels in here."
  :version "0.1.0"
  :author "ynniv"
  :license "MIT"
  :depends-on ("warp" "cassette" "reed" "bordeaux-threads")
  :serial t
  :components
  ((:module "."
    :serial t
    :components
    ((:file "package")
     (:file "engine")       ; the player: decode threads, the audio source thunk, the clock, frames
     (:file "model")        ; the domain: folders, tracks, the transport, present, keys, commands
     (:file "layout")))))   ; the consumer with no encoding: what is where in running order

(defsystem "warp-media/glass"
  :description "The framebuffer encoding: the transport and playlist painted, and the video frame
blitted into its pane — the one place in the system that can see the pixels."
  :depends-on ("warp-media" "warp-glass" "glass/audio")
  :serial t
  :components ((:module "." :components ((:file "glass")))))
