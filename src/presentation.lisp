;;;; presentation.lisp — the record, per-type key functions, grid-snapped extents.
;;;;
;;;; A presentation is a typed object that was displayed.  FINGERPRINT is the CLIM :cache-value
;;;; idea: the value the view derived its appearance from, compared with EQUAL to decide whether a
;;;; matched presentation actually changed.  Keeping it separate from RENDER means change detection
;;;; never has to inspect a closure.

(in-package #:warp)

;;; ---- extents ---------------------------------------------------------------
;;; Extents live in FRAMEBUFFER space and snap to the macroblock grid: the delta chain ends in 16px
;;; macroblocks, so sub-grid precision is precision the encoder cannot use (see DESIGN.md rule 3).

(defconstant +grid+ 16)

(declaim (inline extent-x extent-y extent-w extent-h))
(defun extent-x (e) (first e))
(defun extent-y (e) (second e))
(defun extent-w (e) (third e))
(defun extent-h (e) (fourth e))

(defun snap (n &key (up nil))
  "Round N to the macroblock grid — down for origins, up for sizes."
  (if up (* +grid+ (ceiling n +grid+)) (* +grid+ (floor n +grid+))))

(defun snap-extent (x y w h)
  "An extent snapped OUTWARD to the grid, so it always covers what it claims to."
  (let* ((x0 (snap x)) (y0 (snap y))
         (x1 (snap (+ x w) :up t)) (y1 (snap (+ y h) :up t)))
    (list x0 y0 (- x1 x0) (- y1 y0))))

;;; ---- the record ------------------------------------------------------------

(defstruct (presentation (:conc-name p-))
  key                     ; identity within the parent (see PRESENTATION-KEY)
  type                    ; a symbol; commands are declared against these
  object                  ; the domain object this displays
  extent                  ; (x y w h), framebuffer space, grid-snapped
  (as-of nil)             ; when the underlying data was read; makes stale delivery honest
  (fingerprint nil)       ; EQUAL-compared summary of what the appearance depends on
  (state nil)             ; this consumer's view state (see below); EQUAL-compared like FINGERPRINT
  (cost nil)              ; optional override; defaults to the extent's macroblock count
  (children '()))

;;; STATE is rules 7 and 8 meeting in one slot.  FINGERPRINT is PRESENT's output — what the view
;;; derived the appearance from.  STATE is what this consumer's view state adds to it: selected,
;;; expanded.  They are compared identically, because from the reconciler's side "selection moved"
;;; and "the value changed" are the same event — this row no longer looks the way you were told it
;;; looks.
;;;
;;; The slot originally existed because presentations themselves were shared between consumers and
;;; a selection could not be written into a shared row.  Nothing is shared at this level any more —
;;; each consumer lays out its own presentations over shared OBJECTS — so it would now be possible
;;; to fold selection into the fingerprint.  It is kept separate anyway, for a reason that outlives
;;; the one it was introduced for: FINGERPRINT is PRESENT's output and PRESENT's signature is
;;; (object type view), with no room for a seat's state; and an encoding needs the two apart —
;;; a macroblock consumer tints a row, a token consumer would say "(selected)", and neither can
;;; recover which half was which from a merged blob.  What did go away is the copy-on-write
;;; machinery around it: the consumer builds these presentations, so it just annotates its own.

;;; EXTENT is where a presentation records WHERE IT IS, and "where" is a claim only an encoding can
;;; make.  The framebuffer's is the rectangle above.  A DOM consumer's is (parent . after-key),
;;; because a browser places nodes by sibling order and has no coordinates to translate; a token
;;; consumer's may be nothing at all.  So everything in core that reads an extent AS GEOMETRY has to
;;; ask first, and answer harmlessly when the answer is no — a pixel default that crashes on a
;;; position it does not recognise is a pixel assumption with a stack trace attached, which is the
;;; same bug as a pixel assumption without one.

(defun rect-p (e)
  "Is E a framebuffer extent — a PROPER list of exactly four reals?  Spelled out cons by cons
because the position it is being asked about may be an improper list (a DOM's is a dotted
(parent . after)), and LIST-LENGTH signals on one."
  (and (consp e) (consp (cdr e)) (consp (cddr e)) (consp (cdddr e)) (null (cddddr e))
       (every #'realp e)))

(defun p-macroblocks (p)
  "How many 16px macroblocks this presentation's extent covers — the natural cost unit for an
encoding that ends in an encoder.  A position that is not a rectangle costs one unit, exactly as a
missing one does: core has no way to price somebody else's geometry and does not pretend to."
  (let ((e (p-extent p)))
    (if (rect-p e)
        (max 1 (* (ceiling (extent-w e) +grid+) (ceiling (extent-h e) +grid+)))
        1)))

(defun presentation-cost (p) (or (p-cost p) (p-macroblocks p)))

;;; ---- per-type key functions ------------------------------------------------
;;; DESIGN.md rule 1: the default key is a per-type key function declared alongside the type.  Raw
;;; EQ is the fallback ONLY for objects with genuine identity — defaulting to it would be a trap,
;;; because objects rebuilt from a file or a query are never EQ across renders, so everything would
;;; look new and we would emit full damage forever while the code looked correct.

(defvar *key-functions* (make-hash-table :test 'eq))

(defmacro define-presentation-key (type (object) &body body)
  "Declare how to derive a stable key for presentations of TYPE."
  `(setf (gethash ',type *key-functions*) (lambda (,object) ,@body)))

(defun presentation-key (type object)
  "The stable key for OBJECT presented as TYPE.  Signals if TYPE has no key function and OBJECT has
no obvious identity, rather than silently falling back to something unstable."
  (let ((fn (gethash type *key-functions*)))
    (cond (fn (funcall fn object))
          ;; things that are their own identity
          ((or (symbolp object) (stringp object) (numberp object) (characterp object)) object)
          (t (error "warp: no presentation key function for type ~s, and ~s has no intrinsic~@
                     identity.  Declare one with DEFINE-PRESENTATION-KEY — see DESIGN.md rule 1."
                    type (type-of object))))))

;;; ---- time as an input ------------------------------------------------------
;;; DESIGN.md: `exp > now` changes when nothing changes, so NOW quantizes to a tick and the tick is
;;; a subscribable source.  Quantizing also keeps fingerprints stable: an un-quantized clock would
;;; make every row's fingerprint differ on every pass and defeat the whole diff.

(defconstant +tick-seconds+ 60)

(defun now-tick (&optional (universal (get-universal-time)))
  "The current time, quantized to +TICK-SECONDS+.  Crossing a tick is what lets a time-dependent
query emit ordinary GONE/CHANGED deltas."
  (* +tick-seconds+ (floor universal +tick-seconds+)))
