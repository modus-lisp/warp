;;;; icons.lisp — a small vector icon set, as path data, owned by warp.
;;;;
;;;; ==================================================================================
;;;; WHY NOT AN EXISTING SET
;;;; ==================================================================================
;;;;
;;;; The transport controls were ASCII: "|<", "||", ">|", "[]".  Fine as a placeholder and not
;;;; fine on a phone.  The obvious fix is to pull in a set, and the obvious sets do not fit:
;;;;
;;;;   * ADWAITA is installed here and is real scalable SVG -- and it is CC-BY-SA-3.0 or LGPL-3,
;;;;     where warp is MIT.  Share-alike path data embedded in an MIT library is an entanglement
;;;;     to enter deliberately or not at all, and this is not a good enough reason.
;;;;   * FEATHER / LUCIDE / HEROICONS are permissive and are not on this machine.  Adding a
;;;;     network dependency to draw a triangle is the wrong trade for a system whose display
;;;;     layer is meant to run on bare metal.
;;;;
;;;; So: a small set, hand-authored, in the one place three encodings can share.  Sixteen icons is
;;;; not a design system and is not trying to be; it is the glyphs the apps in this repo actually
;;;; use, and the seam is open (DEFINE-ICON) for an app that needs another.
;;;;
;;;; ==================================================================================
;;;; PATH DATA, NOT A SPRITE, AND WHY THAT IS THE WHOLE POINT
;;;; ==================================================================================
;;;;
;;;; warp has three encodings and a sprite sheet serves exactly one of them.  A path serves all
;;;; three, because each already knows how to draw one:
;;;;
;;;;   DOM          an <svg><path d="..."> -- the string below, verbatim
;;;;   framebuffer  gesso takes the same path; warp-glass is a vector renderer already
;;;;   text         the FALLBACK character, which is the ASCII we started with and is correct
;;;;                for a consumer that has no geometry at all
;;;;
;;;; That last row is why every icon carries a fallback rather than degrading to a blank.  A text
;;;; consumer showing "|<" is right; one showing nothing has lost the button.
;;;;
;;;; ==================================================================================
;;;; THE GLYPH CELL STILL BELONGS TO THE APP
;;;; ==================================================================================
;;;;
;;;; BUTTON's declaration says the glyph is the app's, "not an icon name from a set core would
;;;; then have to own", and that argument survives: a glyph cell may still be any STRING, and
;;;; warp-media's ASCII kept working through this whole change.  What is added is that a glyph
;;;; may ALSO be a KEYWORD, which names an icon here.  An encoding that does not know the name
;;;; draws the fallback; an app that wants a glyph nobody else needs still just sends it.
;;;;
;;;; Coordinates are a 24x24 box, which is what every icon set uses and what makes the numbers
;;;; below legible to anyone who has read one before.

(in-package #:warp)

(defstruct (icon (:conc-name icon-))
  name
  path        ; SVG path data, in a 0 0 24 24 box
  (mode :stroke)   ; :STROKE (outlined, like a chevron) or :FILL (solid, like a play triangle)
  fallback)   ; what a consumer with no geometry shows instead

(defvar *icons* (make-hash-table :test 'eq)
  "Keyword -> ICON.  Keyed by keyword, not by symbol, for the reason cell names are keywords: an
app naming :PLAY in its own package must mean the same icon as this file does.")

(defmacro define-icon (name (&key (mode :stroke) fallback) path)
  `(setf (gethash ,(intern (symbol-name name) :keyword) *icons*)
         (make-icon :name ,(intern (symbol-name name) :keyword)
                    :path ,path :mode ,mode :fallback ,fallback)))

(defun icon (name)
  "NAME's icon, or NIL.  NIL is not an error: an unknown name means an encoding draws the glyph
cell as text, which is what it did before icons existed."
  (and (keywordp name) (gethash name *icons*)))

(defun icon-names ()
  (sort (loop for k being the hash-keys of *icons* collect k) #'string< :key #'symbol-name))

;;; ---- transport ---------------------------------------------------------------------
;;; Solid, because a play triangle outlined reads as an arrow.  These four are warp-media's, and
;;; replacing "|<" "||" ">|" "[]" is what this file was written for.

(define-icon play    (:mode :fill :fallback ">")  "M8 5v14l11-7z")
(define-icon pause   (:mode :fill :fallback "||") "M6 5h4v14H6z M14 5h4v14h-4z")
(define-icon stop    (:mode :fill :fallback "[]") "M6 6h12v12H6z")
(define-icon prev    (:mode :fill :fallback "|<") "M7 5h2v14H7z M20 5v14l-10-7z")
(define-icon next    (:mode :fill :fallback ">|") "M15 5h2v14h-2z M4 5l10 7-10 7z")

;;; ---- navigation --------------------------------------------------------------------
;;; Stroked, because a chevron is a line and filling one makes a wedge.

(define-icon chevron-right (:fallback ">") "M9 5l7 7-7 7")
(define-icon chevron-left  (:fallback "<") "M15 5l-7 7 7 7")
(define-icon chevron-down  (:fallback "v") "M5 9l7 7 7-7")
(define-icon chevron-up    (:fallback "^") "M5 15l7-7 7 7")
(define-icon close         (:fallback "x") "M6 6l12 12 M18 6L6 18")
(define-icon check         (:fallback "/") "M4 12l5 6L20 6")

;;; ---- editing -----------------------------------------------------------------------

(define-icon plus  (:fallback "+") "M12 5v14 M5 12h14")
(define-icon minus (:fallback "-") "M5 12h14")

;;; ---- objects -----------------------------------------------------------------------
;;; A folder and a file, because two apps browse things and both currently say :dir and :file
;;; with no picture at all.

(define-icon folder (:fallback "[]") "M3 6h6l2 2h10v11H3z")
(define-icon file   (:fallback "[]") "M6 3h8l4 4v14H6z M14 3v4h4")
(define-icon trash  (:fallback "x")  "M5 7h14 M9 7V5h6v2 M7 7l1 13h8l1-13")
