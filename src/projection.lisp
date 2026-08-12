;;;; projection.lisp — the shared half of DESIGN.md rule 8: the query, and the objects it returns.
;;;;
;;;; One field of the old SURFACE was the thing being LOOKED AT; every other one was a property of
;;;; the one LOOKING, and with a single consumer nothing forced the distinction.  This file is the
;;;; first half of that split:
;;;;
;;;;   PROJECTION   the QUERY, and the domain objects it returns.  Pulled once per epoch, shared.
;;;;   CONSUMER     one seat: present, layout, diff, encode — and therefore view, scroll, viewport,
;;;;                extents, stream, budget, encoding target, view state, invoker, counters.
;;;;
;;;; It lives in core rather than in an encoding because a query is not a picture.  Two consumers
;;;; over one projection may be a framebuffer and a browser, and neither the objects nor the epoch
;;;; discipline that shares them knows which is which.

(in-package #:warp)

(defclass projection ()
  ((rows-fn :initarg :rows-fn :accessor projection-rows-fn
            :documentation "() -> the current result-set, as DOMAIN OBJECTS.  Not presentations:
present, layout and extents are the consumer's.")
   (type-fn :initarg :type-fn :accessor projection-type-fn
            :initform (lambda (o) (class-name (class-of o)))
            :documentation "object -> presentation type.  What a row IS belongs to the result-set,
not to the seat: a DOM consumer and a token consumer must agree that a row is a STAT even though
they agree on nothing about how it looks.  The default is the object's class name, which is the same
zero-UI-code default PRESENT itself has.")
   (objects :initform '() :accessor projection-objects
            :documentation "The cached result-set — objects, carrying no extents at all.")
   (as-of :initform nil :accessor projection-as-of
          :documentation "When the cached result-set was READ.  Staleness is a property of the read,
so it is stamped here once and copied onto each presentation at layout time; a consumer laying out
an epoch-old cache reports the age of the DATA, not of its own pass.")
   (epoch :initform 0 :accessor projection-epoch)
   (queries :initform 0 :accessor projection-queries
            :documentation "How many times ROWS-FN has actually run.  The measurement rule 8 is
about: with N consumers ticking in a round, this advances once.")
   (consumers :initform '() :accessor projection-consumers)
   (lock :initform (bt:make-lock "warp-projection") :reader projection-lock))
  (:documentation "The shared half: the query, and the objects it returns."))

(defun make-projection (rows-fn &key (type-fn nil type-fn-p))
  (if type-fn-p
      (make-instance 'projection :rows-fn rows-fn :type-fn type-fn)
      (make-instance 'projection :rows-fn rows-fn)))

;;; PULL — the epoch handshake that shares one query between N consumers — is the seam between the
;;; two halves and takes one of each, so it lives with the consumer in consumer.lisp.
