;;;; app/glass-app.lisp — the monitor as a window in the glass desktop.
;;;;
;;;; Two ways to run the same client, sharing one definition of how a row looks:
;;;;
;;;;   standalone   serve-monitor.lisp — its own RFB server on its own port
;;;;   desktop app  MONITOR-SURFACE — a window the glass WM owns, composites, and decorates
;;;;
;;;; The second is the one that reaches the phone, because the phone watches the desktop.  It is
;;;; also the honest test: inside the desktop, warp's damage competes with every other window's for
;;;; the same VP8 budget, so an over-emitting projection shows up as someone else's dropped frame.
;;;;
;;;; PAINT lives here rather than in surface.lisp because it is editorial — how a stat should LOOK is
;;;; this app's decision, not the toolkit's.  warp supplies the default (the MOP slot walk); an app
;;;; specialises to design.

(in-package #:warp-monitor)

;;; A designed row: the VALUE leads (that is what a glance is looking for), the name is secondary,
;;; and a colour bar carries the trend so it reads without being read.
(defmethod warp-glass:paint (fb p view)
  (declare (ignorable view))
  (let* ((e (warp:p-extent p))
         (x (warp::extent-x e)) (y (warp::extent-y e))
         (w (warp::extent-w e)) (h (warp::extent-h e))
         (c (warp:p-fingerprint p))
         (value (princ-to-string (first c)))
         (label (princ-to-string (second c)))
         (trend (third c)))
    (glass:fb-rect fb x y w h warp-glass:+row-bg+)
    (glass:fb-rect fb x y 4 h (warp-glass:trend-colour trend))
    (glass:fb-rect fb x (+ y h -1) w 1 warp-glass:+bg+)          ; hairline separator
    ;; ONE baseline for both columns, derived from the row.  The value sets it (it is the larger
    ;; face and the thing being read); the label sits on the same line rather than being centred
    ;; independently, which is what made it float above the value it labels.
    (let ((base (warp-glass:row-baseline y (1- h) 15)))          ; 1- h: keep clear of the hairline
      (warp-glass:fb-text-baseline fb (+ x 14) base value :size 15 :color warp-glass:+fg+)
      (warp-glass:fb-text-baseline fb (+ x 150) base label :size 12 :color warp-glass:+dim+))))

;;; the menu, painted.  Destructive rows read as destructive without needing to be read.
(defmethod warp-glass:paint (fb (p warp:presentation) view)
  (if (eq (warp:p-type p) 'warp-glass::menu-item)
      (let* ((e (warp:p-extent p))
             (x (warp::extent-x e)) (y (warp::extent-y e))
             (w (warp::extent-w e)) (h (warp::extent-h e))
             (c (warp:p-fingerprint p))
             (label (princ-to-string (first c)))
             (cost (second c))
             (destructive (eq :destructive (third c))))
        (glass:fb-rect fb x y w h (if destructive #x3a1c1c #x222c38))
        (glass:fb-rect fb x y 3 h (if destructive warp-glass:+bad+ warp-glass:+fg+))
        (glass:fb-rect fb (+ x w -1) y 1 h warp-glass:+bg+)
        (warp-glass:fb-text-baseline fb (+ x 12) (warp-glass:row-baseline y h 13) label :size 13
                                     :color (if destructive #xffb0b0 warp-glass:+fg+))
        ;; the cost class, shown: a human reads it as "this will take a moment", an agent as
        ;; scheduling data.  Same field, two renderings.
        (when cost
          (warp-glass:fb-text-baseline fb (+ x w -54) (warp-glass:row-baseline y h 13)
                                       (string-downcase (princ-to-string cost))
                                       :size 10 :color warp-glass:+dim+)))
      (call-next-method)))

;;; ---- the desktop surface ----------------------------------------------------

(defun monitor-surface (fb)
  "glass's :surface contract — (values ON-KEY ON-POINTER DIRTY-P) for a framebuffer the WM owns.

The rows are laid out to the framebuffer's ACTUAL size rather than a fixed one, so the window can be
resized by the WM and the result-set follows.  That is the whole reason layout takes a viewport: a
view subscribes to a slice, and the slice is a property of the window, not of the data."
  (warp-glass:make-surface-app
   fb
   :view 'monitor-view
   :rows-fn (lambda ()
              (monitor-presentations :width (glass:fb-width fb)
                                     :viewport-h (glass:fb-height fb)))
   ;; The desktop shares one VP8 budget across every window, so a monitor that repaints its whole
   ;; view in one pass would starve the others.  400 macroblocks is roughly a third of this window
   ;; and leaves the rest to whatever else is on screen; the reconciler defers the remainder and
   ;; drains it over the following passes.
   :budget 400
   :invoker :allowlist))
