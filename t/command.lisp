;;;; t/command.lisp — one command set, several surfaces, authorization written once.
;;;;
;;;; Uses the REAL enrolment command set (the gateway's link / devices / revoke) so this tests the
;;;; design's central claim rather than a toy: the same declarations serve a menu, a CLI and an
;;;; agent, and the safety properties cannot be talked out of by any of them.

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream))) (asdf:load-system :warp)))

(defpackage #:warp-cmd-test (:use #:cl #:warp))
(in-package #:warp-cmd-test)

(defvar *fails* 0)
(defun ok (name pred)
  (format t "~&  ~:[FAIL~;ok  ~] ~a~%" pred name)
  (unless pred (incf *fails*)))

;;; ---- the domain, as the gateway actually has it -----------------------------

(defstruct (enrol (:constructor enrol (pubkey exp))) pubkey exp)
(define-presentation-key enrolment (e) (enrol-pubkey e))

;;; invokers: the box's own npub (allowlist, permanent) vs an enrolled terminal (24h, bearer)
(defstruct invoker kind)
(defvar *admin*  (make-invoker :kind :allowlist))
(defvar *device* (make-invoker :kind :device))
(defvar *nobody* (make-invoker :kind :none))

(defvar *revoked* '())

(define-command (inspect-enrolment :arg-type enrolment :cost :local :label "inspect")
    (object invoker)
  (list :inspected (enrol-pubkey object)))

(define-command (revoke-enrolment :arg-type enrolment :cost :gateway
                                  :destructive t :confirm t :label "revoke")
    (object invoker)
  (push (enrol-pubkey object) *revoked*)
  (list :revoked (enrol-pubkey object)))

(define-command (fresh-link :arg-type enrolment :cost :network :label "link")
    (object invoker)
  (list :link (enrol-pubkey object)))

;;; the policy, written once, next to the thing it protects
(define-command-authorization revoke-enrolment (i) (eq (invoker-kind i) :allowlist))
(define-command-authorization fresh-link (i) (member (invoker-kind i) '(:allowlist :device)))

(define-default-command 'enrolment 'list-view 'inspect-enrolment)

(defun names (cs) (sort (mapcar (lambda (c) (string (cmd-name c))) cs) #'string<))

(format t "~&== a destructive command cannot be declared as a tap default ==~%")
(ok "declaring revoke as the default signals at declaration time"
    (handler-case (progn (define-default-command 'enrolment 'list-view 'revoke-enrolment) nil)
      (error () t)))
(ok "and the safe default is still in place"
    (eq 'inspect-enrolment (cmd-name (default-command 'enrolment 'list-view))))

(format t "~&== menus differ by invoker (courtesy filtering) ==~%")
(ok "allowlist sees all three"
    (equal '("FRESH-LINK" "INSPECT-ENROLMENT" "REVOKE-ENROLMENT")
           (names (applicable-commands 'enrolment :invoker *admin*))))
(ok "an enrolled device does NOT see revoke"
    (equal '("FRESH-LINK" "INSPECT-ENROLMENT")
           (names (applicable-commands 'enrolment :invoker *device*))))
(ok "an unknown invoker sees only what needs no authorization"
    (equal '("INSPECT-ENROLMENT") (names (applicable-commands 'enrolment :invoker *nobody*))))

(format t "~&== menu filtering is COURTESY; invocation is the enforcement point ==~%")
(let ((e (enrol "aa11" 999)))
  ;; a surface that wrongly offers revoke to a device — a GUI bug, or a malicious client — still
  ;; cannot make it happen.  This is the assertion that keeps the GUI from becoming a second
  ;; enforcement point that someone later trusts.
  (ok "a device invoking revoke directly is refused"
      (handler-case (progn (invoke 'revoke-enrolment e *device* :confirmed t) nil)
        (command-refused (c) (string= "not authorized" (refused-reason c)))))
  (ok "and nothing was revoked as a side effect" (null *revoked*))
  (ok "the allowlist may revoke, with confirmation"
      (equal '(:revoked "aa11") (invoke 'revoke-enrolment e *admin* :confirmed t))))

(format t "~&== irreversible commands refuse to run unconfirmed ==~%")
(let ((e (enrol "bb22" 999)))
  (ok "unconfirmed revoke is refused even for the allowlist"
      (handler-case (progn (invoke 'revoke-enrolment e *admin*) nil)
        (command-refused (c) (search "confirmation" (refused-reason c)))))
  (ok "and it did not happen" (not (member "bb22" *revoked* :test #'string=))))

(format t "~&== gestures resolve through the closed enum ==~%")
(multiple-value-bind (kind payload) (gesture-command :tap 'enrolment 'list-view :invoker *admin*)
  (ok "tap -> invoke the declared safe default"
      (and (eq kind :invoke) (eq 'inspect-enrolment (cmd-name payload)))))
(multiple-value-bind (kind payload) (gesture-command :hold 'enrolment 'list-view :invoker *device*)
  (ok "hold -> menu, already filtered for this invoker"
      (and (eq kind :menu) (equal '("FRESH-LINK" "INSPECT-ENROLMENT") (names payload)))))
(multiple-value-bind (kind) (gesture-command :two-finger 'enrolment 'list-view :invoker *admin*)
  (ok "two-finger -> pass (the surface scrolls)" (eq kind :pass)))
(multiple-value-bind (kind) (gesture-command :tap 'unknown-type 'list-view :invoker *admin*)
  (ok "tap on a type with no declared default -> pass, never a guess" (eq kind :pass)))

(format t "~&== cost class travels with the command (scheduling data) ==~%")
(ok "inspect is local, revoke a gateway round trip, link a network one"
    (and (eq :local   (cmd-cost (find-command 'inspect-enrolment)))
         (eq :gateway (cmd-cost (find-command 'revoke-enrolment)))
         (eq :network (cmd-cost (find-command 'fresh-link)))))

(format t "~&== redefining a command does not silently drop its policy ==~%")
;; reloading a file must not widen access: the authorization survives the handler being replaced
(define-command (revoke-enrolment :arg-type enrolment :destructive t :confirm t :label "revoke")
    (object invoker)
  (list :revoked-v2 (enrol-pubkey object)))
(ok "authorization survived the redefinition"
    (handler-case (progn (invoke 'revoke-enrolment (enrol "cc33" 1) *device* :confirmed t) nil)
      (command-refused () t)))

(format t "~&~:[~a TEST(S) FAILED~;ALL TESTS PASSED~]~%" (zerop *fails*) *fails*)
