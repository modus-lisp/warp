;;;; t/media-i420.lisp — the player into a Y'CbCr framebuffer (glass :I420), never through RGB.
;;;;   run:  sbcl --dynamic-space-size 2048 --non-interactive --load t/media-i420.lisp
;;;; The RGB path is the reference: the same decoded frame blitted both ways must give the
;;;; same picture -- luma within a couple of levels on average over the whole band.

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream)))
    (asdf:load-system :warp-media/glass)))

(defpackage #:warp-media-i420-test (:use #:cl #:warp)) (in-package #:warp-media-i420-test)
(defvar *fails* 0)
(defun ok (n p) (format t "~&  ~:[FAIL~;ok  ~] ~a~%" p n) (unless p (incf *fails*)))

(defparameter *clip* (merge-pathnames "cassette/vectors/t5-av.webm" (user-homedir-pathname)))

(format t "~&== one frame, both ways~%")
(let* ((wp (cassette:open-media *clip* :audio nil))
       (pic (cassette:next-video-frame wp))
       (frgb (let ((warp-media:*frame-format* :rgb)) (warp-media::%picture->frame pic 1)))
       (fyuv (let ((warp-media:*frame-format* :i420)) (warp-media::%picture->frame pic 1)))
       (x (glass:make-framebuffer 400 300 0 :xrgb))
       (i (glass:make-framebuffer 400 300 0 :i420)))
  (ok "an :I420 frame carries planes and no RGB"
      (and (warp-media:vf-y fyuv) (warp-media:vf-u fyuv) (null (warp-media:vf-rgb fyuv))
           (= (length (warp-media:vf-y fyuv)) (* (warp-media:vf-w fyuv) (warp-media:vf-h fyuv)))))
  (warp-media-glass::%blit-frame x frgb 10 10 380 280)
  (warp-media-glass::%blit-frame i fyuv 10 10 380 280)
  (let ((sum 0) (n 0) (mx 0))
    (loop for yy from 10 below 290 do
      (loop for xx from 10 below 390 do
        (let ((e (abs (- (glass::%rgb-y (glass:fb-get x xx yy))
                         (aref (glass:fb-y i) (+ xx (* yy 400)))))))
          (incf sum e) (incf n) (setf mx (max mx e)))))
    (format t "~&    band luma vs the RGB path: mean ~,2f, max ~d~%" (/ sum n) mx)
    (ok "the picture is the same picture (mean luma diff < 3)" (< (/ sum n) 3))
    (ok "and not a blank one" (> (length (remove-duplicates (coerce (subseq (glass:fb-y i) (* 150 400) (* 151 400)) 'list))) 10))))

(format t "~&== the window, cooperative, all :I420~%")
(let* ((glass:*default-fb-format* :i420)
       (warp-media:*frame-format* :i420)
       (warp-media:*cooperative* t)
       (root #p"/tmp/warp-media-i420/")
       (_ (progn (ensure-directories-exist root)
                 (uiop:copy-file *clip* (merge-pathnames "t5-av.webm" root))))
       (fb (glass:make-framebuffer 512 440 0))
       (lib (warp-media:make-library :root root))
       (p (warp-media:library-player lib)))
  (declare (ignore _))
  (multiple-value-bind (on-key on-pointer dirty-p) (warp-media-glass:make-media-window fb lib)
    (declare (ignore on-key on-pointer))
    (warp-media:play-path p (merge-pathnames "t5-av.webm" root))
    (let ((t0 (get-internal-real-time)) (seen '()) (best 0))
      (loop until (or (member (warp-media:player-state p) '(:ended :error))
                      (> (- (get-internal-real-time) t0) (* 10 internal-time-units-per-second)))
            do (funcall dirty-p)
               (let ((f (warp-media:player-frame p))) (when f (pushnew (warp-media:vf-no f) seen)))
               ;; how much picture is in the band while it plays: distinct luma values on a row
               (setf best (max best (length (remove-duplicates
                                             (coerce (subseq (glass:fb-y fb) (* 100 512) (* 101 512)) 'list)))))
               (sleep 0.01))
      (ok (format nil "played to the end (~a)" (warp-media:player-state p)) (eq (warp-media:player-state p) :ended))
      (ok (format nil "frames went by (~d)" (length seen)) (> (length seen) 5))
      (ok (format nil "the framebuffer is :I420 and showed a picture (~d luma levels on a row)" best)
          (and (eq (glass:fb-format fb) :i420) (> best 10))))))

(format t "~&I420: ~:[~d FAILED~;all passed~]~%" (zerop *fails*) *fails*)
(uiop:quit (if (zerop *fails*) 0 1))
