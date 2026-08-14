;;;; t/channel.lisp — the channel module, driven by a fake transport.
;;;;
;;;; THIS IS THE FILE THE GATEWAY WIRING IS MEASURED AGAINST.  The live gateway may not be loaded,
;;;; let alone run, so everything that ends up in it has to be verified by reading — and the only
;;;; honest way to make that assurance mean anything is to make the unreadable part small and put
;;;; everything else here, under assertions, on a transport that is a list.
;;;;
;;;; The fake transport is three lines and that is the point: a WebSocket, an SCTP stream and
;;;; (PUSH FRAME *WIRE*) are the same thing to this code, because the whole of the link is one
;;;; function of one string.  What is left for a gateway is OPEN-CHANNEL / CHANNEL-RECEIVE /
;;;; CHANNEL-CLOSE, none of which can signal, and the last two of which are asserted below to
;;;; survive garbage and to survive being called twice.
;;;;
;;;; The data is REAL-SHAPED and it is a FIXTURE: 64-hex pubkeys and unix expiries, exactly the
;;;; enrolment file the gateway writes, in /tmp.  Nothing in this file may touch the live
;;;; .glass-devices — REVOKE-TERMINAL genuinely rewrites whatever *DEVICES-FILE* names, and a test
;;;; that passes by revoking somebody's terminal is a test that has done real damage to be right.

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream)))
    (asdf:load-system :warp-monitor)
    (asdf:load-system :warp-dom)))

(defpackage #:warp-channel-test (:use #:cl #:warp #:warp-dom)
  (:shadowing-import-from #:warp-dom #:attach))
(in-package #:warp-channel-test)

(defvar *fails* 0)
(defun ok (n p) (format t "~&  ~:[FAIL~;ok  ~] ~a~%" p n) (unless p (incf *fails*)))
(defun kinds (ds) (mapcar #'delta-kind ds))
(defun keys-of (ds) (mapcar #'delta-key ds))

;;; ---- the fixture: the gateway's enrolment file, in /tmp ----------------------------
;;; Same shape as the real one, line for line — <64-hex> <unix-expiry> — because the projection is
;;; the gateway's own READ-DEVICES and a differently-shaped fixture would prove nothing about it.

(defparameter *fixture* "/tmp/warp-channel-test-devices")
(defparameter *now* (- (get-universal-time) 2208988800))
(defparameter *keys*
  '("ea27685000000000000000000000000000000000000000000000000000000001"
    "b91c33aa00000000000000000000000000000000000000000000000000000002"
    "77d0e14400000000000000000000000000000000000000000000000000000003"
    "3f5a90bb00000000000000000000000000000000000000000000000000000004"))

(defun write-fixture (&optional (keys *keys*))
  (with-open-file (s *fixture* :direction :output :if-exists :supersede
                               :if-does-not-exist :create)
    (loop for k in keys for i from 1 do (format s "~a ~a~%" k (+ *now* (* i 3600))))))

(setf warp-monitor::*devices-file* *fixture*)
(write-fixture)

(ok "the test is pointed at a fixture, never the gateway's own file"
    (and (string= *fixture* warp-monitor::*devices-file*)
         (eql 0 (search "/tmp/" warp-monitor::*devices-file*))))

;;; ---- the projection: the query, and nothing else -----------------------------------
;;; Rule 8's shared half.  It is the same query the gateway will run — enrolments, from the file
;;; the gateway writes — with the file swapped for the fixture.

(defvar *queries* 0)
(defun rows-fn () (incf *queries*) (warp-monitor::read-devices))
(defvar *proj* (make-projection #'rows-fn :type-fn #'warp-monitor:row-type))
(defvar *view* 'warp-monitor::monitor-view)

;;; ---- the fake transport ------------------------------------------------------------

(defvar *wire* '())
(defun wire-reset () (setf *wire* '()))
(defun wire-frames () (reverse *wire*))
(defun wire-send (frame) (push frame *wire*))
(defun wire-bytes () (reduce #'+ (mapcar #'length *wire*) :initial-value 0))
(defun wire-deltas ()
  "Every delta the far end would have applied, in arrival order — read off the WIRE, not off the
consumer.  An assertion about what a client holds must come from the bytes that reached it."
  (loop for f in (wire-frames)
        append (let ((j (from-json f))) (json-get j "deltas"))))
(defun d-of (d k) (json-get d k))
(defun wire-delta (key)
  "The delta for KEY, off the wire.  BY KEY and never by position: rule 4 emits within a priority
band in REVERSE layout order, so arrival order is deliberately not layout order and an assertion
that indexed the list would be asserting the emitter's internals instead of the client's."
  (find key (wire-deltas) :test #'equal :key (lambda (d) (d-of d "key"))))
(defun same-set (a b) (equal (sort (copy-list a) #'string<) (sort (copy-list b) #'string<)))

;;; ===================================================================================
(format t "~&== deltas go out: one function of one string is the whole transport ==~%")
;;; ===================================================================================

(wire-reset)
(defvar *ch* (open-channel *proj* :send #'wire-send :view *view* :rows 14
                                  :budget 100000 :invoker :allowlist :hz nil))
(ok "a channel with HZ NIL starts no thread — the caller owns the clock"
    (null (warp-dom::channel-thread *ch*)))
(ok "and it has not sent anything before it has ticked"
    (and (zerop (channel-frames *ch*)) (null *wire*)))

(defvar *first* (channel-tick *ch*))
(ok "the first pass announces the whole working set"
    (and (= 4 (length *first*)) (every (lambda (k) (eq k :appeared)) (kinds *first*))))
(ok "keyed by the pubkey, which is rule 1's key function and not EQ"
    (same-set *keys* (keys-of *first*)))
(ok "one frame reached the fake transport" (= 1 (length *wire*)))
(ok "and its bytes are counted where a host can see them"
    (and (= 1 (channel-frames *ch*)) (= (channel-bytes *ch*) (wire-bytes))))
(let ((ds (wire-deltas)))
  (ok "the wire carries the DOM's own position — (parent . after), not a rectangle"
      (and (= 4 (length ds))
           (every (lambda (d) (equal "rows" (d-of d "in"))) ds)
           (null (d-of (wire-delta (first *keys*)) "after"))
           (equal (first *keys*) (d-of (wire-delta (second *keys*)) "after"))
           (equal (third *keys*) (d-of (wire-delta (fourth *keys*)) "after"))))
  ;; Rule 4's third discipline, on the wire: within a band the emitter goes in REVERSE layout
  ;; order, so an anchor can genuinely arrive after the node that names it.  That is not a bug to
  ;; assert away — it is the reason the client parks an unplaceable node out of the document, and
  ;; a test that demanded layout order here would be quietly deleting the case that obligation
  ;; exists for.
  (ok "and the anchors arrive BEFORE their anchor does, which is why the client must park"
      (let ((arrival (mapcar (lambda (d) (d-of d "key")) ds)))
        (< (position (fourth *keys*) arrival :test #'equal)
           (position (third *keys*) arrival :test #'equal))))
  (ok "every row carries the cells PRESENT produced, and its as-of"
      (every (lambda (d) (and (listp (d-of d "cells")) (d-of d "as_of"))) ds)))
(ok "an idle pass says nothing at all" (and (null (channel-tick *ch*)) (= 1 (length *wire*))))

;;; ===================================================================================
(format t "~&== gestures come back in, by key, and never as a coordinate ==~%")
;;; ===================================================================================

(wire-reset)
(multiple-value-bind (kind detail) (channel-receive *ch* "{\"t\":\"viewport\",\"rows\":2,\"scroll\":0}")
  (ok "the browser reports its own viewport — the consumer-negotiated slice"
      (and (eq :viewport kind) (equal '(2 0) detail))))
(let ((d (channel-tick *ch*)))
  (ok "shrinking it to two rows drops the other two, as :gone"
      (and (= 2 (length d)) (every (lambda (k) (eq k :gone)) (kinds d)))))
(channel-receive *ch* "{\"t\":\"gesture\",\"g\":\"two-finger\",\"dy\":1}")
(ok "two-finger is pan, in ROWS, because that is this encoding's axis"
    (= 1 (consumer-scroll-y (channel-consumer *ch*))))
(channel-receive *ch* "{\"t\":\"viewport\",\"rows\":14,\"scroll\":0}")
(channel-tick *ch*)

(multiple-value-bind (kind detail)
    (channel-receive *ch* (format nil "{\"t\":\"gesture\",\"g\":\"hold\",\"key\":\"~a\"}" (first *keys*)))
  (declare (ignorable detail))
  (ok "a hold on a row opens that consumer's menu" (and (eq :gesture kind)
                                                        (consumer-menu (channel-consumer *ch*)))))
(wire-reset)
(let ((d (channel-tick *ch*)))
  (ok "and the menu travels as ordinary :appeared deltas — menus are presentations"
      (and (plusp (length d)) (every (lambda (k) (eq k :appeared)) (kinds d))))
  (ok "parented on the row that was held, which is this encoding's positional claim"
      (every (lambda (x) (equal (format nil "menu:~a" (first *keys*)) (d-of x "in")))
             (wire-deltas))))

(format t "~&== a message the client had no business sending is data, not a bug ==~%")
(dolist (junk '("" "{" "not json at all" "{\"t\":\"gesture\",\"g\":\"pinch\"}"
                "{\"t\":\"viewport\",\"rows\":-3}" "{\"t\":\"nope\"}"))
  (ok (format nil "  ~s is survived" junk)
      (multiple-value-bind (kind detail) (channel-receive *ch* junk)
        (declare (ignorable detail))
        (not (eq kind :error)))))
(ok "and the channel still works afterwards"
    (progn (channel-receive *ch* "{\"t\":\"gesture\",\"g\":\"tap\",\"key\":\"nosuchkey\"}")
           (not (null (channel-stats *ch*)))))

;;; ===================================================================================
(format t "~&== the budget is BYTES, and a delta that does not fit is deferred, not dropped ==~%")
;;; ===================================================================================

(wire-reset)
(defvar *slow* (open-channel *proj* :send #'wire-send :view *view* :rows 14
                                    :budget 200 :invoker :device :hz nil))
(let ((d (channel-tick *slow*)))
  (ok "a 200-byte budget carries only part of the first fill"
      (and (plusp (length d)) (< (length d) 4)))
  ;; The budget bounds a pass EXCEPT for its first delta, which always goes.  That exception is
  ;; not slack: a 64-hex key with its anchor and its cells is ~230 bytes, so a budget below one
  ;; delta would otherwise defer forever and the link would carry nothing at all while looking
  ;; perfectly healthy.  Assert the rule that exists rather than the tidier one that does not.
  (ok "everything after the first delta fits the budget, priced in the bytes that travelled"
      (<= (reduce #'+ (mapcar (lambda (x) (delta-cost (channel-consumer *slow*) x)) (rest d)))
          200))
  (ok "the frame really is about that size — the budget is the LINK's unit, not a delta count"
      (< (length (first *wire*)) 600))
  (ok "the remainder is deferred, not dropped" (plusp (consumer-deferred (channel-consumer *slow*)))))
(let ((rounds 0))
  (loop while (plusp (consumer-deferred (channel-consumer *slow*)))
        do (incf rounds) (channel-tick *slow*) (when (> rounds 20) (return)))
  (ok "it drains with NOTHING new arriving — rule 4's idle drain" (<= rounds 20))
  (ok "and was never told anything twice" (= 4 (consumer-emitted (channel-consumer *slow*)))))
(ok "the two channels' streams are their own, over one shared query"
    (and (= 4 (consumer-emitted (channel-consumer *slow*)))
         (> (consumer-passes (channel-consumer *slow*)) 1)))

;;; ===================================================================================
(format t "~&== owner and guest: two channels, one query, two menus ==~%")
;;; ===================================================================================
;;; The invoker is the CALLER's — it comes from the authenticated peer and never from anything the
;;; client said.  These two are the gateway's two classes over the same enrolment file.

(defvar *owner* (open-channel *proj* :send (lambda (f) (declare (ignore f))) :view *view*
                                     :rows 14 :budget 100000 :invoker :allowlist :hz nil
                                     :name "owner"))
(defvar *guest* (open-channel *proj* :send (lambda (f) (declare (ignore f))) :view *view*
                                     :rows 14 :budget 100000 :invoker :device :hz nil
                                     :name "guest"))
(channel-tick *owner*) (channel-tick *guest*)

(defun menu-labels (ch)
  (let ((m (consumer-menu (channel-consumer ch))))
    (mapcar (lambda (it) (first (present it 'menu-item *view*))) (getf m :items))))

(channel-receive *owner* (format nil "{\"t\":\"gesture\",\"g\":\"hold\",\"key\":\"~a\"}" (second *keys*)))
(channel-receive *guest* (format nil "{\"t\":\"gesture\",\"g\":\"hold\",\"key\":\"~a\"}" (second *keys*)))
(let ((o (menu-labels *owner*)) (g (menu-labels *guest*)))
  (format t "     owner: ~{~a~^, ~}~%     guest: ~{~a~^, ~}~%" o g)
  (ok "the owner is offered revoke" (member "revoke" o :test #'string=))
  (ok "the guest is NOT" (not (member "revoke" g :test #'string=)))
  (ok "and the guest still gets the safe commands — this is a filter, not a lockout"
      (member "inspect" g :test #'string=))
  (ok "one query served both menus" (= 1 (length (remove-duplicates (list (projection-epoch *proj*)))))))
(ok "one projection, several consumers — the query is not run per seat"
    (>= (length (projection-consumers *proj*)) 4))

(format t "~&== rule 6: the guest's out-of-band revoke is refused at INVOCATION ==~%")
;;; Menu filtering above is COURTESY.  This is the enforcement point, and the only one: the client
;;; names a command it was never offered, over the ordinary message path, and warp says no.

(defun fixture-lines ()
  (with-open-file (s *fixture*) (loop for l = (read-line s nil) while l collect l)))

(let ((before (fixture-lines)))
  (multiple-value-bind (kind detail)
      (channel-receive *guest* (format nil "{\"t\":\"cmd\",\"name\":\"revoke-terminal\",\"key\":\"~a\",\"confirmed\":true}"
                                       (second *keys*)))
    (declare (ignorable detail))
    (ok "the invocation is reported as refused, not as done"
        (or (eq kind :refused)
            (eq :refused (first (consumer-last-result (channel-consumer *guest*))))))
    (ok "and NOTHING was written — the enrolment file is byte-identical"
        (equal before (fixture-lines)))
    (ok "the terminal is still enrolled"
        (member (second *keys*) (mapcar #'warp-monitor::pubkey (warp-monitor::read-devices))
                :test #'string=))))

(format t "~&== ...and the owner's is not ==~%")
(let ((before (fixture-lines)))
  (channel-receive *owner* (format nil "{\"t\":\"cmd\",\"name\":\"revoke-terminal\",\"key\":\"~a\",\"confirmed\":true}"
                                   (second *keys*)))
  (ok "the command ran" (eq :revoked (first (consumer-last-result (channel-consumer *owner*)))))
  (ok "the enrolment is gone from the file, and only that one"
      (and (= (1- (length before)) (length (fixture-lines)))
           (notany (lambda (l) (eql 0 (search (second *keys*) l))) (fixture-lines))))
  (ok "and the guest — same projection, same tick — SEES the revoke it could not perform"
      (let ((d (progn (channel-tick *owner*) (channel-tick *guest*))))
        (and (find :gone (kinds d)) (member (second *keys*) (keys-of d) :test #'equal)))))
(write-fixture)                                   ; put the fixture back for the passes below

;;; ===================================================================================
(format t "~&== a send that fails is an event on a link, not an error in a pass ==~%")
;;; ===================================================================================

(defvar *logged* '())
(defvar *dead* (open-channel *proj* :send (lambda (f) (declare (ignore f)) (error "peer went away"))
                                    :view *view* :rows 14 :budget 100000 :invoker :device :hz nil
                                    :log (lambda (m) (push m *logged*))))
(channel-tick *owner*)                            ; refresh the shared cache to the current file
(let ((d (channel-tick *dead*)))
  (ok "the pass completes and reports what it landed" (= 4 (length d)))
  (ok "the failure is counted" (= 1 (channel-send-errors *dead*)))
  (ok "and named" (search "peer went away" (or (channel-last-error *dead*) ""))))
(channel-receive *dead* "{\"t\":\"viewport\",\"rows\":2}")
(channel-tick *dead*)
(ok "a broken link is reported ONCE, not once per frame at 8 Hz" (= 1 (length *logged*)))
(channel-close *dead*)

;;; ===================================================================================
(format t "~&== detach is clean, and idempotent, because it runs on unwind paths ==~%")
;;; ===================================================================================

(defvar *n-consumers* (length (projection-consumers *proj*)))
(defvar *closing* (open-channel *proj* :send #'wire-send :view *view* :rows 14
                                       :budget 100000 :invoker :device :hz nil))
(ok "opening seats a consumer on the projection"
    (= (1+ *n-consumers*) (length (projection-consumers *proj*))))
(channel-tick *closing*)
(wire-reset)
(channel-close *closing*)
(ok "closing unseats it" (= *n-consumers* (length (projection-consumers *proj*))))
(ok "and nothing lands after the close, even if something ticks it"
    (progn (channel-tick *closing*) (null *wire*)))
(ok "closing twice is not an error" (not (null (channel-close *closing*))))
(ok "and a message after the close is survived too"
    (multiple-value-bind (kind detail) (channel-receive *closing* "{\"t\":\"viewport\",\"rows\":3}")
      (declare (ignorable detail))
      (not (eq kind :error))))
(ok "the other consumers are undisturbed by any of it"
    (progn (channel-tick *owner*) (null (channel-tick *owner*))))

;;; ===================================================================================
(format t "~&== a reconnect starts from an empty stream, and attaching is not a resync ==~%")
;;; ===================================================================================
;;; Rule 8: a consumer that arrives holds nothing, and that emptiness IS its initial snapshot —
;;; there is nothing older to discard, so the generation does not move.  RESYNC bumps it, and stays
;;; for the case it was written for.

(wire-reset)
(defvar *again* (open-channel *proj* :send #'wire-send :view *view* :rows 14
                                     :budget 100000 :invoker :allowlist :hz nil))
(let ((d (channel-tick *again*)))
  (ok "the returning peer is told the whole working set, all :appeared"
      (and (= 4 (length d)) (every (lambda (k) (eq k :appeared)) (kinds d))))
  (ok "it did not inherit anybody else's high-water mark"
      (same-set *keys* (keys-of d))))
(ok "and the generation is still 0 — attaching is not a resync"
    (let ((j (from-json (first (wire-frames))))) (eql 0 (json-get j "gen"))))
(ok "the consumers that were already there were told nothing by its arrival"
    (null (channel-tick *owner*)))
(let ((g0 (ds-generation (consumer-stream (channel-consumer *again*)))))
  (resync (channel-consumer *again*))
  (ok "RESYNC does bump it, which is what makes the discard rule mean something"
      (> (ds-generation (consumer-stream (channel-consumer *again*))) g0)))

;;; ===================================================================================
(format t "~&== with HZ, the channel owns its own clock and gives it back on close ==~%")
;;; ===================================================================================

(wire-reset)
(defvar *timed* (open-channel *proj* :send #'wire-send :view *view* :rows 14
                                     :budget 100000 :invoker :device :hz 20))
(sleep 0.4)
(ok "it ticked on its own" (plusp (channel-frames *timed*)))
(let ((f (channel-frames *timed*)))
  (channel-close *timed*)
  (sleep 0.2)
  (ok "and stopped when told" (= f (channel-frames *timed*)))
  (ok "the thread is gone" (null (warp-dom::channel-thread *timed*))))

;;; ===================================================================================
(format t "~&== several projections over one link: the mux, and the app with no name ==~%")
;;; ===================================================================================
;;; A phone gets ONE negotiated data channel and two apps to show on it.  Everything about routing
;;; between them is here rather than in the gateway, for the reason this whole file exists: the
;;; gateway may not be run, so what runs there has to be what a fake transport can drive.
;;;
;;; The claim under test is narrow and is the one that matters for a deployment: THE DEFAULT APP IS
;;; UNCHANGED.  A message with no `a` routes to it, its frames go back with no `a` on them, and a
;;; client that has never heard of any of this cannot tell the difference.

(wire-reset)
(defvar *second-queries* 0)
(defvar *second-proj*
  (make-projection (lambda ()
                     (incf *second-queries*)
                     (list (make-instance 'warp-monitor::stat :name "one" :value "1" :trend :ok)
                           (make-instance 'warp-monitor::stat :name "two" :value "2" :trend :ok)))
                   :type-fn #'warp-monitor:row-type))

(defvar *opened* '())
(defvar *mux*
  (make-mux (lambda (app)
              (push app *opened*)
              (cond
                ((null app) (open-channel *proj* :send #'wire-send :view *view* :rows 14
                                                 :budget 100000 :invoker :allowlist :hz nil))
                ((equal app "stats")
                 (open-channel *second-proj* :send #'wire-send :view *view* :rows 14
                                             :budget 100000 :invoker :device :hz nil
                                             :app "stats"))
                (t nil)))))                 ; an app this host does not serve

(ok "MESSAGE-APP reads the label off a client message, and NIL means the default"
    (and (null (message-app "{\"t\":\"viewport\",\"rows\":9}"))
         (equal "stats" (message-app "{\"t\":\"viewport\",\"rows\":9,\"a\":\"stats\"}"))
         (null (message-app "{\"t\":\"viewport\",\"a\":\"\"}"))
         (null (message-app "]]] not json at all"))))

(defvar *ch-a* (mux-receive *mux* "{\"t\":\"viewport\",\"rows\":6,\"scroll\":0}"))
(defvar *ch-b* (mux-receive *mux* "{\"t\":\"viewport\",\"rows\":6,\"scroll\":0,\"a\":\"stats\"}"))
(ok "the first message naming an app is what opens it, and only once"
    (and *ch-a* *ch-b* (not (eq *ch-a* *ch-b*))))
(mux-receive *mux* "{\"t\":\"viewport\",\"rows\":7,\"scroll\":0,\"a\":\"stats\"}")
(ok "a second message on the same app reuses the channel rather than opening another"
    (and (= 2 (length (mux-channels *mux*))) (equal '(nil "stats") (mux-apps *mux*))))
(ok "and it reached that app's consumer, not the other one's"
    (and (= 6 (dom-rows (channel-consumer *ch-a*)))
         (= 7 (dom-rows (channel-consumer *ch-b*)))))

(ok "an app this host does not serve is DROPPED — not silently given the default"
    (null (mux-receive *mux* "{\"t\":\"viewport\",\"rows\":3,\"a\":\"nope\"}")))
(let ((n (length *opened*)))
  (mux-receive *mux* "{\"t\":\"viewport\",\"rows\":3,\"a\":\"nope\"}")
  (ok "and asking again costs one answer, not one open attempt per message"
      (= n (length *opened*))))

(channel-tick *ch-a*)
(channel-tick *ch-b*)
(let* ((frames (wire-frames))
       (plain (remove-if (lambda (f) (search "\"a\":" f)) frames))
       (labelled (remove-if-not (lambda (f) (search "\"a\":\"stats\"" f)) frames)))
  (ok "the default app's frames carry NO label — the bytes it sent before any of this existed"
      (and plain (every (lambda (f) (eql 0 (search "{\"gen\":" f))) plain)))
  (ok "and the second app's carry one, which is how a client with two panels tells them apart"
      (and labelled (= (length frames) (+ (length plain) (length labelled)))))
  (ok "two apps, two queries, and neither ran the other's"
      (and (plusp *queries*) (= 1 *second-queries*))))

(mux-close *mux*)
(ok "closing the mux closed every channel on it"
    (and (consumer-stop (channel-consumer *ch-a*)) (consumer-stop (channel-consumer *ch-b*))))
(ok "and it is safe twice, because it runs on an unwind path" (null (mux-close *mux*)))
(ok "the closed channels are still readable, so a host can log what the session did"
    (= 2 (length (mux-channels *mux*))))

;;; ===================================================================================
(format t "~&== and the encoding is still the one that never learned what a socket is ==~%")
;;; ===================================================================================

(ok "no glass anywhere in this image" (and (null (find-package "GLASS"))
                                           (null (find-package "WARP-GLASS"))))
(ok "the channel needs no I/O system: warp-dom, not warp-dom/serve"
    (null (find-package "SB-BSD-SOCKETS-INTERNAL-MARKER")))
(ok "the fixture is the only file this suite touched, and it is in /tmp"
    (probe-file *fixture*))

(format t "~&~:[~a TEST(S) FAILED~;ALL TESTS PASSED~]~%" (zerop *fails*) *fails*)
(unless (zerop *fails*) (sb-ext:exit :code 1))
