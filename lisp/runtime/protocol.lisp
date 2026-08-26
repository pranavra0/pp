;;;; Protocol contracts for the pp.runtime implementation packages.
;;;;
;;;; These generics are the ONLY upward edges in the runtime package DAG.
;;;; Each is declared here (loaded first) and specialized by the package
;;;; that owns the implementation; callers below the owner depend on this
;;;; package alone.

(in-package #:pp.rt.protocol)

(defgeneric runtime-node-engine-force (session state thunk run &key observer)
  (:documentation "Canonical persistent-node entry; OBSERVER receives :hit or :rebuilt."))

(defgeneric runtime-node-engine-invalidate (session keys)
  (:documentation "Invalidate in-memory node memo state for KEYS."))

(defgeneric runtime-node-install-session (session layout)
  (:documentation "Attach node/store services for LAYOUT to SESSION."))

(defgeneric runtime-node-key-of-state (state thunk)
  (:documentation "Canonical persistent-node key for THUNK under STATE."))

(defgeneric runtime-evaluator-force (state value)
  (:documentation "Force one evaluator value."))


(defgeneric runtime-evaluator-error (message &optional code range)
  (:documentation "Signal a typed language error from the evaluator layer."))

(defgeneric runtime-session-find-service (session name)
  (:documentation "Return SESSION's registered service for NAME."))
(defgeneric runtime-evaluator-env-lookup (environment name)
  (:documentation "Look NAME up in ENVIRONMENT using the evaluator's rules."))
(defgeneric runtime-session-register-service (session name function)
  (:documentation "Register FUNCTION as SESSION's service for NAME."))

(defgeneric runtime-session-find-node-thunk (session key)
  (:documentation "Return the live node thunk registered under KEY."))

(defgeneric runtime-session-set-node-thunk (session key thunk)
  (:documentation "Register THUNK under KEY in SESSION's live table."))

(defgeneric runtime-session-add-node-dependent (session parent child)
  (:documentation "Record CHILD as a dependency edge of PARENT."))

(defgeneric runtime-session-add-wanted-node (session key)
  (:documentation "Track KEY as a GC root for lifecycle reconciliation."))

(defgeneric runtime-session-call (session function arguments environment)
  (:documentation "Apply a pp FUNCTION via SESSION's evaluator."))

(defgeneric runtime-session-call-service (session name &rest arguments)
  (:documentation "Invoke SESSION's registered service NAME."))

(defgeneric runtime-session-evaluator (session)
  (:documentation "Return SESSION's evaluator state."))

(defgeneric runtime-session-force (session value)
  (:documentation "Force VALUE within SESSION's evaluation context."))

(defgeneric runtime-session-core-operations (session)
  (:documentation "Return SESSION's core operation views."))

(defgeneric runtime-session-ambient-capabilities (session)
  (:documentation "Return SESSION's long-lived ambient capability list."))

(defgeneric runtime-install-pure-primitives ()
  (:documentation "Install and return the pure primitive catalog."))

(defgeneric runtime-primitive-initial-env (catalog)
  (:documentation "Return the initial global environment for CATALOG."))
