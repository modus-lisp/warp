;;;; t/surface.lisp — the interaction chain: hold -> menu -> confirm -> invoke, all headless.
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream)))
    (asdf:load-system :warp-monitor) (asdf:load-system :warp-glass)))
(defpackage #:wst (:use #:cl)) (in-package #:wst)

;;; This test invokes the REAL revoke command, whose handler rewrites the enrolment file.  The
;;; default is the running gateway's, so point it somewhere disposable first: a test must not be
;;; able to revoke a real terminal by passing.
(setf warp-monitor::*devices-file* "/tmp/warp-test-devices")
(with-open-file (s warp-monitor::*devices-file* :direction :output :if-exists :supersede
                                                :if-does-not-exist :create)
  (format s "aa11bb22cc 0~%dd33ee44ff 0~%"))

(defvar *fails* 0)
(defun ok (n p) (format t "~&  ~:[FAIL~;ok  ~] ~a~%" p n) (unless p (incf *fails*)))
(defun kinds (ds) (mapcar #'warp:delta-kind ds))

;;; a surface over a fixed, controlled result-set (no live files: this tests interaction)
(defvar *rows*
  (list (make-instance 'warp-monitor::enrolment :pubkey "aa11bb22cc" :expires (+ 99999 (- (get-universal-time) 2208988800)))
        (make-instance 'warp-monitor::enrolment :pubkey "dd33ee44ff" :expires (+ 99999 (- (get-universal-time) 2208988800)))))
(defun rows-fn ()
  (let ((tick (warp:now-tick)) (i -1))
    (mapcar (lambda (o)
              (incf i)
              (warp:make-presentation :key (warp:presentation-key 'warp-monitor::enrolment o)
                                      :type 'warp-monitor::enrolment :object o
                                      :extent (warp:snap-extent 0 (* i 32) 480 32)
                                      :fingerprint (warp:present o 'warp-monitor::enrolment 'warp-monitor::monitor-view)
                                      :as-of tick))
            *rows*)))

(defvar *sf* (warp-glass::make-surface :fb (glass:make-framebuffer 480 448 warp-glass:+bg+)
                                       :view 'warp-monitor::monitor-view :rows-fn #'rows-fn
                                       :invoker :allowlist))

(format t "~&== first pass paints the rows, and only the rows ==~%")
(let ((d (warp-glass:tick *sf*)))
  (ok "two rows appear" (equal '(:appeared :appeared) (kinds d)))
  (ok "painted == emitted" (= (warp-glass:sf-painted *sf*) (length d))))
(ok "an idle pass emits nothing" (null (warp-glass:tick *sf*)))

(format t "~&== hold opens a menu, and the menu is PRESENTATIONS ==~%")
(warp-glass:on-pointer *sf* 4 20 10)          ; button 3 = hold, on row 0
(ok "a menu is open" (not (null (warp-glass:sf-menu *sf*))))
(let ((d (warp-glass:tick *sf*)))
  (ok "its items arrive as ordinary :appeared deltas"
      (and (plusp (length d)) (every (lambda (k) (eq k :appeared)) (kinds d))))
  (ok "they are menu-item presentations"
      (every (lambda (x) (eq 'warp-glass::menu-item
                             (warp:p-type (warp:delta-presentation x)))) d))
  (ok "damage is bounded to the menu, not the view"
      (every (lambda (x) (<= (warp::extent-w (warp:delta-extent x)) warp-glass:+menu-w+)) d)))

(format t "~&== the menu offers what this invoker may run, revoke included for the allowlist ==~%")
(let* ((items (getf (warp-glass:sf-menu *sf*) :items))
       (labels* (mapcar (lambda (it) (first (warp:present it 'warp-glass::menu-item 'v))) items)))
  (ok "inspect, revoke and cancel are offered" (and (member "inspect" labels* :test #'string=)
                                                    (member "revoke" labels* :test #'string=)
                                                    (member "cancel" labels* :test #'string=))))

(format t "~&== tapping a destructive item CONFIRMS rather than acting ==~%")
(let* ((vis (warp-glass:sf-visible *sf*))
       (rev (find-if (lambda (p) (and (eq (warp:p-type p) 'warp-glass::menu-item)
                                      (eq :command (warp-glass:mi-kind (warp:p-object p)))
                                      (warp:cmd-destructive (warp-glass:mi-command (warp:p-object p)))))
                     vis))
       (e (warp:p-extent rev)))
  (ok "the revoke row is on screen" (not (null rev)))
  (warp-glass:on-pointer *sf* 1 (+ 4 (warp::extent-x e)) (+ 4 (warp::extent-y e)))
  (ok "nothing was revoked yet" (null (warp-glass:sf-last-result *sf*)))
  (let ((items (getf (warp-glass:sf-menu *sf*) :items)))
    (ok "the menu became a confirmation"
        (and (= 2 (length items))
             (eq :confirm (warp-glass:mi-kind (first items)))))))

(format t "~&== confirming runs it; the surface never second-guesses the policy ==~%")
(warp-glass:tick *sf*)
(let* ((vis (warp-glass:sf-visible *sf*))
       (cf (find-if (lambda (p) (and (eq (warp:p-type p) 'warp-glass::menu-item)
                                     (eq :confirm (warp-glass:mi-kind (warp:p-object p)))))
                    vis))
       (e (warp:p-extent cf)))
  (warp-glass:on-pointer *sf* 1 (+ 4 (warp::extent-x e)) (+ 4 (warp::extent-y e)))
  (ok "the command ran" (eq :revoked (first (warp-glass:sf-last-result *sf*))))
  (ok "and the menu closed" (null (warp-glass:sf-menu *sf*))))

(format t "~&== closing the menu emits :gone for exactly its items ==~%")
(let ((d (warp-glass:tick *sf*)))
  (ok "the menu rows are repaired" (plusp (count :gone (kinds d)))))

(format t "~&== a device may NOT revoke, even if a surface offers it ==~%")
(setf (warp-glass::sf-invoker *sf*) :device)
(ok "the menu no longer lists revoke"
    (multiple-value-bind (kind payload)
        (warp:gesture-command :hold 'warp-monitor::enrolment 'warp-monitor::monitor-view :invoker :device)
      (declare (ignore kind))
      (notany (lambda (c) (warp:cmd-destructive c)) payload)))
(ok "and invoking it anyway is refused"
    (progn (setf (warp-glass::sf-last-result *sf*) nil)
           (warp-glass::run-command *sf* (warp:find-command 'warp-monitor::revoke-terminal)
                                    (first *rows*) :confirmed t)
           (eq :refused (first (warp-glass:sf-last-result *sf*)))))

(format t "~&~:[~a TEST(S) FAILED~;ALL TESTS PASSED~]~%" (zerop *fails*) *fails*)
