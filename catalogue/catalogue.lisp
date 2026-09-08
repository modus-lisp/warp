;;;; catalogue/catalogue.lisp — every widget warp has, rendered as itself.
;;;;
;;;; ==================================================================================
;;;; A CATALOGUE THAT IS NOT A MOCK
;;;; ==================================================================================
;;;;
;;;; Storybook's idea, and the reason it is worth having here: you cannot see a widget set by
;;;; reading its declarations, and you cannot trust a picture of one drawn by hand.
;;;;
;;;; THIS ONE IS A PROJECTION, so it is not a picture.  Each sample is presented under the REAL
;;;; presentation type, travels as real deltas through the real reconciler, and is painted by the
;;;; same client that paints warp-files and warp-quire.  If a widget renders wrong here it
;;;; renders wrong there; a catalogue that rendered from a fixture would agree with itself and
;;;; nothing else.
;;;;
;;;; It is also client five, which makes it useful twice: the first four clients each had one or
;;;; two row shapes, and this one has ALL of them at once -- which is the arrangement that finds
;;;; a stylesheet claiming a selector another widget also matches.
;;;;
;;;; ==================================================================================
;;;; WHAT IT SHOWS, AND WHY THE DECLARATION IS BESIDE THE RENDERING
;;;; ==================================================================================
;;;;
;;;; Each section is a heading, the declared cell layout as prose, and then the variants.  The
;;;; layout line is generated from WIDGET-CELLS rather than typed, so a catalogue entry cannot
;;;; drift from the declaration it documents -- which is the failure every hand-written
;;;; component gallery eventually has.

(in-package #:warp-catalogue)

;;; ---- the domain: a sample is some cells and the widget they are for ----------------

(defclass sample ()
  ((widget :initarg :widget :reader sample-widget)   ; the presentation type to render AS
   (cells  :initarg :cells  :reader sample-cells)
   (note   :initarg :note   :reader sample-note :initform nil)
   (id     :initarg :id     :reader sample-id))
  (:documentation "One rendering of one widget.  PRESENT hands the cells back verbatim, so what
appears is exactly what an app would have produced -- the catalogue adds nothing and hides
nothing."))

(defclass section-head ()
  ((widget :initarg :widget :reader section-widget)
   (level  :initarg :level  :reader section-level :initform 2)))

(defclass section-note ()
  ((widget :initarg :widget :reader note-widget)
   (text   :initarg :text   :reader note-text)))

;;; ---- identity ---------------------------------------------------------------------

;;; KEYED BY PRESENTATION TYPE, NOT BY CLASS, and the difference bites here for the first time.
;;; Every earlier app named its type after its class -- HEADING-ROW presents as HEADING-ROW -- so
;;; the two were interchangeable and nothing distinguished them.  A catalogue cannot do that: a
;;; SAMPLE presents as BUTTON, or as METER, or as any of twelve, which is the whole point of it.
;;;
;;; warp said so plainly rather than drawing nothing:
;;;   "no presentation key function for type CAT-HEAD, and SECTION-HEAD has no intrinsic identity"
(define-presentation-key cat-head (s) (format nil "h/~(~a~)" (section-widget s)))
(define-presentation-key cat-note (s) (format nil "n/~(~a~)" (note-widget s)))

;;; ---- the catalogue's own two row types --------------------------------------------
;;; The heading and the caption are core's HEADING and PROSE, which is the first dogfooding:
;;; the catalogue is built out of the set it documents.

(define-widget cat-head (text level))
(define-widget cat-note (text))

(defmethod present ((s section-head) (type (eql 'cat-head)) (view (eql 'catalogue-view)))
  (list (string-downcase (symbol-name (section-widget s)))
        (ecase (section-level s) (1 :h1) (2 :h2) (3 :h3))))

(defmethod present ((n section-note) (type (eql 'cat-note)) (view (eql 'catalogue-view)))
  (list (note-text n)))

;;; ---- presenting a sample AS its widget ---------------------------------------------
;;; PRESENT dispatches on the TYPE as an EQL specializer, so rendering a sample as a BUTTON
;;; needs a method for BUTTON.  One per widget, and they are all the same line -- hand the cells
;;; back -- so the macro writes them.  Doing it by hand would be twelve chances to typo a cell
;;; order in the file whose whole job is to show cell orders correctly.

(defmacro define-sample-presenters (&rest widgets)
  `(progn
     ,@(loop for w in widgets
             collect `(defmethod present ((s sample) (type (eql ',w)) (view (eql 'catalogue-view)))
                        (sample-cells s)))))

(defmacro define-sample-keys (&rest widgets)
  "A sample's key is its id, whichever widget it is being rendered as.  One declaration per type
for the same reason as the presenters: the lookup is by TYPE, and a sample wears twelve."
  `(progn ,@(loop for w in widgets
                  collect `(define-presentation-key ,w (s) (sample-id s)))))

(define-sample-presenters warp:menu-item warp:row warp:entry warp:opaque warp:heading
                          warp:prose warp:button warp:meter warp:table-head warp:table-row
                          warp:table-total warp:chip)

(define-sample-keys warp:menu-item warp:row warp:entry warp:opaque warp:heading
                    warp:prose warp:button warp:meter warp:table-head warp:table-row
                    warp:table-total warp:chip)

;;; ---- the samples -------------------------------------------------------------------
;;; VARIANTS ARE THE POINT.  A widget shown once shows that it renders; a widget shown in every
;;; state shows what its states LOOK like beside each other, which is the only way to notice
;;; that two of them are indistinguishable.

(defparameter *samples*
  `((warp:heading    "a section heading, at three levels"
     (("Heading one" :h1) ("Heading two" :h2) ("Heading three" :h3)))
    (warp:prose      "a paragraph.  one cell: wrapping is the consumer's, never the wire's"
     (("Prose is sent as one unwrapped cell, so a narrow consumer and a wide one break it at their own measure, and neither re-renders when the other resizes.")))
    (warp:row        "a value that leads, what it is, and how it is doing"
     (("1.2 GB" "memory in use" :ok)
      ("87%" "cache hit rate" :warn)
      ("14" "sessions refused" :bad)))
    (warp:entry      "a name that leads, a secondary fact, and which kind it is"
     (("Documents" "12 items" :dir)
      ("report.pdf" "2.4 MB" :file)
      ("~/work" "4 tracks, 2 folders" :head)))
    (warp:button     "a mark to touch, and what it means"
     (("|<" :prev) ("||" :toggle) (">|" :next) ("[]" :stop)))
    (warp:meter      "ONE segment of a bar.  a second of playback changes at most one"
     ((:filled) (:filled) (:filled) (:head) (:empty) (:empty) (:empty) (:empty)))
    (warp:chip       "one step of a path.  a presentation, so it is tappable on its own"
     (("region: North") ("channel: direct") ("Q3")))
    (warp:opaque     "a region offered as pixels, described in words.  no bytes on this wire"
     (("photo.jpg" "3024 x 4032" :opaque)
      ("frame" "1280 x 720" 4471 :opaque)))
    (warp:table-head "the heading row of a pivot.  N-ARY: one cell per column"
     (("region" "Q1" "Q2" "Q3" "total")))
    (warp:table-row  "one row of a pivot.  the total is last, by this type's declared layout"
     (("North" "60.0k" "75.0k" "57.0k" "192.0k")
      ("South" "46.2k" "54.1k" "59.5k" "159.8k")
      ("East" "8.6k" "38.0k" "14.9k" "61.5k")))
    (warp:table-total "the grand total under a pivot"
     (("amount" "471.0k")))
    (warp:menu-item  "a command on an open hold-menu.  destructive ones look different"
     (("open" :local :safe)
      ("copy path" :local :safe)
      ("revoke terminal" :gateway :destructive))))
  "((widget note (cells ...)) ...) — the whole catalogue, as data.")

;;; ---- the projection ----------------------------------------------------------------

(defun catalogue-rows ()
  "Every section, in order: a heading, the declared layout, then the variants.

THE LAYOUT LINE IS GENERATED from WIDGET-CELLS, never typed.  A catalogue that restated a
declaration in prose would be a second copy of it, and the two would part company the first time
a widget changed."
  (loop for (widget note variants) in *samples*
        for i from 0
        append (list* (make-instance 'section-head :widget widget)
                      (make-instance 'section-note :widget widget
                                     :text (format nil "~a~%cells: ~{~(~a~)~^, ~}"
                                                   note
                                                   (mapcar (lambda (c)
                                                             (if (consp c)
                                                                 (format nil "~(~a~)…" (second c))
                                                                 c))
                                                           (widget-cells widget))))
                      (loop for cells in variants
                            for j from 0
                            collect (make-instance 'sample :widget widget :cells cells
                                                   :id (format nil "~(~a~)/~a" widget j))))))

(defun row-type (o)
  "Which presentation type each row is.  A sample is presented AS ITS WIDGET, which is what makes
this a catalogue rather than a screenshot of one."
  (etypecase o
    (section-head 'cat-head)
    (section-note 'cat-note)
    (sample (sample-widget o))))

(defun row-container (o)
  "TWO containers per section: the prose, and the samples.

ONE WAS WRONG AND THE CATALOGUE SHOWED IT.  With a single container per widget, a strip that
lays its samples out horizontally -- buttons, meter segments -- laid the section's HEADING and
CAPTION out horizontally too, because a container's layout is the container's and the prose was
inside it.  The heading of `button' ended up beside the buttons.

So the strip is its own container.  That is the same rule warp-quire found for chips (a row of
chips is a container, not a widget) arriving from the other side: a container is the unit of
LAYOUT, so anything laid out differently is a different container, even when it belongs to the
same section conceptually."
  (etypecase o
    (section-head (format nil "w:~(~a~)" (section-widget o)))
    (section-note (format nil "w:~(~a~)" (note-widget o)))
    (sample (format nil "s:~(~a~)" (sample-widget o)))))

(defun catalogue-projection ()
  (make-projection #'catalogue-rows :type-fn #'row-type))
