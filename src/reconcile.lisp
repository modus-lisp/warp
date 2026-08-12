;;;; reconcile.lisp — the delta stream: state->state diff, coalescing, budget, deferral, snapshots.
;;;;
;;;; THE DESIGN CHOICE THAT MATTERS.  Deferral is not a queue of unsent deltas.  It is expressed as
;;;; ACKNOWLEDGED STATE LAGGING: the stream keeps the last state it actually delivered, and every
;;;; pass diffs *current* against *delivered*.  Emitting advances the delivered state; skipping does
;;;; not.  Three consequences fall out for free, and each of them is a bug we hit the other way in
;;;; the pixel path:
;;;;
;;;;   * coalescing — three changes to one key between passes are one delta, because we compare
;;;;     states rather than replaying events.  "Converge to current state under budget."
;;;;   * idle drain — a deferred delta is re-derived on the next pass even when nothing new happens,
;;;;     because delivered state still differs.  It CANNOT be stranded.  The video path kept a
;;;;     separate `pending` set and stranded it whenever the source went quiet: the viewer saw two
;;;;     rows of a change and never the rest.  Not representable here.
;;;;   * supersession — a delta deferred and then changed again is emitted once, at its newest value,
;;;;     never as stale intermediates.

(in-package #:warp)

(defstruct (delta (:constructor %make-delta))
  kind            ; :appeared | :changed | :gone | :moved
  key
  presentation    ; nil for :gone
  extent          ; for :gone, the extent to repair
  (dx 0) (dy 0))  ; for :moved

(defstruct (delta-stream (:conc-name ds-) (:constructor %make-delta-stream))
  (delivered (make-hash-table :test 'equal))   ; key -> presentation, as the consumer holds it
  (generation 0)
  (pending-count 0))

(defun make-delta-stream () (%make-delta-stream))

;;; ---- diffing ---------------------------------------------------------------

(defun %translation (old new)
  "If OLD and NEW differ only by position, the (dx dy); else NIL."
  (let ((a (p-extent old)) (b (p-extent new)))
    (when (and a b
               (= (extent-w a) (extent-w b))
               (= (extent-h a) (extent-h b)))
      (let ((dx (- (extent-x b) (extent-x a))) (dy (- (extent-y b) (extent-y a))))
        (unless (and (zerop dx) (zerop dy)) (list dx dy))))))

(defun %diff (delivered current)
  "Deltas that would bring DELIVERED (key -> presentation) to CURRENT (a list of presentations).
Pure: computes what is owed, decides nothing about budget."
  (let ((out '()) (seen (make-hash-table :test 'equal)))
    (dolist (new current)
      (let* ((key (p-key new)) (old (gethash key delivered)))
        (setf (gethash key seen) t)
        (cond
          ((null old)
           (push (%make-delta :kind :appeared :key key :presentation new :extent (p-extent new)) out))
          (t
           (let ((moved (%translation old new))
                 ;; the projection's content AND this consumer's view state: a row the consumer has
                 ;; selected does not look the way it was told it looks (DESIGN.md rules 7 and 8)
                 (same-look (and (equal (p-fingerprint old) (p-fingerprint new))
                                 (equal (p-state old) (p-state new)))))
             (cond
               ;; unchanged content that merely translated: the cheap case rule 2 exists for
               ((and same-look moved)
                (push (%make-delta :kind :moved :key key :presentation new
                                   :extent (p-extent new) :dx (first moved) :dy (second moved))
                      out))
               ((and same-look (equal (p-extent old) (p-extent new))) nil)   ; nothing owed
               (t
                (push (%make-delta :kind :changed :key key :presentation new
                                   :extent (p-extent new))
                      out))))))))
    ;; anything delivered that is no longer present
    (maphash (lambda (key old)
               (unless (gethash key seen)
                 (push (%make-delta :kind :gone :key key :extent (p-extent old)) out)))
             delivered)
    out))

;;; ---- ordering --------------------------------------------------------------
;;; DESIGN.md rule 4: unseen before prettier.  Content the consumer has NEVER seen outranks
;;; refinement of what it already holds.  :gone comes first because a stale row still on screen is
;;; actively misleading, and repairing it is usually cheap.

(defun %priority (d)
  (ecase (delta-kind d)
    (:gone 0)
    (:appeared 1)
    (:moved 2)       ; cheap, and it keeps navigation responsive
    (:changed 3)))

;;; ---- cost is the ENCODING's, because a budget is denominated in the consumer's link -----------
;;;
;;; This used to be a plain function counting 16px macroblocks, and that quietly made rule 4's
;;; budget a PIXEL budget for every consumer in existence.  For a framebuffer that is exactly right —
;;; the thing that gets spent is dirty tiles.  For a consumer whose extents are NIL every delta cost
;;; a flat 1, so `budget` silently degenerated into "N deltas per pass": usable, but it is not the
;;; consumer's unit.  A DOM consumer's budget is BYTES on a data channel and a token consumer's is
;;; tokens, and neither can be derived from a rectangle.
;;;
;;; So the price of a delta is a question asked of the CONSUMER, exactly like LAY-OUT and
;;; APPLY-DELTAS.  Nothing else about rule 4 moves: deferral is still acknowledged-state-lagging,
;;; the drain is still re-derivation, supersession is still by key, and the ordering is still
;;; unseen-before-prettier.  Only the number changes, and only for an encoding that says so.

(defgeneric delta-cost (consumer delta)
  (:documentation "What DELTA costs this CONSUMER, in whatever unit its budget is denominated in.
Macroblocks for a framebuffer, serialized bytes for a browser, tokens for a model.

The default below is the macroblock count of the delta's extent, which is the unit core's OWN
default layout produces (grid-snapped rectangles, DESIGN.md rule 3) — so the default cost and the
default layout agree with each other, and an encoding that lays out in something other than pixels
is the one obliged to say what it is spending."))

(defmethod delta-cost (consumer (d delta))
  (declare (ignore consumer))
  (if (eq (delta-kind d) :moved)
      1                                       ; a translation asserts, it does not re-send content
      (let ((p (delta-presentation d)))
        (if p (presentation-cost p)
            (let ((e (delta-extent d)))        ; :gone — cost of repairing the hole
              (if e (max 1 (* (ceiling (extent-w e) +grid+) (ceiling (extent-h e) +grid+))) 1))))))

;;; ---- emission --------------------------------------------------------------

(defun emit (stream current &key (budget most-positive-fixnum) consumer)
  "Advance STREAM toward CURRENT (a list of presentations) within BUDGET.  Returns
(values deltas deferred-count).  Deltas that do not fit are simply not emitted — the stream's
delivered state does not advance for them, so the next call re-derives them, coalesced with any
newer change.  Nothing to strand.

CONSUMER is who the budget belongs to, and it is here for one reason: a stream and a number cannot
price a delta.  It is optional so that the reconciler stays usable on its own — the harnesses and
the film demo drive EMIT with no consumer at all — and NIL simply selects the default DELTA-COST."
  (let* ((owed (sort (%diff (ds-delivered stream) current) #'< :key #'%priority))
         (spent 0) (emitted '()) (deferred 0))
    (dolist (d owed)
      (let ((cost (delta-cost consumer d)))
        (cond
          ((or (null emitted) (<= (+ spent cost) budget))   ; always make progress on the first
           (incf spent cost)
           (push d emitted)
           ;; advance delivered state ONLY for what we actually sent
           (if (eq (delta-kind d) :gone)
               (remhash (delta-key d) (ds-delivered stream))
               (setf (gethash (delta-key d) (ds-delivered stream)) (delta-presentation d))))
          (t (incf deferred)))))
    (setf (ds-pending-count stream) deferred)
    (values (nreverse emitted) deferred)))

(defun snapshot (stream current &key (budget most-positive-fixnum) consumer)
  "Resync: forget what the consumer was believed to hold and re-announce the whole working set,
chunked by the same budget discipline.  Bumps the generation — DESIGN.md rule 4: snapshot chunks
carry the generation, and deltas older than it must be discarded, which is where key-mismatch bugs
breed.  Returns (values deltas deferred-count generation)."
  (clrhash (ds-delivered stream))
  (incf (ds-generation stream))
  (multiple-value-bind (deltas deferred) (emit stream current :budget budget :consumer consumer)
    (values deltas deferred (ds-generation stream))))
