;;;; glass/surface.lisp — warp's glass surface: deltas become framebuffer writes.
;;;;
;;;; This is the encoding half.  The delta stream decides WHAT travels; this decides how it lands in
;;;; pixels.  The important discipline is that a pass paints ONLY the extents the stream emitted —
;;;; never the whole view — because glass discovers damage by diffing tiles against its snapshot and
;;;; ships the dirty ones.  So glass independently CHECKS warp: if the reconciler is right, the tiles
;;;; glass finds dirty are the extents warp emitted, and nothing else.
;;;;
;;;; Input is the interim mapping.  DESIGN.md rule 5 wants semantic gestures recognized on the phone
;;;; and carried on the wire; today the client flattens them into RFB pointer events, so until that
;;;; protocol change lands: button 1 = tap, button 3 = hold (the menu).  Recognition still happens at
;;;; the edge — we are just receiving it in a lossy encoding.

(in-package #:warp-glass)

(defparameter +bg+     #x0c0e12)
(defparameter +row-bg+ #x161a20)
(defparameter +row-sel+ #x26303c)
(defparameter +fg+     #xdce4ec)
(defparameter +dim+    #x8a949c)
(defparameter +ok+     #x5abe82)
(defparameter +warn+   #xfabe3c)
(defparameter +bad+    #xf04646)

(defun trend-colour (trend)
  (case trend (:bad +bad+) (:warn +warn+) (t +ok+)))

;;; ---- text on a baseline -----------------------------------------------------
;;; GLASS:FB-TEXT positions a string by its TOP-LEFT, so a SIZE-px line drawn at Y occupies
;;; Y..Y+SIZE.  Two consequences bit the monitor, and the second is not cosmetic:
;;;
;;;   * two different sizes positioned by their tops do NOT share a baseline, which reads as the
;;;     smaller label floating above the value it labels;
;;;   * a line whose box is taller than the room left in the row OVERFLOWS INTO THE NEIGHBOUR — and
;;;     that is warp painting outside the extent it declared.  The reconciler told the consumer which
;;;     rectangles changed; glass then finds dirty tiles outside every one of them.  The invariant
;;;     this file's header claims (glass independently checks warp) is exactly what breaks.  The
;;;     visible symptom is the descender vanishing when the row below is next painted over it.
;;;
;;; So: position by baseline, and derive the baseline from the row.

(defun text-ascent (size &optional (font (glass:default-font)))
  "Pixels from the top of a SIZE-px text box down to its baseline."
  (round (* (scribe:font-ascent font) size) (scribe:font-units-per-em font)))

(defun fb-text-baseline (fb x baseline string &key (size 13) (color +fg+))
  "Draw STRING with its BASELINE at that y.  Use this, not FB-TEXT, wherever text shares a line."
  (glass:fb-text fb x (- baseline (text-ascent size)) string :size size :color color))

(defun row-baseline (y h size)
  "A baseline that vertically centres a SIZE-px line in the row of height H starting at Y.
Centres the em box, which keeps the whole line inside the row — the point being that the row, not
the glyph, owns the space."
  (+ y (floor (- h size) 2) (text-ascent size)))

;;; ---- painting --------------------------------------------------------------
;;; PAINT is the counterpart of PRESENT: present decides what a thing says, paint decides how it
;;; looks.  Keeping them apart is what lets the content double as the fingerprint.

(defgeneric paint (fb presentation view)
  (:documentation "Draw PRESENTATION into FB.  Called only for extents the delta stream emitted."))

(defmethod paint (fb p view)
  "Default: the content lines, small and plain — the visual counterpart of the MOP slot walk."
  (declare (ignorable view))
  (let* ((e (warp:p-extent p)) (x (warp::extent-x e)) (y (warp::extent-y e))
         (w (warp::extent-w e)) (h (warp::extent-h e)))
    (glass:fb-rect fb x y w h +row-bg+)
    ;; stop when the NEXT line would not fit entirely, so the default never paints past the extent
    (loop for line in (warp:p-fingerprint p)
          for i from 0
          for top = (+ 2 (* i 12))
          while (<= (+ top 11) h)
          do (fb-text-baseline fb (+ x 8) (+ y top (text-ascent 11)) (princ-to-string line)
                               :size 11 :color +fg+))))

(defun clear-extent (fb e)
  (glass:fb-rect fb (warp::extent-x e) (warp::extent-y e)
                 (warp::extent-w e) (warp::extent-h e) +bg+))


;;; ---- menus are presentations too --------------------------------------------
;;; Rule 7 says view state is presentations, keyed like everything else.  A menu is exactly that: a
;;; transient overlay whose rows are commands.  Which means it needs no special painting path, no
;;; separate damage accounting, and no extra code in the reconciler — opening a menu emits :appeared
;;; for its items, closing emits :gone, and the damage is bounded to the menu itself.

(defstruct (menu-item (:conc-name mi-))
  kind        ; :command | :confirm | :cancel
  command     ; the COMMAND object (nil for :cancel)
  target)     ; the domain object it would act on

(warp:define-presentation-key menu-item (m)
  (format nil "menu:~(~a~):~a" (mi-kind m)
          (if (mi-command m) (warp:cmd-name (mi-command m)) "cancel")))

(defmethod warp:present ((m menu-item) (type (eql 'menu-item)) view)
  (declare (ignorable view))
  (let ((c (mi-command m)))
    (ecase (mi-kind m)
      (:command (list (warp:cmd-label c) (warp:cmd-cost c)
                      (if (warp:cmd-destructive c) :destructive :safe)))
      (:confirm (list (format nil "really ~a?" (warp:cmd-label c)) :confirm :destructive))
      (:cancel  (list "cancel" nil :safe)))))

(defparameter +menu-w+ 224)
(defparameter +menu-row+ 32)

(defun menu-presentations (sf)
  "Lay the open menu out beneath its target row, as ordinary presentations."
  (let ((m (sf-menu sf)))
    (when m
      (destructuring-bind (&key target items) m
        (let* ((te (warp:p-extent target))
               (x (min (warp::extent-x te)
                       (max 0 (- (glass:fb-width (sf-fb sf)) +menu-w+))))
               (y0 (+ (warp::extent-y te) (warp::extent-h te))))
          (loop for it in items
                for i from 0
                for y = (+ y0 (* i +menu-row+))
                collect (warp:make-presentation
                         :key (warp:presentation-key 'menu-item it)
                         :type 'menu-item :object it
                         :extent (warp:snap-extent x y +menu-w+ +menu-row+)
                         :fingerprint (warp:present it 'menu-item (sf-view sf))
                         :as-of (warp:now-tick))))))))

(defun open-menu (sf target commands)
  (setf (sf-menu sf)
        (list :target target
              :items (append (mapcar (lambda (c) (make-menu-item :kind :command :command c
                                                                 :target (warp:p-object target)))
                                     commands)
                             (list (make-menu-item :kind :cancel))))))

(defun confirm-menu (sf target command)
  "Replace the menu with a confirmation.  Rule 6: irreversible commands do not run on one tap."
  (setf (sf-menu sf)
        (list :target target
              :items (list (make-menu-item :kind :confirm :command command
                                           :target (warp:p-object target))
                           (make-menu-item :kind :cancel)))))

(defun close-menu (sf) (setf (sf-menu sf) nil))

;;; ---- the surface -----------------------------------------------------------

(defstruct (surface (:conc-name sf-))
  fb port name view
  rows-fn                       ; () -> the current result-set (presentations)
  (stream (warp:make-delta-stream))
  (visible '())                 ; last emitted set, for hit-testing
  (menu nil)                    ; (:target presentation :items (menu-item ...)) or NIL
  (selected nil)
  (budget 400)
  (invoker :allowlist)
  (lock (bt:make-lock))
  (last-result nil)
  (painted 0) (emitted 0) (passes 0)
  (stop nil))

(defun hit (sf x y)
  "The presentation under (X,Y), or NIL.  Reverse order so the topmost wins."
  (find-if (lambda (p)
             (let ((e (warp:p-extent p)))
               (and e (<= (warp::extent-x e) x (+ (warp::extent-x e) (warp::extent-w e) -1))
                    (<= (warp::extent-y e) y (+ (warp::extent-y e) (warp::extent-h e) -1)))))
           (reverse (sf-visible sf))))

(defun apply-deltas (sf deltas)
  "Paint exactly what the stream emitted, and nothing else."
  (let ((fb (sf-fb sf)))
    (glass:with-fb-locked (fb)
      (dolist (d deltas)
        (ecase (warp:delta-kind d)
          ((:appeared :changed)
           (paint fb (warp:delta-presentation d) (sf-view sf))
           (incf (sf-painted sf)))
          (:moved
           ;; No blit yet: repaint at the new extent and clear where it came from.  The :moved KIND
           ;; is still the right thing to carry — it is what a CopyRect or a motion vector will use
           ;; once the encoder can see a translation (DESIGN.md rule 2).
           (let* ((p (warp:delta-presentation d)) (e (warp:p-extent p)))
             (clear-extent fb (list (- (warp::extent-x e) (warp:delta-dx d))
                                    (- (warp::extent-y e) (warp:delta-dy d))
                                    (warp::extent-w e) (warp::extent-h e)))
             (paint fb p (sf-view sf))
             (incf (sf-painted sf))))
          (:gone
           (clear-extent fb (warp:delta-extent d))
           (incf (sf-painted sf))))))))

(defun tick (sf)
  "One pass: recompute the result-set, emit what is owed under budget, paint only that."
  (bt:with-lock-held ((sf-lock sf))
    (let ((rows (append (funcall (sf-rows-fn sf)) (menu-presentations sf))))
      (multiple-value-bind (deltas deferred) (warp:emit (sf-stream sf) rows :budget (sf-budget sf))
        (declare (ignore deferred))
        (incf (sf-passes sf))
        (incf (sf-emitted sf) (length deltas))
        (setf (sf-visible sf) rows)
        (when deltas (apply-deltas sf deltas))
        deltas))))

(defun on-pointer (sf mask x y)
  "Interim gesture mapping (see the file header): button 1 = tap, button 3 = hold."
  (let* ((gesture (cond ((logtest mask 1) :tap) ((logtest mask 4) :hold) (t nil)))
         (p (and gesture (hit sf x y))))
    (when gesture
      (cond
        ;; nothing under the finger: a tap dismisses any open menu
        ((null p) (when (eq gesture :tap) (close-menu sf)))
        ;; a tap on a menu row
        ((eq (warp:p-type p) 'menu-item)
         (when (eq gesture :tap)
           (let ((it (warp:p-object p)))
             (ecase (mi-kind it)
               (:cancel (close-menu sf))
               (:command
                (let ((c (mi-command it)))
                  ;; destructive commands get a confirmation step rather than running
                  (if (warp:cmd-confirm c)
                      (confirm-menu sf (getf (sf-menu sf) :target) c)
                      (progn (run-command sf c (mi-target it)) (close-menu sf)))))
               (:confirm
                (run-command sf (mi-command it) (mi-target it) :confirmed t)
                (close-menu sf))))))
        ;; a tap or hold on content
        (t
         (multiple-value-bind (kind payload)
             (warp:gesture-command gesture (warp:p-type p) (sf-view sf) :invoker (sf-invoker sf))
           (case kind
             (:invoke
              (close-menu sf)
              (setf (sf-selected sf) (warp:p-key p))
              (run-command sf payload (warp:p-object p)))
             (:menu (open-menu sf p payload))
             (t nil))))))))

(defun run-command (sf command object &key confirmed)
  "Invoke, and let warp refuse.  The surface never second-guesses the policy — it only reports."
  (handler-case
      (let ((r (warp:invoke (warp:cmd-name command) object (sf-invoker sf) :confirmed confirmed)))
        (setf (sf-last-result sf) r)
        r)
    (warp:command-refused (c)
      (setf (sf-last-result sf) (list :refused (warp:refused-reason c)))
      (format *error-output* "~&[warp] ~a~%" c)
      (finish-output *error-output*)
      nil)))

(defun make-surface-app (fb &key view rows-fn (budget 400) (invoker :allowlist))
  "The WM surface contract: given a framebuffer, return (values ON-KEY ON-POINTER DIRTY-P).
DIRTY-P is a warp pass — recompute the result-set, emit what is owed, paint only that, and report
whether anything changed.  This is how warp becomes a window in the glass desktop rather than a
separate server: the WM owns the framebuffer, decorates and composites it, and knows nothing about
presentations."
  (let ((sf (make-surface :fb fb :view view :rows-fn rows-fn :budget budget :invoker invoker)))
    (glass:with-fb-locked (fb) (glass:fb-fill fb +bg+))
    (values
     ;; on-key: Escape dismisses an open menu, which is the only key this surface needs yet
     (lambda (down keysym)
       (when (and down (= keysym #xff1b) (sf-menu sf)) (close-menu sf) t))
     (lambda (mask x y) (on-pointer sf mask x y))
     ;; dirty-p: the WM polls this; a pass returns non-nil exactly when it painted
     (lambda () (and (tick sf) t))
     sf)))

(defun run (&key (port 5910) (width 480) (height 448) (name "warp") view rows-fn
                 (hz 4) (budget 400) (invoker :allowlist))
  "Serve a warp surface over RFB on PORT.  Returns the SURFACE; the paint loop and the RFB server
each run on their own thread."
  (let* ((fb (glass:make-framebuffer width height +bg+))
         (sf (make-surface :fb fb :port port :name name :view view :rows-fn rows-fn
                           :budget budget :invoker invoker)))
    (bt:make-thread
     (lambda ()
       (handler-case
           (glass:serve fb port :name name
                        :on-pointer (lambda (mask x y) (on-pointer sf mask x y)))
         (error (e) (format *error-output* "~&[warp] serve: ~a~%" e))))
     :name "warp-rfb")
    (bt:make-thread
     (lambda ()
       (loop until (sf-stop sf) do
         (handler-case (tick sf)
           (error (e) (format *error-output* "~&[warp] tick: ~a~%" e)))
         (sleep (/ 1.0 hz))))
     :name "warp-paint")
    sf))
