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
for the same reason as the presenters: the lookup is by TYPE, and a sample wears twelve.

AND A TYPE HAS EXACTLY ONE KEY FUNCTION, which is the thing this file found the hard way.  The
live slider presents as METER and so do the static meter samples, so the key function for METER is
called with both -- and one that assumed SAMPLE died on the other with `no applicable method for
SAMPLE-ID'.  Hence the ETYPECASE: two classes sharing a presentation type share its identity rule,
and there is nowhere else to put the distinction."
  `(progn ,@(loop for w in widgets
                  collect `(define-presentation-key ,w (o)
                             (etypecase o
                               (sample (sample-id o))
                               (live-seg (format nil "live/seg/~a" (ls-index o))))))))

;;; NOTE WHAT IS NOT IN THIS LIST: warp:menu-item.
;;;
;;; A PRESENTATION KEY IS GLOBAL PER TYPE, so declaring one for a CORE type overwrites core's.
;;; The catalogue wants to show a menu item, so it declared a key for MENU-ITEM -- and every real
;;; hold-menu in the image then died in the catalogue's key function, which knew about samples and
;;; not about menu items.  Nothing warned; the menu simply never appeared.
;;;
;;; So menu items are shown under the catalogue's OWN type with the same cells.  It is a hair less
;;; honest than every other section -- this one renders a copy rather than the thing -- and that is
;;; the correct trade: a catalogue may not break the app it is documenting.  The alternative is to
;;; make keys dispatch on the OBJECT rather than the type, which is a real design question and not
;;; one to answer in a demo.
(define-widget cat-menu (label cost tone))

;;; The icon sheet shows each icon WITH its name, which a plain BUTTON cannot: a button is a
;;; glyph and what it does, and here the name IS the interesting half -- you are looking up what
;;; to call it.
(define-widget cat-icon (glyph label))

(defmethod present ((s sample) (type (eql 'cat-icon)) (view (eql 'catalogue-view)))
  (sample-cells s))
(define-presentation-key cat-icon (s) (sample-id s))

(defmethod present ((s sample) (type (eql 'cat-menu)) (view (eql 'catalogue-view)))
  (sample-cells s))
(define-presentation-key cat-menu (s) (sample-id s))

(define-sample-presenters warp:row warp:entry warp:opaque warp:heading
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
    (cat-icon        "every icon warp has.  path data, shared by all three encodings"
     ,(mapcar (lambda (n) (list n (string-downcase (symbol-name n)))) (warp:icon-names)))
    (warp:entry      "a name that leads, a secondary fact, and which kind it is"
     (("Documents" "12 items" :dir)
      ("report.pdf" "2.4 MB" :file)
      ("~/work" "4 tracks, 2 folders" :head)))
    (warp:button     "a mark to touch.  the glyph may be a string, or a keyword naming an icon"
     ((:prev :prev) (:play :toggle) (:next :next) (:stop :stop)
      ("|<" :prev)))   ; and a literal string still works, which is what media sent for a year
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
    (cat-menu        "a command on an open hold-menu.  destructive ones look different"
     (("open" :local :safe)
      ("copy path" :local :safe)
      ("revoke terminal" :gateway :destructive))))
  "((widget note (cells ...)) ...) — the whole catalogue, as data.")

;;; ==================================================================================
;;; THE LIVE SECTION
;;; ==================================================================================
;;;
;;; A STATIC SAMPLE CANNOT SHOW A CONTROL WORKING.  Everything above renders a widget; these
;;; three are backed by real state with real commands, so tapping them changes something and the
;;; change comes back as an ordinary delta.  That is the difference between a catalogue that
;;; shows what a widget LOOKS like and one that shows what it DOES -- and for a control the
;;; second is the only interesting question.
;;;
;;; All three needed no protocol: a toggle is a row whose default command flips a boolean, an
;;; option is a presentation whose tap invokes a valued command, and a slider is a meter segment
;;; whose tap sets the value to its own position.

(defclass demo-state ()
  ((flag  :initform nil :accessor demo-flag)
   (title :initform "" :accessor demo-title)
   (mode  :initform "list" :accessor demo-mode)
   (level :initform 7 :accessor demo-level))
  (:documentation "What the live section manipulates.  One instance, because the catalogue is
one page; a second consumer looking at it would see the same values, which is correct -- these
are domain facts, not view state."))

(defvar *demo* (make-instance 'demo-state))

(defclass live-toggle () ((state :initarg :state :reader lt-state)))
(defclass live-choice () ((state :initarg :state :reader lc-state)
                          (value :initarg :value :reader lc-value)))
(defclass live-seg    () ((state :initarg :state :reader ls-state)
                          (index :initarg :index :reader ls-index)))
(defclass live-field  () ((state :initarg :state :reader lf-state)))

(defparameter +levels+ 20)
(defparameter +modes+ '("list" "grid" "columns"))

(define-sample-keys warp:row warp:entry warp:opaque warp:heading
                    warp:prose warp:button warp:meter warp:table-head warp:table-row
                    warp:table-total warp:chip)

(define-presentation-key warp:toggle (o) (progn o "live/toggle"))
(define-presentation-key warp:choice (o) (format nil "live/choice/~a" (lc-value o)))
(define-presentation-key warp:field (o) (progn o "live/field"))

(defmethod present ((o live-toggle) (type (eql 'warp:toggle)) (view (eql 'catalogue-view)))
  (list "show hidden files" (if (demo-flag (lt-state o)) :on :off)))

(defmethod present ((o live-field) (type (eql 'warp:field)) (view (eql 'catalogue-view)))
  (list "document title" (demo-title (lf-state o))))

(defmethod present ((o live-choice) (type (eql 'warp:choice)) (view (eql 'catalogue-view)))
  (list (lc-value o)
        (if (equal (demo-mode (lc-state o)) (lc-value o)) :live :idle)))

;;; The slider's segments are METERs, so they present exactly as the static ones do -- which is
;;; the point: a slider is not a different widget, it is a meter you may tap.
(defmethod present ((o live-seg) (type (eql 'warp:meter)) (view (eql 'catalogue-view)))
  (let ((n (demo-level (ls-state o))))
    (list (cond ((< (ls-index o) n) :filled)
                ((= (ls-index o) n) :head)
                (t :empty)))))

(define-command (flip :arg-type warp:toggle :cost :local :label "flip") (o invoker)
  (declare (ignore invoker))
  (setf (demo-flag (lt-state o)) (not (demo-flag (lt-state o))))
  (list :flag (demo-flag (lt-state o))))
(define-default-command 'warp:toggle 'catalogue-view 'flip)

(define-command (set-title :arg-type warp:field :cost :local :label "set the title"
                           ;; :PROMPT is the whole of text input.  The client collects a string
                           ;; however its platform collects strings and sends the result; warp
                           ;; never sees a keystroke.
                           :prompt "document title")
    (o invoker value)
  (declare (ignore invoker))
  (setf (demo-title (lf-state o)) value)
  (list :title value))
(define-default-command 'warp:field 'catalogue-view 'set-title)

(define-command (pick-mode :arg-type warp:choice :cost :local :label "pick") (o invoker)
  (declare (ignore invoker))
  (setf (demo-mode (lc-state o)) (lc-value o))
  (list :mode (lc-value o)))
(define-default-command 'warp:choice 'catalogue-view 'pick-mode)

(define-command (set-level :arg-type warp:meter :cost :local :label "set") (o invoker)
  (declare (ignore invoker))
  ;; A SLIDER, DECOMPOSED: the segment knows its own position, so setting the value to it needs
  ;; no coordinate on the wire.  Twenty segments is a percentage to the nearest five, and the
  ;; quantisation is the app's choice rather than the protocol's.
  (setf (demo-level (ls-state o)) (ls-index o))
  (list :level (ls-index o)))
(define-default-command 'warp:meter 'catalogue-view 'set-level)

(defun live-rows ()
  (append
   (list (make-instance 'section-head :widget 'live :level 1)
         (make-instance 'section-note :widget 'live
                        :text "these three are backed by real state: tap them.  a toggle is a row whose default command flips a boolean, an option is a tap that carries its value, a slider is a meter segment that sets the value to its own position, and a FIELD is a tap that means ask me -- the client collects the string with its own keyboard and sends the result.  none of them needed anything new on the wire."))
   (list (make-instance 'live-toggle :state *demo*)
         (make-instance 'live-field :state *demo*))
   (loop for m in +modes+ collect (make-instance 'live-choice :state *demo* :value m))
   (loop for i below +levels+ collect (make-instance 'live-seg :state *demo* :index i))))

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
                                                   :id (format nil "~(~a~)/~a" widget j))))
          into out
        finally (return (append (live-rows) out))))

(defun row-type (o)
  "Which presentation type each row is.  A sample is presented AS ITS WIDGET, which is what makes
this a catalogue rather than a screenshot of one."
  ;; TOTAL, NOT ETYPECASE, and that was a real bug rather than a style point: a menu item is not
  ;; a projection row, but it reaches a consumer's layout all the same, and an ETYPECASE here
  ;; killed every pass the moment a menu opened.  The default is core's own -- the object's class
  ;; name -- which is what PROJECTION-TYPE-FN falls back to when an app declares nothing.
  (typecase o
    (section-head 'cat-head)
    (section-note 'cat-note)
    (live-toggle 'warp:toggle)
    (live-field 'warp:field)
    (live-choice 'warp:choice)
    (live-seg 'warp:meter)
    (sample (sample-widget o))
    (t (class-name (class-of o)))))

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
  (typecase o
    (section-head (format nil "w:~(~a~)" (section-widget o)))
    (section-note (format nil "w:~(~a~)" (note-widget o)))
    (live-toggle "live:toggle")
    (live-field "live:toggle")
    (live-choice "opts:mode")          ; laid out as a strip, like any option set
    (live-seg    "seek:level")         ; and the slider as a bar
    (sample (format nil "s:~(~a~)" (sample-widget o)))
    (t "rows")))

(defun catalogue-projection ()
  (make-projection #'catalogue-rows :type-fn #'row-type))
