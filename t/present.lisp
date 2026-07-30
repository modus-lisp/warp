(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream))) (asdf:load-system :warp)))
(defpackage #:warp-p-test (:use #:cl #:warp)) (in-package #:warp-p-test)
(defvar *fails* 0)
(defun ok (n p) (format t "~&  ~:[FAIL~;ok  ~] ~a~%" p n) (unless p (incf *fails*)))

(defclass enrolment () ((pubkey :initarg :pubkey :accessor pubkey)
                        (expires :initarg :expires :accessor expires)))
(define-presentation-key enrolment (e) (pubkey e))
(defun e* (pk exp) (make-instance 'enrolment :pubkey pk :expires exp))

(format t "~&== the default present is an inspector: every slot, zero UI code ==~%")
(let ((c (present (e* "aa11" 900) 'enrolment 'any-view)))
  (ok "names the class then walks slots"
      (and (search "ENROLMENT" (first c))
           (some (lambda (s) (search "pubkey: aa11" s)) c)
           (some (lambda (s) (search "expires: 900" s)) c))))

(format t "~&== a designed view is a specialization, not a different system ==~%")
(defmethod present ((o enrolment) (type (eql 'enrolment)) (view (eql 'list-view)))
  (list (format nil "~a" (subseq (pubkey o) 0 (min 4 (length (pubkey o)))))
        (format nil "expires ~a" (expires o))))
(let ((c (present (e* "aa11bb22" 900) 'enrolment 'list-view)))
  (ok "the specialization wins for that view" (equal '("aa11" "expires 900") c)))
(ok "and the default still serves other views"
    (search "ENROLMENT" (first (present (e* "aa11bb22" 900) 'enrolment 'other-view))))

(format t "~&== layout emits only the VISIBLE rows — that is the working set ==~%")
(let* ((rows (loop for i below 100 collect (e* (format nil "k~3,'0d" i) i)))
       (ps (layout-list rows 'enrolment 'list-view :row-height 32 :viewport-h 320)))
  (ok "a 320px viewport of 32px rows yields ~10 rows, not 100" (<= 9 (length ps) 11))
  (ok "extents are grid-aligned"
      (every (lambda (p) (let ((e (p-extent p)))
                           (and (zerop (mod (extent-y e) +grid+)) (zerop (mod (extent-h e) +grid+)))))
             ps))
  (ok "keys are the pubkeys" (equal "k000" (p-key (first ps)))))

(format t "~&== scrolling: rows that stay MOVE, rows crossing the edge appear/disappear ==~%")
(let* ((rows (loop for i below 100 collect (e* (format nil "k~3,'0d" i) i)))
       (s (make-delta-stream)))
  (emit s (layout-list rows 'enrolment 'list-view :row-height 32 :viewport-h 320 :scroll-y 0))
  (let* ((d (emit s (layout-list rows 'enrolment 'list-view :row-height 32 :viewport-h 320 :scroll-y 32)))
         (kinds (mapcar #'delta-kind d)))
    (ok "one row leaves, one arrives, the rest merely moved"
        (and (= 1 (count :gone kinds)) (= 1 (count :appeared kinds))
             (plusp (count :moved kinds)) (zerop (count :changed kinds))))
    (ok "and a scroll costs far less than the rows it touched"
        (< (reduce #'+ (mapcar (lambda (x) (if (eq (delta-kind x) :moved) 1 40)) d)) 120))))

(format t "~&== a row whose content is unchanged emits nothing, even rebuilt from scratch ==~%")
(let ((s (make-delta-stream)))
  (flet ((frame () (layout-list (list (e* "aa" 1) (e* "bb" 2)) 'enrolment 'list-view)))
    (emit s (frame))
    (ok "identical projection is silent" (null (emit s (frame))))))

(format t "~&~:[~a TEST(S) FAILED~;ALL TESTS PASSED~]~%" (zerop *fails*) *fails*)
