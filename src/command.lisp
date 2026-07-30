;;;; command.lisp — commands are objects declared against presentation TYPES, not wired to widgets.
;;;;
;;;; This is the layer that makes the payoff real: one command set serves the DM interface, a CLI,
;;;; the glass GUI, and an agent, with the authorization predicate written ONCE.  Today the gateway's
;;;; `revoke` exists once and is authorization-checked once; a GUI that reimplemented it would
;;;; duplicate both the logic and the check, and the two would drift.
;;;;
;;;; Safety properties live on the command, where no view can override them (DESIGN.md rule 6):
;;;;
;;;;   * DESTRUCTIVE commands can never be a tap default; they are hold-menu only.
;;;;   * CONFIRM commands refuse to run until confirmation is passed explicitly.
;;;;   * AUTHORIZE is enforced at INVOCATION.  Menu filtering is courtesy, not security — a surface
;;;;     that offers a command it should not have offered still cannot invoke it.
;;;;
;;;; Those same properties read as lint on model-authored views: generate the seeing, never the
;;;; permitting.

(in-package #:warp)

(defstruct (command (:conc-name cmd-))
  name                    ; a symbol
  (arg-type nil)          ; the presentation type this applies to
  (handler nil)           ; (lambda (object invoker) ...)
  (authorize nil)         ; (lambda (invoker) ...) -> generalized boolean; NIL means "anyone"
  (destructive nil)       ; may not be a default; hold-menu only
  (confirm nil)           ; irreversible: refuses without :confirmed t
  (cost :local)           ; :local | :gateway | :network — scheduling data for any consumer
  (label nil))

(defvar *commands* (make-hash-table :test 'eq))          ; name -> command
(defvar *defaults* (make-hash-table :test 'equal))       ; (type . view) -> command name

(defmacro define-command ((name &key arg-type (cost :local) destructive confirm label)
                          (object invoker) &body body)
  "Declare a command against a presentation type.  BODY is the handler; AUTHORIZE is attached
separately with DEFINE-COMMAND-AUTHORIZATION so the predicate can live next to the policy it
enforces rather than next to the UI."
  `(let ((existing (gethash ',name *commands*)))
     (setf (gethash ',name *commands*)
           (make-command :name ',name :arg-type ',arg-type :cost ,cost
                         :destructive ,destructive :confirm ,confirm
                         :label ,(or label (string-downcase (symbol-name name)))
                         ;; keep any authorization already declared, so load order does not silently
                         ;; drop a policy and widen access
                         :authorize (and existing (cmd-authorize existing))
                         :handler (lambda (,object ,invoker)
                                    (declare (ignorable ,object ,invoker))
                                    ,@body)))
     ',name))

(defmacro define-command-authorization (name (invoker) &body body)
  "Attach the authorization predicate for NAME.  Enforced at invocation, on every surface."
  `(let ((c (or (gethash ',name *commands*)
                (error "warp: no such command ~s" ',name))))
     (setf (cmd-authorize c) (lambda (,invoker) (declare (ignorable ,invoker)) ,@body))
     ',name))

(defun find-command (name)
  (or (gethash name *commands*) (error "warp: no such command ~s" name)))

;;; ---- defaults are declared, never derived ----------------------------------
;;; Deriving a default from "most specific applicable" is the seed of translator-creep: the moment
;;; ordering gets clever we have rebuilt the machinery we refused.  And a derived default can become
;;; destructive without anyone editing a UI.

(defun define-default-command (type view name)
  "Declare the command TAP invokes for (TYPE, VIEW).  Signals if it is destructive — a mis-tap on a
phone must not be able to destroy anything, so this is rejected at declaration rather than trusted
to a reviewer."
  (let ((c (find-command name)))
    (when (cmd-destructive c)
      (error "warp: ~s is destructive and cannot be a tap default for (~s ~s).~@
              Destructive commands are reachable only through the hold menu — DESIGN.md rule 6."
             name type view))
    (setf (gethash (cons type view) *defaults*) name)))

(defun default-command (type view)
  (let ((name (gethash (cons type view) *defaults*)))
    (and name (find-command name))))

;;; ---- applicability ---------------------------------------------------------
;;; One flat rule: a command applies to a presentation whose type matches its ARG-TYPE.  No
;;; translators, no nested input contexts, no chained matching.

(defun applicable-commands (type &key invoker (authorized-only t))
  "Commands applicable to presentations of TYPE.  With INVOKER and AUTHORIZED-ONLY, filters to what
that invoker may actually run — for MENU DISPLAY.  This is courtesy: INVOKE re-checks independently,
so a surface that offers too much cannot grant anything."
  (let ((out '()))
    (maphash (lambda (name c)
               (declare (ignore name))
               (when (and (eq (cmd-arg-type c) type)
                          (or (not authorized-only)
                              (null (cmd-authorize c))
                              (funcall (cmd-authorize c) invoker)))
                 (push c out)))
             *commands*)
    ;; stable order so a menu does not reshuffle under the finger between renders
    (sort out #'string< :key (lambda (c) (string (cmd-name c))))))

;;; ---- invocation: the one enforcement point ---------------------------------

(define-condition command-refused (error)
  ((command :initarg :command :reader refused-command)
   (reason  :initarg :reason  :reader refused-reason))
  (:report (lambda (c s)
             (format s "warp: refused ~s — ~a"
                     (cmd-name (refused-command c)) (refused-reason c)))))

(defun invoke (name object invoker &key confirmed)
  "Run a command.  Authorization is checked HERE, regardless of which surface asked and regardless
of what any menu displayed.  Returns the handler's value, or signals COMMAND-REFUSED."
  (let ((c (find-command name)))
    (when (and (cmd-authorize c) (not (funcall (cmd-authorize c) invoker)))
      (error 'command-refused :command c :reason "not authorized"))
    (when (and (cmd-confirm c) (not confirmed))
      (error 'command-refused :command c :reason "irreversible; needs confirmation"))
    (funcall (cmd-handler c) object invoker)))

;;; ---- gestures -> commands --------------------------------------------------
;;; The closed enum from DESIGN.md rule 5.  Recognition happens on the client; the server only maps.

(defun gesture-command (gesture type view &key invoker)
  "What GESTURE means for a presentation of TYPE in VIEW.  Returns (values kind payload):
  (:invoke command)  — tap resolved to the declared default
  (:menu commands)   — hold resolved to the applicable list (filtered for display only)
  (:pass nil)        — nothing declared; the surface may do as it likes (e.g. scroll)"
  (ecase gesture
    (:tap (let ((c (default-command type view)))
            (if c (values :invoke c) (values :pass nil))))
    (:hold (let ((cs (applicable-commands type :invoker invoker)))
             (if cs (values :menu cs) (values :pass nil))))
    (:two-finger (values :pass nil))))
