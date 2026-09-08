;;;; widget.lisp — what a row's cells MEAN, declared once, for every encoding.
;;;;
;;;; ==================================================================================
;;;; THE PROBLEM THIS SOLVES, AS IT ACTUALLY APPEARED
;;;; ==================================================================================
;;;;
;;;; PRESENT returns a list of cells and nothing said what they are.  PROTOCOL.md §10.3 is
;;;; explicit about it — "There is no schema for cells.  Their meaning is a contract between
;;;; one app's `present' methods and one page's stylesheet" — and names three shapes the
;;;; reference client hardcodes.  With three clients that were each a flat list of one kind of
;;;; thing, that contract held, because each app had exactly one row shape to agree about.
;;;;
;;;; What it degenerated into is in dom/client.js:
;;;;
;;;;     if (d.type === "menu-item")     [label, cost, destructive?]
;;;;     else if (cells[2] === "opaque") [caption, dims, "opaque"]
;;;;     else                            [value, label, trend]
;;;;
;;;; The third slot means TREND, or DESTRUCTIVE, or the literal type tag "opaque", and which
;;;; one is decided by TESTING ITS OWN CONTENTS.  A type smuggled through a data slot.
;;;;
;;;; Client four (warp-quire, a compound document over a cube) broke it by existing.  Six row
;;;; kinds, cell widths of 1, 2 and 5 — a pivot row is a label, one number per column and a
;;;; total — so there is no third slot to sniff and no width the convention could be widened
;;;; to.  Measured in t/quire.lisp rather than argued.
;;;;
;;;; ==================================================================================
;;;; WHAT CHANGES, AND WHAT DELIBERATELY DOES NOT
;;;; ==================================================================================
;;;;
;;;; NOT THE WIRE.  Every delta already carries `type', and DOM-CONSUMER's %CELLS already
;;;; passes a list of any length.  Nothing here adds a field, a version, or a negotiation.
;;;;
;;;; NOT PRESENT.  Methods still return a list of cells.  A widget declaration says what those
;;;; cells ARE; it does not wrap them, validate them at runtime, or stand between an app and
;;;; its own output.  A kit that made PRESENT more expensive would be paid for on every row of
;;;; every pass.
;;;;
;;;; WHAT CHANGES is that the contract stops being folklore.  DEFINE-WIDGET writes the layout
;;;; down where the type is declared, and an encoding asks — WIDGET-CELLS — instead of
;;;; guessing.  MENU-ITEM is the proof this works, because core already did exactly this for
;;;; it and PROTOCOL.md calls it "the one cell layout an encoding may rely on".  The change is
;;;; to stop that being the only one.
;;;;
;;;; ==================================================================================
;;;; WHY A REGISTRY AND NOT A CLASS HIERARCHY
;;;; ==================================================================================
;;;;
;;;; A widget is not a thing an app subclasses.  Presentation types are already the app's own
;;;; domain classes — STAT, FS-FILE, SLICE-DATA-ROW — and asking an app to inherit from
;;;; WARP:ROW to be paintable would put a UI toolkit in the way of its model, which is the
;;;; thing DESIGN.md's opening refuses ("not McCLIM: retained but imperative, and its size is
;;;; the problem").
;;;;
;;;; So a declaration is a side table keyed by the presentation type, exactly like
;;;; PRESENTATION-KEY, and an app declares its rows are a KIND without changing what they are.
;;;;
;;;; ==================================================================================
;;;; N-ARY, AND WHY THAT IS A PROPERTY RATHER THAN A COUNT
;;;; ==================================================================================
;;;;
;;;; A pivot row's width is the number of columns in the slice — it changes when the user
;;;; pivots, and two consumers of one projection see the same width because it comes from the
;;;; result-set.  So a widget declares its FIXED cells by name and may declare one REPEATING
;;;; group, which is what lets an encoding paint a table without being told how many quarters
;;;; there are:
;;;;
;;;;     (define-widget table-row (label (:repeat value) total))
;;;;
;;;; The repeat is greedy and there is at most one, so a layout is unambiguous from the front
;;;; and the back: fixed cells before it are counted forwards, fixed cells after it backwards,
;;;; and whatever is left is the repeat.  Two repeats would need a delimiter on the wire, and
;;;; a delimiter is the thing this file exists to avoid.

(in-package #:warp)

(defstruct (widget (:conc-name wg-))
  type                ; the presentation type this describes
  cells               ; the declared layout: (name | (:repeat name)) ...
  doc)

(defvar *widgets* (make-hash-table :test 'eq)
  "Presentation type -> WIDGET.  A side table for the reason PRESENTATION-KEY is one: an app's
rows are its own classes and warp does not get to be their superclass.")

(defun %cell-name (spec)
  "Normalize a declared cell name to a KEYWORD.

NAMES ARE KEYWORDS, and the alternative is a bug that only appears across packages.  A
declaration is written wherever the app lives, so `label' in warp-quire reads as
WARP-QUIRE::LABEL while an encoding comparing against its own `label' has WARP-DOM::LABEL --
two symbols that print identically and are never EQ.  The first client to declare a widget
outside warp would have found this, and the test that resolves a pivot row did."
  (etypecase spec
    (symbol (intern (symbol-name spec) :keyword))
    (cons (list :repeat (intern (symbol-name (second spec)) :keyword)))))

(defmacro define-widget (type (&rest cells) &optional doc)
  "Declare what TYPE's cells mean.  CELLS is a list of names, at most one of which may be
(:repeat NAME) — the group that varies with the data.

This is a CONTRACT, not a constructor: it does not wrap PRESENT, does not run per row, and
costs nothing at pass time.  It exists so an encoding can dispatch on a declared type instead
of inferring one from cell contents, and so the layout is written where the type is rather
than in whichever client was written first."
  (let ((repeats (count-if #'consp cells)))
    (when (> repeats 1)
      (error "warp: ~s declares ~d repeating groups; at most one is allowed, or a layout is ~
              ambiguous from both ends and the wire would need a delimiter." type repeats))
    `(progn
       (setf (gethash ',type *widgets*)
             (make-widget :type ',type
                          :cells (mapcar #'%cell-name ',cells)
                          :doc ,doc))
       ',type)))

(defun widget-of (type)
  "TYPE's declaration, or NIL.  NIL is not an error: an undeclared type is an app that has not
said what its cells mean, and an encoding should fall back to painting them as a plain row
rather than refuse to draw it."
  (gethash type *widgets*))

(defun widget-cells (type)
  (let ((w (widget-of type))) (and w (wg-cells w))))

(defun widget-layout (type n)
  "Resolve TYPE's declaration against a row of N cells: a list of N names, one per cell.

This is what an encoding calls.  It answers in the units the encoding has — I am painting
cell 3, what is it — so a table row and a heading go through the same code path and neither
needs to know the other exists.  An undeclared type, or a row whose width cannot satisfy the
declaration, answers NIL: the encoding paints a plain row, which is what every client did
before any of this and is never worse than guessing."
  (let ((cells (widget-cells type)))
    (when cells
      (let* ((rep-pos (position-if #'consp cells))
             (fixed (if rep-pos (1- (length cells)) (length cells))))
        (cond
          ((null rep-pos) (when (= n fixed) (copy-list cells)))
          ((< n fixed) nil)
          (t (let* ((before (subseq cells 0 rep-pos))
                    (after (subseq cells (1+ rep-pos)))
                    (rep-name (second (nth rep-pos cells)))   ; already a keyword
                    (rep-n (- n (length before) (length after))))
               (append before (make-list rep-n :initial-element rep-name) after))))))))

;;; ==================================================================================
;;; THE CORE SET
;;; ==================================================================================
;;;
;;; SMALL, AND CHOSEN BY WHAT FOUR CLIENTS ACTUALLY NEEDED rather than by what a toolkit
;;; usually has.  There is no button here, no slider and no text field, because nothing in
;;; warp has needed one yet: a command is reached by tapping a row or holding for a menu, so
;;; the affordance is the ROW.  When warp-media's transport controls are lifted out of
;;; media/model.lisp they will be the first genuine button and can be declared then — that is
;;; "extract under load", and it is the right rule for compositions even though it is the
;;; wrong rule for the base, which is why the base is here at all.
;;;
;;; Each of these is in use by a shipping client TODAY.  Nothing is declared speculatively.

(define-widget menu-item (label cost tone)
  "A command on an open hold-menu.  TONE is :destructive or :safe; COST is a cost class or NIL.
Core's own, and the shape PROTOCOL.md §10.3 already fixed — every other line in this file is
the argument for doing what this one line already did.")

(define-widget row (value label trend)
  "The default row: a number that leads, what it is, and how it is doing.  TREND is
:ok / :warn / :bad.  This is the layout the reference client falls back to, declared so that
falling back to it is a decision rather than an else-branch.  In use by warp-monitor.")

(define-widget entry (label detail tag)
  "A NAMED thing in a list: what it is called, a secondary fact about it, and which kind it is.

THE SECOND ROW WIDGET, and it earned that by being invented twice.  warp-files presents FS-HEAD,
FS-DIR and FS-FILE as (name, size-or-count, :head/:dir/:file); warp-media presents MEDIA-HEAD,
MEDIA-DIR and MEDIA-TRACK as (name, extension-or-count, :head/:dir/:track).  Two apps, no shared
code, same three cells in the same order -- which is what `extract under load\' looks like when
the load is real rather than anticipated.

IT IS NOT `ROW\', and the difference is editorial rather than structural.  ROW leads with a VALUE
because a monitor is read by glancing for the number that is wrong; an ENTRY leads with a NAME
because a browser is read by looking for the thing you came for.  Same arity, opposite emphasis,
and a stylesheet wants to know which.

TAG is the app\'s own keyword -- :dir, :track, :head, :up -- not a closed enum.  An encoding that
does not recognise one styles the row plainly, which is why adding a kind needs no core change.")

(define-widget button (glyph kind)
  "A CONTROL: a mark to touch, and what it does.

warp\'s first genuine button, and it existed in warp-media before it existed here -- transport
controls presenting (\"|<\" :prev), (\"||\"/\">\" :toggle), (\">|\" :next), (\"[]\" :stop).  This is
the case DESIGN.md\'s `extract under load\' was waiting for and the reason the base set had no
button until now: nothing needed one, because until media every affordance in warp was a ROW.

THE GLYPH IS THE APP\'S, not an icon name from a set core would then have to own.  A text encoding
prints it, a framebuffer draws it, and neither needs a sprite table.  KIND is what it means, so a
consumer can style :stop differently from :next without parsing the glyph.

A BUTTON IS STILL TAPPED LIKE ANYTHING ELSE.  It is a presentation with a declared default
command; rule 5 needed no new verb for it, which is why this is a widget and not a mechanism.")

(define-widget meter (state)
  "ONE SEGMENT of a progress bar: :empty, :head or :filled.

AND A SLIDER IS THIS ONE, TAPPED.  A segment is already a presentation, so giving it a default
command that sets the value to its own position is the whole of a slider -- discrete, one tap,
no drag.  That is the decomposition the interaction-language section requires of continuous
manipulation: the wire carries semantics, not a finger\'s path, so a slider is N choices that
happen to be drawn as a bar.  A CONTINUOUS slider is not available and should not be faked; the
quantisation is the app\'s, and twenty segments is a percentage to the nearest five.

A METER IS N PRESENTATIONS, NOT ONE WIDE ROW, and warp-media found the reason: a second of
playback changes AT MOST ONE CELL.  Send the bar as a single row and every tick re-sends the whole
thing; send it as segments and the delta is one segment, which over a 1024-byte pass at 4 Hz is
the difference between a scrubber and a stall.

THIS IS THE COUNTER-EXAMPLE TO THE RULE AT `CHIP\', and both stay.  A chip is a presentation
because it has identity in the domain; a meter segment has none -- it is an attribute of a
position -- and is a presentation anyway, because it CHANGES INDEPENDENTLY.  So the rule has two
clauses, and the second was hiding inside media the whole time:

    a thing becomes a presentation when it has identity in the domain,
    OR when it changes independently of its neighbours.

A pivot cell has neither, which is why a table row is still one row of cells.")

(define-widget opaque (caption dimensions (:repeat detail) kind)
  "A region the app offers only as pixels (rule 9).  KIND is the literal :OPAQUE, and it is
the reason this file exists: the reference client detects an opaque node by testing whether
the THIRD CELL says \"opaque\", which is a type inferred from a data slot.  Declared here so
an encoding can switch on the presentation type and this cell can eventually go.  In use by
warp-files (previews) and warp-media (the picture).

THE REPEAT IS FOR WHAT THE APP KNOWS AND CORE DOES NOT: warp-files sends caption and size, and
warp-media sends a frame number as well.  Rather than two widgets differing by one cell, the
middle is open and the tag stays last, so a consumer reads the ends and paints whatever detail
it was given.")

;;; ---- the document set, from client four ------------------------------------------
;;; These arrived together because a compound document needed all of them at once, and they
;;; are the first widgets in warp that are not a single flat row.

(define-widget heading (text level)
  "A section heading.  LEVEL is :h1 / :h2 / :h3 — a keyword rather than a number so a text
encoding can print '##' without knowing that 2 meant anything.")

(define-widget prose (text)
  "A paragraph.  ONE cell, unwrapped: wrapping is the consumer's, because a pre-wrapped
fingerprint would put the narrowest consumer's geometry into the shared result-set and every
other consumer would re-render on a resize it does not care about (rule 2).")

(define-widget table-head (corner (:repeat column) total)
  "The heading row of a pivot: the row dimension's name, one heading per column, and the word
for the total.  The first genuinely N-ARY widget, and the one that made the three-cell
convention untenable.")

(define-widget table-row (label (:repeat value) total)
  "One row of a pivot.  The total is LAST and unlabelled — a positional convention INSIDE a
declared type, which is the distinction that makes it tolerable where `cells[2] === \"opaque\"'
is not: a consumer painting a TABLE-ROW knows the last cell is the total because that is this
type's layout, and never has to guess it from the value.")

(define-widget table-total (label value)
  "The grand total under a pivot.")

(define-widget toggle (label state)
  "A SETTING THAT IS ON OR OFF.  STATE is :on or :off.

THE CHECKBOX, and it needed no protocol at all -- which is the finding, not the widget.  A toggle
is a row whose declared default command flips a boolean and whose current value is a cell; tap is
already the default-command gesture (rule 5), so there is no new verb, no new delta kind and no
new message.  It took a widget because there was nothing to PAINT it as, not because there was
nothing to express.

WHY STATE IS A CELL HERE AND VIEW STATE ELSEWHERE, since the two look alike and the distinction
has bitten twice: a toggle\'s on-ness is a fact about the DOMAIN -- every consumer looking at this
setting sees the same value, and a second seat must be told when it changes.  `selected\' and a
picker\'s `live\' are facts about the CONSUMER, and two seats may disagree about them forever.
Rule 7 is the test: would another seat need to know?  Then it is content.")

(define-widget choice (label state)
  "ONE OPTION of a set shown INLINE -- a segmented control, a pill set, a row of tabs.

THE SAME PICKER, RENDERED WITHOUT THE MENU.  A hold-menu of values is the right shape when the
options are many or the space is small; when there are three and they matter, a person expects to
see them.  So this is not a second mechanism: an option is a presentation whose tap invokes the
same valued command a menu item would, and which one is live travels as view state exactly as it
does on the menu.

WHICH ONE IS SET IS A CELL, and getting that wrong first is what makes it worth stating.  It was
declared as view state, by analogy with the hold-menu -- and the analogy is false.  Apply the test
from TOGGLE: would another seat need to know?  It would.  The selected mode is a fact about the
SETTING, not about the looker, so two consumers must agree about it and it travels as content.
STATE is :live or :idle.

(The hold-menu marks its live choice with view state, and that is a looser fit than it looks --
the value comes from COMMAND-CURRENT, which reads the domain.  It is harmless there because a
menu is one consumer\'s open menu and dies with it.  Inline options outlive the tap.)

IT IS A CHIP THAT MEANS SOMETHING DIFFERENT.  Nearly the same cells, and they could have shared a
declaration -- they do not, because an encoding wants to draw them differently: a chip is a step
you can go BACK to, an option is a value you can SWITCH to, and a stylesheet that could not tell
them apart would have to guess from the container.")

(define-widget chip (label)
  "ONE chip — a step of a drill path, a filter clause, a breadcrumb.

A CHIP IS A PRESENTATION, NOT A CELL, and the question that decides it is not about chips.
This was first declared as CHIPS, a row of N cells, and it could only be tapped as a whole: a
gesture carries a key and no coordinates (§10.5), so a row of cells has nothing to send that
says WHICH cell.  The tempting fix is a cell index on the gesture; it is wrong, because it is a
coordinate wearing a different word.

THE DESIGN HAD ALREADY ANSWERED IT.  §10.6: `Menus are presentations -- opening one emits
:appeared per item\'.  A menu is a list of tappable things and so is a breadcrumb.  Same shape,
same answer, and the reconciler needs no special case for either.

THE RULE THIS SETTLES, which is the part worth keeping: DOES THE THING HAVE IDENTITY IN THE
DOMAIN?  A filter clause is an object -- (region . North) -- nameable, keyable, revocable.  A
pivot cell is an ATTRIBUTE of its row and has no identity apart from it.  Things with identity
become presentations; things without stay cells.

That rule is also what stops this generalising into `make every cell tappable\'.  A five-column
pivot of twenty rows would be a hundred presentations instead of twenty, which is precisely the
cost a delta protocol exists to avoid.  Four chips is four.

A ROW OF CHIPS IS A CONTAINER, then, not a widget: `crumbs:<id>\' beside `part:<id>\', laid out
horizontally by the client because a container\'s place is the client\'s (§10.4).  No new delta
kind, no geometry on the wire.")
