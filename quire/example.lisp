;;;; quire/example.lisp — the fixture: a small cube and a document that reads like a report.
;;;;
;;;; Invented data, deliberately: this is a protocol demo, and a fixture that had to be fetched
;;;; would make the test depend on a network or a file nobody has.  It is shaped to be
;;;; interesting rather than large -- three dimensions with different cardinalities, so a pivot
;;;; is legible on a phone and a drill has somewhere to go.

(in-package #:warp-quire)

(defun example-cube ()
  (make-instance
   'cube
   :dims '(("region" . :region) ("quarter" . :quarter) ("channel" . :channel) ("rep" . :rep))
   :measures `(("amount" :amount . ,#'sum-of)
               ("orders" :amount . ,#'count-of)
               ("average" :amount . ,#'mean-of)
               ("largest" :amount . ,#'max-of))
   :facts
   (loop for (region quarter channel rep amount)
         in '(("North" "Q1" "direct"  "ada"    41200)
              ("North" "Q1" "partner" "grace"  18800)
              ("North" "Q2" "direct"  "ada"    52600)
              ("North" "Q2" "partner" "grace"  22400)
              ("North" "Q3" "direct"  "ada"    47900)
              ("North" "Q3" "online"  "kay"     9100)
              ("South" "Q1" "direct"  "linus"  33500)
              ("South" "Q1" "online"  "kay"    12700)
              ("South" "Q2" "direct"  "linus"  38900)
              ("South" "Q2" "partner" "grace"  15200)
              ("South" "Q3" "online"  "kay"    18400)
              ("South" "Q3" "direct"  "linus"  41100)
              ("East"  "Q1" "partner" "grace"   8600)
              ("East"  "Q2" "online"  "kay"    11300)
              ("East"  "Q2" "direct"  "ada"    26700)
              ("East"  "Q3" "partner" "grace"  14900)
              ("West"  "Q1" "online"  "kay"     6200)
              ("West"  "Q2" "direct"  "linus"  19800)
              ("West"  "Q3" "direct"  "linus"  24300)
              ("West"  "Q3" "partner" "grace"   7400))
         collect (list :region region :quarter quarter :channel channel
                       :rep rep :amount amount))))

(defun example-document ()
  "A report: prose, a pivot, more prose, a ranked list.  The ORDER matters to the demo -- the
computed parts are separated by authored ones, so a pass that recomputes a slice has to leave
the prose between them untouched, and the test measures exactly that."
  (let ((cube (example-cube)))
    (make-instance
     'document
     :title "Quarterly review"
     :cube cube
     :parts
     (list
      (make-instance 'prose-part :id "t" :level 1 :text "Quarterly review")
      (make-instance 'prose-part :id "intro"
                     :text "Four regions, three quarters. The table below is live: tap a row to
drill into it, hold the header to change what the numbers measure.")
      (make-instance 'prose-part :id "h-sales" :level 2 :text "Sales by region and quarter")
      (make-instance 'slice-part :id "pivot"
                     :note "amount, by region across quarter"
                     :slice (make-instance 'slice :rows-by "region" :cols-by "quarter"
                                                  :measure "amount"))
      (make-instance 'prose-part :id "mid"
                     :text "North carries the year on direct sales. The channel mix below is
the same facts asked a different question.")
      (make-instance 'prose-part :id "h-channel" :level 2 :text "Channel mix")
      (make-instance 'slice-part :id "channel"
                     :note "amount, by channel"
                     :slice (make-instance 'slice :rows-by "channel" :measure "amount"))
      (make-instance 'prose-part :id "h-rep" :level 2 :text "By representative")
      (make-instance 'slice-part :id "reps"
                     :note "amount, by rep"
                     :slice (make-instance 'slice :rows-by "rep" :measure "amount"))
      (make-instance 'prose-part :id "outro"
                     :text "Every number on this page was computed from twenty facts. Nothing
here is stored twice.")))))
