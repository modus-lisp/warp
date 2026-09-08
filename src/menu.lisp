;;;; menu.lisp — the hold menu, and what a recognized gesture means.
;;;;
;;;; DESIGN.md rules 5 and 6 are warp concepts, not glass ones: `hold` opens the applicable-command
;;;; menu, `tap` invokes the declared default, destructive commands are hold-menu only and confirm
;;;; before they run, and invocation is the single enforcement point.  None of that is about pixels,
;;;; and a DOM consumer that skipped it would have to reimplement the safety rules — which is exactly
;;;; the "second enforcement point someone later trusts" that rule 6 refuses.
;;;;
;;;; So the split runs along the same line rule 8 draws everywhere else:
;;;;
;;;;   core     the menu MODEL — what a menu is, what is on it, what tapping an item does.  Items
;;;;            are ordinary presentations, so opening a menu emits :appeared, closing emits :gone,
;;;;            and the reconciler needs no special case.
;;;;   encoding MEASUREMENT and PLACEMENT — how wide a menu is, where it sits, and how it is drawn.
;;;;            The default here gives items NO extents: the model travels, and an encoding that has
;;;;            a geometry says so by specialising MENU-PRESENTATIONS.
;;;;
;;;; Likewise recognition: rule 5 puts gesture recognition at the edge and carries (gesture, x, y) on
;;;; the wire.  Turning (x, y) into a presentation is the encoding's job — glass hit-tests pixels, a
;;;; browser would send back the key it already has — but what the gesture MEANS once it has landed
;;;; on a presentation is one rule for every consumer, and it is ON-GESTURE below.

(in-package #:warp)

(defstruct (menu-item (:conc-name mi-))
  kind        ; :command | :confirm | :cancel | :choice
  command     ; the COMMAND object (nil for :cancel)
  target      ; the domain object it would act on
  ;; ---- for :choice, the picker's half -------------------------------------------------
  value       ; the value this item would set
  vlabel      ; how to write it
  (live nil)) ; T when it is what is set now

(define-presentation-key menu-item (m)
  ;; A CHOICE'S KEY CARRIES ITS VALUE, because a picker puts several items on one menu for one
  ;; command and they must not collide.  The plain case is unchanged, which matters: PROTOCOL.md
  ;; documents `menu:<kind>:<command|cancel>' and every existing client keys on it.
  (format nil "menu:~(~a~):~a~@[:~a~]" (mi-kind m)
          (if (mi-command m) (cmd-name (mi-command m)) "cancel")
          (and (eq (mi-kind m) :choice) (mi-vlabel m))))

(defmethod present ((m menu-item) (type (eql 'menu-item)) view)
  (declare (ignorable view))
  (let ((c (mi-command m)))
    (ecase (mi-kind m)
      (:command (list (cmd-label c) (cmd-cost c)
                      (if (cmd-destructive c) :destructive :safe)))
      ;; A CHOICE READS AS THE VALUE, not as the command: on a menu of measures the items are
      ;; "amount" and "orders", not "measure: amount" twice.  The command's label is on the
      ;; CONTROL that opened the menu, which is where the question belongs.
      ;;
      ;; WHICH ONE IS LIVE IS NOT A CELL.  It was, for one commit -- :LIVE in the COST slot --
      ;; and that is precisely the overloading the widget declarations exist to end: a slot
      ;; whose meaning depends on what is in it.  Live-ness is not part of the choice's content,
      ;; it is this consumer's view of it, which is what P-STATE is for (rule 7) and is
      ;; EQUAL-compared exactly like a fingerprint.
      (:choice  (list (mi-vlabel m) (cmd-cost c) :safe))
      (:confirm (list (format nil "really ~a?" (cmd-label c)) :confirm :destructive))
      (:cancel  (list "cancel" nil :safe)))))

;;; A menu belongs to the CONSUMER, not the projection: it is the hold gesture of one particular
;;; finger, listing what one particular invoker may run.  Two people looking at the same list can
;;; have two menus open on two different rows.

(defmethod menu-presentations ((c consumer))
  "The encoding-neutral menu: the items, as presentations, with NO extents.

An extent is a claim about a geometry, and core has none to make — the reconciler already tolerates
a NIL extent (it costs one unit and can never be a :moved), so the menu still travels as ordinary
budgeted deltas and a browser or a model places it however it places anything else."
  (let ((m (consumer-menu c)))
    (when m
      (destructuring-bind (&key target items) m
        (declare (ignore target))
        (loop for it in items
              collect (let ((p (make-presentation
                                :key (presentation-key 'menu-item it)
                                :type 'menu-item :object it
                                :extent nil
                                :fingerprint (present it 'menu-item (consumer-view c))
                                :as-of (now-tick))))
                        ;; Rule 7: this consumer's view state, on this consumer's presentation.
                        ;; Two seats holding the same menu can disagree about which value is
                        ;; live if they are looking at different objects, and neither is told
                        ;; about the other's.
                        (when (mi-live it) (setf (p-state p) (list :live t)))
                        p))))))

(defun %items-for (cmd object)
  "One menu item for a verb; one per choice for a picker.

THIS IS THE WHOLE OF THE MANIPULATIVE CORE AT THE MENU LAYER.  A parameter does not need a new
gesture, a new delta kind or a coordinate -- it needs the menu that HOLD already opens to list
values instead of verbs, and rule 5's tap to carry the one that was tapped."
  (let ((choices (command-values cmd object)))
    (if (null choices)
        (list (make-menu-item :kind :command :command cmd :target object))
        (let ((now (command-current cmd object)))
          (loop for (v . label) in choices
                collect (make-menu-item :kind :choice :command cmd :target object
                                        :value v
                                        :vlabel (or label (format nil "~a" v))
                                        :live (and now (equal now v))))))))

(defun open-menu (c target commands)
  "Rule 5: hold lists the applicable commands.  TARGET is the presentation held, kept because an
encoding will want to place the menu relative to it."
  (setf (consumer-menu c)
        (list :target target
              :items (append (loop for cmd in commands
                                   append (%items-for cmd (p-object target)))
                             (list (make-menu-item :kind :cancel))))))

(defun confirm-menu (c target command)
  "Replace the menu with a confirmation.  Rule 6: irreversible commands do not run on one tap."
  (setf (consumer-menu c)
        (list :target target
              :items (list (make-menu-item :kind :confirm :command command :target (p-object target))
                           (make-menu-item :kind :cancel)))))

(defun close-menu (c) (setf (consumer-menu c) nil))

;;; ---- invocation: the surface never second-guesses the policy -------------------

(defun run-command (c command object &key confirmed (value nil value-p))
  "Invoke, and let warp refuse.  The consumer only reports.
The invoker is the CONSUMER's, so an owner and a guest over one projection get different answers
here, and rule 6 is unchanged: this is the enforcement point, the menu was courtesy."
  (handler-case
      (let ((r (if value-p
                   (invoke (cmd-name command) object (consumer-invoker c)
                           :confirmed confirmed :value value)
                   (invoke (cmd-name command) object (consumer-invoker c)
                           :confirmed confirmed))))
        (setf (consumer-last-result c) r)
        r)
    (command-refused (e)
      (setf (consumer-last-result c) (list :refused (refused-reason e)))
      (format *error-output* "~&[warp] ~a~%" e)
      (finish-output *error-output*)
      nil)))

;;; ---- what a gesture means -----------------------------------------------------

(defun on-gesture (c gesture p)
  "Apply a RECOGNIZED gesture to the presentation it landed on.  GESTURE is one of the closed enum
of rule 5 (:tap, :hold, NIL for none); P is the presentation under it, or NIL for empty space.

Everything this touches — the menu, the selection, the invoker the gesture is resolved against — is
this consumer's.  Another consumer over the same projection is not disturbed by any of it.

Resolving (x, y) to P is deliberately NOT here: that is the encoding's, because only the encoding
knows what its coordinates mean."
  (when gesture
    (cond
      ;; nothing under the finger: a tap dismisses any open menu
      ((null p) (when (eq gesture :tap) (close-menu c)))
      ;; a tap on a menu row
      ((eq (p-type p) 'menu-item)
       (when (eq gesture :tap)
         (let ((it (p-object p)))
           (ecase (mi-kind it)
             (:cancel (close-menu c))
             (:command
              (let ((cmd (mi-command it)))
                ;; destructive commands get a confirmation step rather than running
                (if (cmd-confirm cmd)
                    (confirm-menu c (getf (consumer-menu c) :target) cmd)
                    (progn (run-command c cmd (mi-target it)) (close-menu c)))))
             ;; A CHOICE CARRIES ITS VALUE, and closes the menu like any other tap.  There is
             ;; no confirmation step: a picker sets a parameter, and setting one is reversible
             ;; by setting it again -- which is rule 6's actual test, not a category of command.
             (:choice
              (run-command c (mi-command it) (mi-target it) :value (mi-value it))
              (close-menu c))
             (:confirm
              (run-command c (mi-command it) (mi-target it) :confirmed t)
              (close-menu c))))))
      ;; a tap or hold on content
      (t
       (multiple-value-bind (kind payload)
           (gesture-command gesture (p-type p) (consumer-view c) :invoker (consumer-invoker c))
         (case kind
           (:invoke
            (close-menu c)
            (setf (consumer-selected c) (p-key p))
            (run-command c payload (p-object p)))
           (:menu (open-menu c p payload))
           (t nil)))))))
