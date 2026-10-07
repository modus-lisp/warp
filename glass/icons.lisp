;;;; icons.lisp — warp's icon set (src/icons.lisp) drawn onto a glass framebuffer.
;;;;
;;;; src/icons.lisp keeps each icon as SVG path data so every encoding can draw it, and this is the
;;;; framebuffer's half.  The transport icons are filled polygons -- a triangle, two bars, a square
;;;; -- so a filled-polygon rasterizer is all this needs: the path's straight segments (M L H V Z,
;;;; absolute and relative) become polygons in the icon's 24x24 box, and each pixel's coverage is
;;;; sampled 4x4 with the even-odd rule, which is enough to make a 20-pixel triangle look drawn
;;;; rather than stepped.  An icon this cannot draw (a stroked chevron, or a curve) answers NIL and
;;;; the caller draws its text fallback, which is what it did before there were icons.

(in-package #:warp-glass)

(defvar *icon-polygons* (make-hash-table :test 'eq)
  "Icon keyword -> its polygons (lists of (x . y) in the 24-box), or :NONE if it is not drawable.")

(defun %parse-path (d)
  "Polygons from SVG path data D, for the straight-line commands; NIL if D uses anything else."
  (let ((i 0) (n (length d)) (polys '()) (cur '()) (x 0) (y 0) (cmd nil))
    (labels ((skip () (loop while (and (< i n) (member (char d i) '(#\Space #\, #\Newline #\Tab))) do (incf i)))
             (num-p () (skip) (and (< i n) (or (digit-char-p (char d i)) (member (char d i) '(#\- #\.)))))
             (num ()
               (skip)
               (let ((start i))
                 (when (and (< i n) (char= (char d i) #\-)) (incf i))
                 (loop while (and (< i n) (or (digit-char-p (char d i)) (char= (char d i) #\.))) do (incf i))
                 (let ((*read-default-float-format* 'double-float))
                   (float (read-from-string d t nil :start start :end i) 1d0))))
             (close-poly () (when (cdr cur) (push (nreverse cur) polys)) (setf cur '()))
             (point (px py) (setf x px y py) (push (cons px py) cur)))
      (loop
        (skip)
        (when (>= i n) (return))
        (if (alpha-char-p (char d i))
            (progn (setf cmd (char d i)) (incf i))
            (unless cmd (return-from %parse-path nil)))
        (case cmd
          ((#\M #\m) (close-poly)
           (let ((a (num)) (b (num))) (if (char= cmd #\m) (point (+ x a) (+ y b)) (point a b)))
           ;; further pairs after a moveto are linetos
           (setf cmd (if (char= cmd #\m) #\l #\L)))
          (#\L (point (num) (num)))
          (#\l (let ((a (num)) (b (num))) (point (+ x a) (+ y b))))
          (#\H (point (num) y))
          (#\h (point (+ x (num)) y))
          (#\V (point x (num)))
          (#\v (point x (+ y (num))))
          ((#\Z #\z) (close-poly) (setf cmd nil))
          (t (return-from %parse-path nil)))
        ;; a command letter followed by nothing more of its own: let the loop read the next
        (unless (num-p) (when (member cmd '(#\L #\l #\H #\h #\V #\v)) (setf cmd nil))))
      (close-poly)
      (nreverse polys))))

(defun %icon-polygons (name)
  (let ((hit (gethash name *icon-polygons*)))
    (if hit
        (if (eq hit :none) nil hit)
        (let* ((ic (warp:icon name))
               (polys (and ic (eq (warp::icon-mode ic) :fill) (%parse-path (warp::icon-path ic)))))
          (setf (gethash name *icon-polygons*) (or polys :none))
          polys))))

(defun %inside-p (polys px py)
  "Even-odd: is (PX,PY) inside POLYS?"
  (let ((in nil))
    (dolist (poly polys in)
      (loop for (a . rest) on poly
            for b = (or (car rest) (first poly))
            do (let ((ax (car a)) (ay (cdr a)) (bx (car b)) (by (cdr b)))
                 (when (and (not (eq (> ay py) (> by py)))
                            (< px (+ ax (/ (* (- bx ax) (- py ay)) (- by ay)))))
                   (setf in (not in))))))))

(defun fb-icon (fb name x y size color)
  "Draw warp icon NAME, SIZE pixels square, centred in the SIZE box at (X,Y), in COLOR, blended
   over what is there.  T if it was drawn; NIL if NAME is not a filled icon this can draw."
  (let ((polys (%icon-polygons name)))
    (when polys
      (let* ((px (glass:fb-pixels fb)) (fw (glass:fb-width fb)) (fh (glass:fb-height fb))
             (k (/ 24d0 size))
             (fr (scribe:srgb->linear (ldb (byte 8 16) color)))
             (fg (scribe:srgb->linear (ldb (byte 8 8) color)))
             (fbl (scribe:srgb->linear (ldb (byte 8 0) color))))
        (dotimes (j size)
          (let ((ty (+ y j)))
            (when (< -1 ty fh)
              (dotimes (i size)
                (let ((tx (+ x i)))
                  (when (< -1 tx fw)
                    (let ((hits 0))
                      (dotimes (sy 4)
                        (dotimes (sx 4)
                          (when (%inside-p polys (* k (+ i (/ (+ sx 0.5d0) 4))) (* k (+ j (/ (+ sy 0.5d0) 4))))
                            (incf hits))))
                      (when (plusp hits)
                        (let* ((a (/ hits 16d0)) (ia (- 1d0 a)) (idx (+ (* ty fw) tx)) (dst (aref px idx)))
                          (flet ((ch (d c)
                                   (let ((l (+ (* ia (scribe:srgb->linear d)) (* a c))))
                                     (aref scribe:*linear->srgb* (min 4096 (max 0 (round (* l 4096d0))))))))
                            (setf (aref px idx)
                                  (logior (ash (ch (ldb (byte 8 16) dst) fr) 16)
                                          (ash (ch (ldb (byte 8 8) dst) fg) 8)
                                          (ch (ldb (byte 8 0) dst) fbl)))))))))))))
        (glass:fb-touch fb)
        t))))
