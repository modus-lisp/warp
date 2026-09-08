;;;; media/model.lisp — the domain: a folder of files, a transport, a clock, and a picture.
;;;;
;;;; WHAT IS SHARED AND WHAT IS THE SEAT'S.  The PLAYER is shared and so is the FOLDER: both are
;;;; arguments to the query, and two windows over one library are two views of one thing playing
;;;; — which is also the honest picture, since the session has one mixer and everybody hears the
;;;; same sound.  Selection, scroll and budget are the consumer's.  Somebody who wants a second
;;;; player wants a second library, exactly as somebody who wants a second file browser wants a
;;;; second browser.
;;;;
;;;; THE PICTURE IS RULE 9's OPAQUE NODE.  Its fingerprint is a caption, the frame's size and the
;;;; frame NUMBER — so a new frame is a :changed delta on one extent, and a consumer that cannot
;;;; blit is told "frame 812 of Big Buck Bunny" and nothing else.  The RGB rides on the object,
;;;; never in the fingerprint, never on any wire.

(in-package #:warp-media)

;;; ---- where the media is --------------------------------------------------------------------------

(defparameter *extensions*
  '("webm" "mkv" "mp4" "m4a" "mpg" "mpeg" "vob" "ts" "m2ts" "mp3" "opus" "ogg" "oga" "aac")
  "What this player can open.  Named after the CONTAINERS rather than the codecs, so that a folder
of photographs is not a playlist of errors — and because which codec is inside is not knowable from
the name anyway.

WebM and Matroska are the same demuxer; `.mpg', `.vob', `.ts' and `.m2ts' are MPEG program and
transport streams, which carry MPEG-1, MPEG-2 or H.264 video.  A file whose video this cannot decode
is still listed rather than hidden: a person with a folder of them would rather hear one than be
told the folder is empty.")

(defun default-media-root ()
  "$GLASS_MEDIA, else the first of ~/Videos, ~/Music, HOME that exists."
  (let ((env (uiop:getenv "GLASS_MEDIA")))
    (or (and env (plusp (length env))
             (ignore-errors (truename (uiop:ensure-directory-pathname env))))
        (loop for sub in '("Videos/" "Music/")
              for d = (merge-pathnames sub (user-homedir-pathname))
              when (probe-file d) do (return (truename d)))
        (user-homedir-pathname))))

(defvar *media-root* nil "Bound lazily by MAKE-LIBRARY so a saved core does not freeze HOME.")

(defun playable-p (path)
  (let ((type (pathname-type path)))
    (and type (member (string-downcase type) *extensions* :test #'string=) t)))

(defun folder-tracks (dir)
  (sort (remove-if-not #'playable-p
                       (or (ignore-errors (uiop:directory-files (uiop:ensure-directory-pathname dir))) '()))
        #'string< :key (lambda (p) (string-downcase (file-namestring p)))))

(defun folder-subdirs (dir)
  (sort (or (ignore-errors (uiop:subdirectories (uiop:ensure-directory-pathname dir))) '())
        #'string< :key (lambda (p) (string-downcase (namestring p)))))

;;; ---- the library: shared navigation + the player ----------------------------------------------------

(defclass library ()
  ((root :initarg :root :reader library-root)
   (folder :initarg :folder :accessor library-folder :documentation "The open directory — the query's argument.")
   (player :initarg :player :reader library-player)
   (listing :initform nil :accessor %listing)
   (listing-at :initform 0 :accessor %listing-at)
   (listing-for :initform nil :accessor %listing-for)
   (lock :initform (bt:make-lock "warp-media-library") :reader %library-lock))
  (:documentation "A folder being looked at and the player its tracks play on."))

(defun make-library (&key (root (default-media-root)) mixer player)
  (let* ((r (truename (uiop:ensure-directory-pathname root)))
         (lib (make-instance 'library :root r :folder r :player (or player (make-player :mixer mixer)))))
    (setf (player-on-change (library-player lib))
          (lambda (p what)
            ;; auto-advance: the next track in the folder when this one ends
            (when (eq what :ended) (ignore-errors (play-next p)))))
    lib))

(defun %folder-listing (lib)
  "(values subdirs tracks), re-read at most every two seconds — the query runs at UI rate."
  (bt:with-lock-held ((%library-lock lib))
    (let ((now (get-internal-real-time)) (folder (library-folder lib)))
      (when (or (null (%listing lib))
                (not (equal folder (%listing-for lib)))
                (> (- now (%listing-at lib)) (* 2 internal-time-units-per-second)))
        (setf (%listing lib) (cons (folder-subdirs folder) (folder-tracks folder))
              (%listing-at lib) now
              (%listing-for lib) folder))
      (values (car (%listing lib)) (cdr (%listing lib))))))

(defun library-open (lib dir)
  "Navigate: DIR becomes the folder, and its tracks become the player's queue."
  (bt:with-lock-held ((%library-lock lib))
    (setf (library-folder lib) (truename (uiop:ensure-directory-pathname dir))
          (%listing lib) nil))
  (let ((p (library-player lib)))
    (setf (player-queue p) (folder-tracks (library-folder lib))
          (player-index p) (or (and (player-track p) (position (player-track p) (player-queue p) :test #'equal)) -1)))
  (library-folder lib))

(defun library-up (lib)
  (let* ((f (library-folder lib))
         (parent (uiop:pathname-parent-directory-pathname f)))
    (if (and parent (not (equal parent f)) (probe-file parent))
        (library-open lib parent)
        f)))

;;; ---- the domain objects the query returns ---------------------------------------------------------------

(defclass media-row ()
  ((kind :initarg :kind :reader row-kind :documentation ":head :up :dir :track")
   (path :initarg :path :reader row-path)
   (index :initarg :index :reader row-index :documentation "Position in the folder's track list, or NIL.")
   (library :initarg :library :reader row-library)))

(defclass transport ()
  ((library :initarg :library :reader transport-library))
  (:documentation "The title, the clock and the state: one row that changes once a second."))

(defclass media-button ()
  ((kind :initarg :kind :reader button-kind :documentation ":prev :toggle :next :stop")
   (library :initarg :library :reader button-library)))

(defconstant +seek-cells+ 32
  "The seek bar is 32 cells, one macroblock each at the window's width.  A tap lands on a CELL,
which is an object with an index, so `seek to 5/8 of the way` is an ordinary command against an
ordinary presentation — the protocol carries no coordinates and does not need to.")

(defclass seek-cell ()
  ((index :initarg :index :reader cell-index)
   (library :initarg :library :reader cell-library))
  (:documentation "One cell of the seek bar: filled when the position has passed it."))

(defclass picture-node ()
  ((frame :initarg :frame :reader node-frame :documentation "A VIDEO-FRAME, or NIL.  Never in the fingerprint.")
   (library :initarg :library :reader node-library))
  (:documentation "Rule 9's hole: the current picture, for whoever can blit it."))

(defun node-caption (node)
  (let* ((p (library-player (node-library node))) (f (node-frame node)))
    (cond ((null f) (format nil "~a — no picture" (or (player-title p) "nothing playing")))
          (t (format nil "~a — ~d x ~d, frame ~d" (or (player-title p) "?") (vf-w f) (vf-h f) (vf-no f))))))

;;; ---- rule 1: keys ---------------------------------------------------------------------------------------

(define-presentation-key media-head (r) (cons :head (namestring (row-path r))))
(define-presentation-key media-dir (r) (cons :dir (namestring (row-path r))))
(define-presentation-key media-track (r) (cons :track (namestring (row-path r))))
(define-presentation-key media-transport (o) (declare (ignore o)) :transport)
(define-presentation-key media-control (b) (cons :control (button-kind b)))
(define-presentation-key media-picture (o) (declare (ignore o)) :picture)
(define-presentation-key media-seek (c) (cons :seek (cell-index c)))

(defun row-type (o)
  (etypecase o
    (transport 'media-transport)
    (media-button 'media-control)
    (seek-cell 'media-seek)
    (picture-node 'media-picture)
    (media-row (ecase (row-kind o) ((:head :up) 'media-head) (:dir 'media-dir) (:track 'media-track)))))

;;; ---- present: the cells are the fingerprint -------------------------------------------------------------

(defun mmss (secs)
  (if (and secs (numberp secs) (>= secs 0))
      (multiple-value-bind (m s) (floor (round secs) 60) (format nil "~d:~2,'0d" m s))
      "--:--"))

;;; ---- what these ARE, for an encoding ----------------------------------------
;;; The three list rows are core's ENTRY, the same three cells warp-files uses -- two apps that
;;; never shared code and agreed exactly, which is why ENTRY is core's now.
(define-widget media-head (label detail tag))
(define-widget media-dir (label detail tag))
(define-widget media-track (label detail tag))
;;; The picture is OPAQUE with one extra detail (the frame number), which is what the repeat in
;;; core's declaration is for.
(define-widget media-picture (caption dimensions (:repeat detail) kind))
;;; And the two that gave core its control widgets: a transport button, and one segment of the
;;; scrubber.  A METER is N presentations because a second of playback changes at most one.
(define-widget media-control (glyph kind))
(define-widget media-seek (state))
;;; The now-playing line is not a widget any other app has needed: title, elapsed/total, state,
;;; and an error string that is usually empty.  Left as its own declaration rather than forced
;;; into ROW -- four cells, and the fourth is a condition rather than a trend.
(define-widget media-transport (title clock state error))

(defmethod present ((r media-row) (type (eql 'media-head)) (view (eql 'media-view)))
  (let ((lib (row-library r)))
    (multiple-value-bind (dirs tracks) (%folder-listing lib)
      (list (car (last (pathname-directory (library-folder lib))))
            (format nil "~d track~:p~[~:;, ~:*~d folder~:p~]" (length tracks) (length dirs))
            (if (eq (row-kind r) :up) :up :head)))))

(defmethod present ((r media-row) (type (eql 'media-dir)) (view (eql 'media-view)))
  (list (car (last (pathname-directory (row-path r)))) "" :dir))

(defmethod present ((r media-row) (type (eql 'media-track)) (view (eql 'media-view)))
  (let* ((p (library-player (row-library r)))
         (current (and (player-track p) (equal (player-track p) (row-path r)))))
    (list (pathname-name (row-path r))
          (string-downcase (or (pathname-type (row-path r)) ""))
          (if current (player-state p) :track))))

(defmethod present ((tr transport) (type (eql 'media-transport)) (view (eql 'media-view)))
  (let ((p (library-player (transport-library tr))))
    (list (or (player-title p) "—")
          (format nil "~a / ~a" (mmss (player-position p)) (mmss (player-duration p)))
          (player-state p)
          (or (player-error p) ""))))

(defmethod present ((b media-button) (type (eql 'media-control)) (view (eql 'media-view)))
  (let ((p (library-player (button-library b))))
    (list (ecase (button-kind b)
            (:prev "|<") (:toggle (if (eq (player-state p) :playing) "||" ">")) (:next ">|") (:stop "[]"))
          (button-kind b))))

(defmethod present ((c seek-cell) (type (eql 'media-seek)) (view (eql 'media-view)))
  "Filled, or not.  Two states per cell means a second of playback changes at most one cell."
  (let* ((p (library-player (cell-library c))) (dur (player-duration p)))
    (list (cond ((or (null dur) (not (plusp dur)) (null (player-track p))) :empty)
                ((>= (player-position p) (* dur (/ (1+ (cell-index c)) +seek-cells+))) :filled)
                ((>= (player-position p) (* dur (/ (cell-index c) +seek-cells+))) :head)
                (t :empty)))))

(defmethod present ((n picture-node) (type (eql 'media-picture)) (view (eql 'media-view)))
  "Caption, size, frame number, and the tag that says THIS IS A HOLE.  No pixels."
  (let ((f (node-frame n)))
    (list (node-caption n)
          (if f (format nil "~d x ~d" (vf-w f) (vf-h f)) "—")
          (if f (vf-no f) 0)
          :opaque)))

;;; ---- rule 6: commands, safe defaults ---------------------------------------------------------------------

(define-command (play-track :arg-type media-track :label "play") (r invoker)
  (let* ((lib (row-library r)) (p (library-player lib)))
    (unless (equal (player-queue p) (folder-tracks (library-folder lib)))
      (setf (player-queue p) (folder-tracks (library-folder lib))))
    (let ((i (position (row-path r) (player-queue p) :test #'equal)))
      (if i (progn (play-index p i) (list :playing (namestring (row-path r))))
          (list :missing (namestring (row-path r)))))))

(define-command (open-folder :arg-type media-dir :label "open") (r invoker)
  (list :opened (namestring (library-open (row-library r) (row-path r)))))

(define-command (folder-up :arg-type media-head :label "up") (r invoker)
  (list :folder (namestring (library-up (row-library r)))))

(define-command (press :arg-type media-control :label "press") (b invoker)
  (let ((p (library-player (button-library b))))
    (list (button-kind b)
          (ecase (button-kind b)
            (:prev (play-prev p)) (:next (play-next p)) (:stop (stop p)) (:toggle (toggle p))))))

(define-command (toggle-play :arg-type media-transport :label "play / pause") (tr invoker)
  (list :state (toggle (library-player (transport-library tr)))))

(define-command (back-10 :arg-type media-transport :label "back 10 s") (tr invoker)
  (list :position (skip (library-player (transport-library tr)) -10)))

(define-command (forward-10 :arg-type media-transport :label "forward 10 s") (tr invoker)
  (list :position (skip (library-player (transport-library tr)) 10)))

(define-command (stop-playback :arg-type media-transport :label "stop") (tr invoker)
  (list :state (stop (library-player (transport-library tr)))))

(define-command (seek-to-cell :arg-type media-seek :label "seek here") (c invoker)
  (let ((p (library-player (cell-library c))))
    (list :position (seek-fraction p (/ (cell-index c) +seek-cells+)))))

(define-command (toggle-picture :arg-type media-picture :label "play / pause") (n invoker)
  (list :state (toggle (library-player (node-library n)))))

(define-default-command 'media-track 'media-view 'play-track)
(define-default-command 'media-dir 'media-view 'open-folder)
(define-default-command 'media-head 'media-view 'folder-up)
(define-default-command 'media-control 'media-view 'press)
(define-default-command 'media-transport 'media-view 'toggle-play)
(define-default-command 'media-picture 'media-view 'toggle-picture)
(define-default-command 'media-seek 'media-view 'seek-to-cell)

;;; ---- the query -----------------------------------------------------------------------------------------------

(defun library-rows (lib)
  "The result-set, in running order: the picture, the transport, its four controls, then the
   folder — header, sub-folders, tracks.  Re-run at UI rate; the listing is cached in the library."
  (let* ((p (library-player lib))
         (folder (library-folder lib))
         (frame (player-frame-current p)))
    (multiple-value-bind (dirs tracks) (%folder-listing lib)
      (append
       (list (make-instance 'picture-node :frame frame :library lib)
             (make-instance 'transport :library lib))
       (loop for k in '(:prev :toggle :next :stop)
             collect (make-instance 'media-button :kind k :library lib))
       (loop for i below +seek-cells+ collect (make-instance 'seek-cell :index i :library lib))
       (list (make-instance 'media-row :kind (if (equal folder (library-root lib)) :head :up)
                                       :path folder :index nil :library lib))
       (loop for d in dirs collect (make-instance 'media-row :kind :dir :path d :index nil :library lib))
       (loop for tr in tracks for i from 0
             collect (make-instance 'media-row :kind :track :path tr :index i :library lib))))))

(defun library-projection (lib)
  (make-projection (lambda () (library-rows lib)) :type-fn #'row-type))
