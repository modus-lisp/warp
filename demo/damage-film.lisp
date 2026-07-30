;;;; demo/damage-film.lisp — render warp's delta stream so you can SEE it.
;;;;
;;;; The protocol's whole claim is "only what changed travels."  That is invisible in a working UI,
;;;; which is exactly why it is easy to get wrong and hard to demo.  So: render each frame twice —
;;;; the view as a viewer sees it, and beside it the same frame with the emitted damage outlined and
;;;; tinted by kind.  If the claim holds, the right pane is mostly dark, and it lights up only where
;;;; something actually happened.
;;;;
;;;;   green  appeared   (never seen before — highest priority)
;;;;   red    gone       (stale and misleading — repaired first)
;;;;   blue   moved      (translated; asserts, does not re-send)
;;;;   amber  changed    (seen, now stale)
;;;;
;;;; Writes raw RGB frames; the shell script muxes them with ffmpeg.  No glass, no gesso — the point
;;;; is the protocol, and keeping the demo dependency-free keeps it honest.

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream))) (asdf:load-system :warp)))

(defpackage #:warp-demo (:use #:cl #:warp))
(in-package #:warp-demo)

;;; ---- the domain: enrolled terminals, as the gateway has them ----------------

(defclass enrolment ()
  ((pubkey :initarg :pubkey :accessor pubkey)
   (expires :initarg :expires :accessor expires)))

(define-presentation-key enrolment (e) (pubkey e))

;;; a designed row: short key + a countdown.  The default MOP slot-walk would also work — it would
;;; just be legible rather than designed, which is the trade the design page names.
(defmethod present ((o enrolment) (type (eql 'enrolment)) (view (eql 'list-view)))
  (list (subseq (pubkey o) 0 8)
        (if (plusp (expires o)) (format nil "expires in ~d min" (expires o)) "EXPIRED")))

;;; ---- a tiny framebuffer ----------------------------------------------------

(defconstant +w+ 480)
(defconstant +h+ 448)          ; 28 macroblock rows
(defparameter *row-h* 32)
(defparameter *viewport-h* 384)

(defun fb () (make-array (* +w+ +h+ 3) :element-type '(unsigned-byte 8) :initial-element 0))

(defun px (fb x y r g b)
  (when (and (<= 0 x (1- +w+)) (<= 0 y (1- +h+)))
    (let ((i (* 3 (+ (* y +w+) x))))
      (setf (aref fb i) r (aref fb (+ i 1)) g (aref fb (+ i 2)) b))))

(defun fill-rect (fb x y w h r g b &key (alpha 1.0))
  (loop for yy from (max 0 y) below (min +h+ (+ y h)) do
    (loop for xx from (max 0 x) below (min +w+ (+ x w)) do
      (if (>= alpha 1.0)
          (px fb xx yy r g b)
          (let ((i (* 3 (+ (* yy +w+) xx))))
            (px fb xx yy
                (round (+ (* alpha r) (* (- 1 alpha) (aref fb i))))
                (round (+ (* alpha g) (* (- 1 alpha) (aref fb (+ i 1)))))
                (round (+ (* alpha b) (* (- 1 alpha) (aref fb (+ i 2)))))))))))

(defun frame-rect (fb x y w h r g b)
  (loop for xx from x below (+ x w) do (px fb xx y r g b) (px fb xx (+ y h -1) r g b))
  (loop for yy from y below (+ y h) do (px fb x yy r g b) (px fb (+ x w -1) yy r g b)))

;;; A 3x5 bitmap font: enough to read a key and a countdown, and it keeps the demo dependency-free.
(defparameter *glyphs*
  (let ((h (make-hash-table)))
    (loop for (ch . rows) in
          '((#\0 "111" "101" "101" "101" "111") (#\1 "010" "010" "010" "010" "010")
            (#\2 "111" "001" "111" "100" "111") (#\3 "111" "001" "111" "001" "111")
            (#\4 "101" "101" "111" "001" "001") (#\5 "111" "100" "111" "001" "111")
            (#\6 "111" "100" "111" "101" "111") (#\7 "111" "001" "001" "001" "001")
            (#\8 "111" "101" "111" "101" "111") (#\9 "111" "101" "111" "001" "111")
            (#\a "111" "101" "111" "101" "101") (#\b "110" "101" "110" "101" "111")
            (#\c "111" "100" "100" "100" "111") (#\d "110" "101" "101" "101" "110")
            (#\e "111" "100" "111" "100" "111") (#\f "111" "100" "111" "100" "100")
            (#\i "010" "000" "010" "010" "010") (#\m "101" "111" "111" "101" "101")
            (#\n "101" "111" "111" "111" "101") (#\p "111" "101" "111" "100" "100")
            (#\r "111" "101" "111" "110" "101") (#\s "111" "100" "111" "001" "111")
            (#\t "111" "010" "010" "010" "010") (#\x "101" "101" "010" "101" "101")
            (#\E "111" "100" "111" "100" "111") (#\D "110" "101" "101" "101" "110")
            (#\X "101" "101" "010" "101" "101") (#\P "111" "101" "111" "100" "100")
            (#\I "010" "010" "010" "010" "010") (#\R "111" "101" "111" "110" "101")
            (#\Space "000" "000" "000" "000" "000") (#\- "000" "000" "111" "000" "000")
            (#\: "000" "010" "000" "010" "000") (#\. "000" "000" "000" "000" "010"))
          do (setf (gethash ch h) rows))
    h))

(defun draw-text (fb x y text r g b &key (scale 2))
  (let ((cx x))
    (loop for ch across text do
      (let ((rows (or (gethash ch *glyphs*) (gethash #\- *glyphs*))))
        (loop for ry from 0 below 5 do
          (loop for rx from 0 below 3 do
            (when (char= #\1 (char (nth ry rows) rx))
              (fill-rect fb (+ cx (* rx scale)) (+ y (* ry scale)) scale scale r g b))))
        (incf cx (* scale 4))))))

;;; ---- painting the view ------------------------------------------------------

(defun paint-row (fb p &key selected)
  (let* ((e (p-extent p)) (x (extent-x e)) (y (extent-y e))
         (w (extent-w e)) (h (extent-h e))
         (content (p-fingerprint p))
         (expired (string= "EXPIRED" (second content))))
    (fill-rect fb x y w h (if selected 38 22) (if selected 48 26) (if selected 62 32))
    (fill-rect fb x y 3 h (if expired 200 90) (if expired 60 190) (if expired 60 130))
    (draw-text fb (+ x 12) (+ y 6) (first content) 220 228 236)
    (draw-text fb (+ x 12) (+ y 18) (second content)
               (if expired 230 120) (if expired 90 140) (if expired 90 155) :scale 1)))

(defun paint (presentations &key selected)
  (let ((fb (fb)))
    (fill-rect fb 0 0 +w+ +h+ 12 14 18)
    (dolist (p presentations) (paint-row fb p :selected (equal selected (p-key p))))
    fb))

(defun overlay-damage (fb deltas)
  "The same frame, dimmed, with the emitted damage tinted and outlined by kind."
  (let ((o (copy-seq fb)))
    (fill-rect o 0 0 +w+ +h+ 0 0 0 :alpha 0.72)
    (dolist (d deltas)
      (let ((e (delta-extent d)))
        (when e
          (multiple-value-bind (r g b)
              (ecase (delta-kind d)
                (:appeared (values 60 230 110))
                (:gone     (values 240 70 70))
                (:moved    (values 80 150 255))
                (:changed  (values 250 190 60)))
            (fill-rect o (extent-x e) (extent-y e) (extent-w e) (extent-h e) r g b :alpha 0.22)
            (frame-rect o (extent-x e) (extent-y e) (extent-w e) (extent-h e) r g b)))))
    o))

(defun side-by-side (a b caption)
  "Two panes plus a caption strip, as one wide frame."
  (let* ((gap 8) (cap 28) (w (+ +w+ gap +w+)) (h (+ +h+ cap))
         (out (make-array (* w h 3) :element-type '(unsigned-byte 8) :initial-element 16)))
    (labels ((opx (x y r g b)
               (when (and (<= 0 x (1- w)) (<= 0 y (1- h)))
                 (let ((i (* 3 (+ (* y w) x))))
                   (setf (aref out i) r (aref out (+ i 1)) g (aref out (+ i 2)) b))))
             (blit (src ox)
               (loop for y from 0 below +h+ do
                 (loop for x from 0 below +w+ do
                   (let ((si (* 3 (+ (* y +w+) x))))
                     (opx (+ x ox) (+ y cap)
                          (aref src si) (aref src (+ si 1)) (aref src (+ si 2)))))))
             (otext (x y text)
               (let ((cx x))
                 (loop for ch across text do
                   (let ((rows (or (gethash ch *glyphs*) (gethash #\- *glyphs*))))
                     (loop for ry from 0 below 5 do
                       (loop for rx from 0 below 3 do
                         (when (char= #\1 (char (nth ry rows) rx))
                           (loop for dy below 2 do
                             (loop for dx below 2 do
                               (opx (+ cx (* rx 2) dx) (+ y (* ry 2) dy) 210 220 230)))))))
                   (incf cx 8)))))
      (blit a 0)
      (blit b (+ +w+ gap))
      (otext 10 9 caption))
    (values out w h)))

;;; ---- the script ------------------------------------------------------------

(defun main ()
  (let* ((n 24)
         (rows (loop for i below n
                     collect (make-instance 'enrolment
                                            :pubkey (format nil "~(~a~)" (format nil "e~7,'0d" (* i 1111)))
                                            :expires (+ 10 (* i 37)))))
         (s (make-delta-stream))
         (scroll 0) (selected nil) (frame 0) (out '()))
    (labels ((visible ()
               (layout-list rows 'enrolment 'list-view
                            :width +w+ :row-height *row-h* :scroll-y scroll
                            :viewport-h *viewport-h* :as-of (now-tick)))
             (step! (caption &key (budget most-positive-fixnum))
               (multiple-value-bind (deltas deferred) (emit s (visible) :budget budget)
                 (let* ((view (paint (visible) :selected selected))
                        (dmg (overlay-damage view deltas)))
                   (multiple-value-bind (fbuf w h)
                       (side-by-side view dmg
                                     (format nil "~a - ~d delta~:[s~;~] ~:[~;def ~d~]"
                                             caption (length deltas) (= 1 (length deltas))
                                             (plusp deferred) deferred))
                     (declare (ignore w h))
                     (push fbuf out)))
                 (incf frame)
                 deferred)))
      ;; 1. first paint: everything is new, and it arrives under a budget a few rows at a time
      (loop for i from 0
            for def = (step! (if (zerop i) "first paint - budget 240" "converging - no new input")
                             :budget 240)
            while (plusp def) do (when (> i 20) (return)))
      ;; 2. idle: nothing owed
      (step! "idle - nothing changed")
      ;; 3. one row changes
      (setf (expires (nth 3 rows)) 0)
      (step! "one row expired")
      ;; 4. scroll: rows that stay merely MOVE
      (dotimes (i 6) (incf scroll *row-h*) (step! "scrolling - rows move, edges appear/leave"))
      ;; 5. selection: view state is a presentation too
      (setf selected (pubkey (nth 8 rows)))
      (step! "selection changed")
      ;; 6. a revoke: the row is gone
      (setf rows (remove (nth 8 rows) rows))
      (step! "revoked - gone, repaired first")
      ;; 7. a new enrolment appears at the top
      (push (make-instance 'enrolment :pubkey "beef0001" :expires 1440) rows)
      (step! "new terminal enrolled")
      (step! "idle - nothing changed"))
    ;; write the frames
    (ensure-directories-exist "/tmp/warp-film/")
    (let ((i 0))
      (dolist (f (nreverse out))
        (with-open-file (o (format nil "/tmp/warp-film/f~4,'0d.rgb" i) :direction :output
                           :element-type '(unsigned-byte 8) :if-exists :supersede)
          (write-sequence f o))
        (incf i))
      (format t "~&frames: ~a  size: ~ax~a~%" i (+ +w+ 8 +w+) (+ +h+ 28)))))

(main)
