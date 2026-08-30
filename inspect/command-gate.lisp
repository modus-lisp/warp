;;;; command-gate.lisp — authorization is enforced where it is claimed to be.
;;;;
;;;;     sbcl --load inspect/command-gate.lisp
;;;;
;;;; warp says two things about commands that are only true if the code says them
;;;; too, and both are the kind of claim that decays quietly:
;;;;
;;;;   1. Menu filtering is COURTESY.  APPLICABLE-COMMANDS narrows what a surface
;;;;      offers, and INVOKE re-checks independently — so a surface that offers too
;;;;      much cannot grant anything.  If that ever stops being true, every screen
;;;;      still looks correct, and the only symptom is that a client which sends the
;;;;      command anyway gets to run it.
;;;;
;;;;   2. Declaring a command AGAIN must not drop the authorization attached to it.
;;;;      Load order decides which of DEFINE-COMMAND and DEFINE-COMMAND-AUTHORIZATION
;;;;      runs last, and the failure mode of getting it wrong is silently WIDER
;;;;      access, which no test of the happy path would notice.
;;;;
;;;; Neither needs a screen, a socket or a font.

(require :asdf)
(let ((here (make-pathname :name nil :type nil
                           :defaults (or *load-truename* *compile-file-truename*))))
  (asdf:initialize-source-registry
   `(:source-registry (:tree ,(merge-pathnames "../../" here))
                      (:exclude "vendor") (:exclude "deps") :inherit-configuration)))
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream)))
    (asdf:load-system :warp)))

(in-package #:warp)

(defvar *pass* 0) (defvar *fail* 0)
(defun ok (name got &optional detail)
  (if got (progn (incf *pass*) (format t "  ok   ~a~@[ — ~a~]~%" name detail))
      (progn (incf *fail*) (format t "  FAIL ~a~@[ — ~a~]~%" name detail)))
  (finish-output))

;;; A tiny domain: a document type, and two commands over it.
(defstruct (doc (:conc-name doc-)) name)
(define-presentation-key doc (d) (format nil "doc:~a" (doc-name d)))

(define-command (gate-open :arg-type doc :label "open") (object invoker)
  (declare (ignore invoker)) (list :opened (doc-name object)))

(define-command (gate-delete :arg-type doc :destructive t :confirm t :label "delete")
    (object invoker)
  (declare (ignore invoker)) (list :deleted (doc-name object)))

;; Only an owner may delete.  The predicate lives beside the policy, not the UI.
(define-command-authorization gate-delete (invoker) (eq invoker :owner))

(defparameter *d* (make-doc :name "notes"))

(format t "~&== what a menu offers ==~%")
(let ((for-owner   (mapcar #'cmd-name (applicable-commands 'doc :invoker :owner)))
      (for-stranger (mapcar #'cmd-name (applicable-commands 'doc :invoker :stranger))))
  (ok "the owner is offered the destructive command"
      (member 'gate-delete for-owner) (format nil "~a" for-owner))
  (ok "a stranger is not" (not (member 'gate-delete for-stranger))
      (format nil "~a" for-stranger))
  (ok "…but is still offered the harmless one" (member 'gate-open for-stranger)))

(format t "~&== and what INVOKE allows, which is the part that matters ==~%")
;; The whole claim: a client that never saw the menu, and simply sends the command.
(ok "a stranger invoking directly is refused"
    (handler-case (progn (invoke 'gate-delete *d* :stranger :confirmed t) nil)
      (command-refused (c) (search "not authorized" (or (refused-reason c) ""))))
    "COMMAND-REFUSED: not authorized")
(ok "the owner may run it, given confirmation"
    (equal (invoke 'gate-delete *d* :owner :confirmed t) '(:deleted "notes")))
;; Confirmation is enforced in the same place, for the same reason.
(ok "…and not without it"
    (handler-case (progn (invoke 'gate-delete *d* :owner) nil)
      (command-refused (c) (search "confirmation" (or (refused-reason c) "")))))
(ok "an unauthorized command needs no confirmation to be refused"
    (handler-case (progn (invoke 'gate-delete *d* :stranger) nil)
      (command-refused (c) (search "not authorized" (or (refused-reason c) ""))))
    "authorization is checked before confirmation")

(format t "~&== redeclaring a command keeps its policy ==~%")
;; DEFINE-COMMAND again, as a reload would do.  The authorization must survive it.
(define-command (gate-delete :arg-type doc :destructive t :confirm t :label "delete")
    (object invoker)
  (declare (ignore invoker)) (list :deleted-again (doc-name object)))
(ok "the authorization predicate is still attached after redefinition"
    (handler-case (progn (invoke 'gate-delete *d* :stranger :confirmed t) nil)
      (command-refused () t))
    "a reload must not widen access")

(format t "~&== geometry is priced in 16px macroblocks ==~%")
(ok "a 16x16 extent is one block"
    (= (p-macroblocks (make-presentation :extent '(0 0 16 16))) 1))
(ok "33x16 rounds UP to three across, not two"
    (= (p-macroblocks (make-presentation :extent '(0 0 33 16))) 3)
    "ceiling, because a partly covered block is still sent")
(ok "32x32 is four" (= (p-macroblocks (make-presentation :extent '(0 0 32 32))) 4))
(ok "a zero-sized extent still costs one, not zero"
    (= (p-macroblocks (make-presentation :extent '(0 0 0 0))) 1))
(ok "and something that is not a rectangle costs one rather than guessing"
    (= (p-macroblocks (make-presentation :extent nil)) 1))

(format t "~&~%~d passed, ~d failed~%" *pass* *fail*)
(finish-output)
(sb-ext:exit :code (if (plusp *fail*) 1 0))
