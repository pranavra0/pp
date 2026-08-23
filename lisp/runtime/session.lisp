;;;; Session state and immutable evaluator operation views.
;;;;
;;;; A session is the owner of mutable runtime state.  Nothing in this file
;;;; uses a process-global registry: callbacks, services, memo tables, and
;;;; pass data are all reachable from an explicit RUNTIME-SESSION value.

(in-package #:pp.runtime)

;;; ---------------------------------------------------------------------------
;;; Operation views

(defstruct (runtime-core-operations
            (:constructor %make-runtime-core-operations (force eval apply)))
  "The small operation view shared by evaluator clients."
  force eval apply)

(defstruct (runtime-node-operations
            (:constructor %make-runtime-node-operations
                (key-of run-body resolve-hit data-closed)))
  "The node boundary.  Store-backed implementations belong to later slices."
  key-of run-body resolve-hit data-closed)

(defstruct (runtime-operations
            (:constructor %make-runtime-operations (core node)))
  core node)

(defun make-runtime-core-operations (&key force eval apply)
  (%make-runtime-core-operations force eval apply))

(defun make-runtime-node-operations (&key key-of run-body resolve-hit data-closed)
  (%make-runtime-node-operations key-of run-body resolve-hit data-closed))

(defun make-runtime-operations (&key core node)
  (%make-runtime-operations core node))

;;; ---------------------------------------------------------------------------
;;; Session-owned records

(defstruct (runtime-domain-entry
            (:constructor make-runtime-domain-entry
                (&key namespace observe diff apply cap observe-cell)))
  namespace observe diff apply cap observe-cell)

(defstruct (runtime-evaluation-state
            (:constructor %make-runtime-evaluation-state))
  (thunks (make-hash-table :test #'equal))
  (macros (make-hash-table :test #'equal))
  (gensym 0 :type integer)
  global-env
  (node-thunks (make-hash-table :test #'equal))
  (node-keys (make-hash-table :test #'equal))
  (node-dependents (make-hash-table :test #'equal))
  (force-path nil)
  (cache-bust 0 :type integer))

(defstruct (runtime-domain-state
            (:constructor %make-runtime-domain-state))
  (domains (make-hash-table :test #'equal))
  (probes (make-hash-table :test #'equal))
  (preseeded-probes (make-hash-table :test #'equal)))

(defstruct (runtime-run-state
            (:constructor %make-runtime-run-state))
  (sealed-pins (make-hash-table :test #'equal))
  (observations nil)
  (wanted-nodes (make-hash-table :test #'equal))
  (run-pins (make-hash-table :test #'equal))
  (preseeded-run-pins (make-hash-table :test #'equal))
  (events nil)
  (reporters nil)
  runtime-manifest)

(defstruct (runtime-node-runtime
            (:constructor %make-runtime-node-runtime))
  scheduler executor remote-dispatch (schedule-locked nil))

(defstruct (runtime-fenced-state
            (:constructor %make-runtime-fenced-state))
  (fenced-actions nil)
  (fenced-epoch-nonce 0 :type integer)
  (fenced-epoch "")
  (fenced-epoch-recovered nil))

(defstruct (runtime-service
            (:constructor make-runtime-service (name function)))
  name function)

(defstruct (runtime-session
            (:constructor %make-runtime-session))
  operations node-runtime runtime-context store-layout evaluator-state
  evaluation domains run fenced
  (services (make-hash-table :test #'equal)))


(defun runtime-session-error (message &optional (code "runtime.session"))
  (if (fboundp 'language-fail)
      (language-fail message code)
      (error "~A" message)))

(defun runtime-session-key (key)
  "Use the canonical textual identity when available, without retaining host
objects as durable keys. Ordinary string keys remain valid for local callers."
  (cond
    ((stringp key) key)
    ((and (fboundp 'node-key-to-string) (typep key 'node-key))
     (node-key-to-string key))
    ((and (fboundp 'cache-key-to-string) (typep key 'cache-key))
     (cache-key-to-string key))
    (t key)))

(defun runtime-session--default-operations (state)
  (unless (and (fboundp 'runtime-evaluator-force)
               (fboundp 'runtime-evaluator-run-expression)
               (fboundp 'runtime-evaluator-apply-value))
    (runtime-session-error
     "an evaluator state requires the explicit evaluator implementation"
     "runtime.evaluator"))
  (let ((core
          (%make-runtime-core-operations
           (lambda (value) (runtime-evaluator-force state value))
           (lambda (expression environment)
             (runtime-evaluator-run-expression state expression environment))
           (lambda (function arguments environment)
             (runtime-evaluator-apply-value state function arguments environment))))
        (node
          (%make-runtime-node-operations
           (if (fboundp 'runtime-evaluator-node-key)
               (lambda (thunk) (runtime-evaluator-node-key state thunk))
               (lambda (thunk)
                 (declare (ignore thunk))
                 (runtime-session-error "node key service is unavailable"
                                        "runtime.node")))
           ;; The default node operation fails closed until a service is
           ;; installed in the session.
           (lambda (key run thunk)
             (declare (ignore key thunk))
             (runtime-session-error
              "persistent node execution service is unavailable"
              "runtime.node"))
           (lambda (thunk key)
             (declare (ignore thunk key))
             nil)
           (lambda (thunk)
             (declare (ignore thunk))
             (runtime-session-error
              "persistent node closure service is unavailable"
              "runtime.node")))))
    (%make-runtime-operations core node)))

(defun runtime-session--make-evaluator-state (&key evaluator-state evaluator-arguments)
  (or evaluator-state
      (if (fboundp 'make-runtime-evaluator)
          (apply #'make-runtime-evaluator evaluator-arguments)
          (runtime-session-error
           "make-runtime-session requires an explicit evaluator state"
           "runtime.evaluator"))))

(defun runtime-session--make-global-env (state)
  (cond
    ((and (fboundp 'runtime-evaluator-state-initial-env)
          (runtime-evaluator-state-initial-env state))
     (runtime-evaluator-state-initial-env state))
    ((and (fboundp 'make-empty-env) (fboundp 'make-env))
     (make-env nil :env-id 0 :env-hash ""))
    (t nil)))

(defun runtime-session--install-store (session layout)
  "Attach one initialized store and its node/effect callbacks to SESSION."
  (unless (fboundp 'runtime-node-install-session)
    (runtime-session-error
     "persistent node services are unavailable"
     "runtime.node"))
  (store-layout-init layout)
  (runtime-node-install-session session layout)
  ;; These callbacks are the session-owned defaults.  A command may replace
  ;; them with reporting or host-observation implementations, but a normal
  ;; session must still retain reads and events for cache and why inspection.
  (unless (runtime-session-find-service session :record-read)
    (runtime-session-register-service
     session :record-read
     (lambda (ignored-session cell hash)
       (declare (ignore ignored-session))
       (runtime-session-add-observation session (cons cell hash)))))
  (unless (runtime-session-find-service session :record-event)
    (runtime-session-register-service
     session :record-event
     (lambda (ignored-session event)
       (declare (ignore ignored-session))
       (runtime-session-add-event session event))))
  (runtime-session-register-service session :store-layout (lambda () layout))
  ;; Track top-level persistent forces for lifecycle reconciliation.  Ordinary
  ;; commands keep this set in memory and do not publish a root.
  (let ((old (runtime-evaluator-state-node-force-function
              (runtime-session-evaluator session))))
    (when old
      (runtime-session-register-callback
       session :node-force
       (lambda (callback-state thunk key run)
         (runtime-session-add-wanted-node session key)
         (funcall old callback-state thunk key run)))))
  session)

(defun make-runtime-session (&key operations core-operations node-operations
                                  evaluator-state evaluator-arguments
                                  scheduler executor remote-dispatch
                                  (schedule-locked nil) runtime-context
                                  store-layout store-root
                                  (initialize-store t) capabilities
                                  services)
  "Create one explicit session and its operation views.

When STORE-LAYOUT or STORE-ROOT is supplied, initialize the durable store and
install the store-backed node/effect callbacks before returning."
  (let* ((state (runtime-session--make-evaluator-state
                 :evaluator-state evaluator-state
                 :evaluator-arguments evaluator-arguments))
         (store-layout (or store-layout
                           (and store-root (make-store-layout store-root))))
         (operations
           (or operations
               (%make-runtime-operations
                (or core-operations
                    (runtime-operations-core
                     (runtime-session--default-operations state)))
                (or node-operations
                    (runtime-operations-node
                     (runtime-session--default-operations state))))))
         (evaluation (%make-runtime-evaluation-state
                      :global-env (runtime-session--make-global-env state)))
         (session (%make-runtime-session
                   :operations operations
                   :node-runtime (%make-runtime-node-runtime
                                  :scheduler scheduler :executor executor
                                  :remote-dispatch remote-dispatch
                                  :schedule-locked schedule-locked)
                   :runtime-context runtime-context
                   :store-layout store-layout
                   :evaluator-state state
                   :evaluation evaluation
                   :domains (%make-runtime-domain-state)
                   :run (%make-runtime-run-state)
                   :fenced (%make-runtime-fenced-state))))
    (when (and capabilities
               (fboundp 'runtime-evaluator-state-capabilities))
      (setf (runtime-evaluator-state-capabilities state)
            (copy-tree capabilities)))
    (dolist (entry services)
      (destructuring-bind (name . function) entry
        (runtime-session-register-service session name function)))
    (when (and store-layout initialize-store)
      (runtime-session--install-store session store-layout))
    session))

;;; The default operation construction above is intentionally explicit; these
;;; accessors make the ownership boundary pleasant for callers and tests.


(defun runtime-session-evaluator (session)
  (runtime-session-evaluator-state session))

(defun runtime-session-operations-view (session)
  (runtime-session-operations session))

(defun runtime-session-core-operations (session)
  (runtime-operations-core (runtime-session-operations session)))

(defun runtime-session-node-operations (session)
  (runtime-operations-node (runtime-session-operations session)))

(defun runtime-session-scheduler (session)
  (runtime-node-runtime-scheduler (runtime-session-node-runtime session)))

(defun runtime-session-executor (session)
  (runtime-node-runtime-executor (runtime-session-node-runtime session)))

(defun runtime-session-remote-dispatch (session)
  (runtime-node-runtime-remote-dispatch (runtime-session-node-runtime session)))

(defun runtime-session-schedule-locked-p (session)
  (runtime-node-runtime-schedule-locked (runtime-session-node-runtime session)))

(defun (setf runtime-session-schedule-locked-p) (value session)
  (setf (runtime-node-runtime-schedule-locked
         (runtime-session-node-runtime session))
        (not (null value))))

(defun runtime-session-force (session value)
  (funcall (runtime-core-operations-force (runtime-session-core-operations session))
           value))

(defun runtime-session-call (session function arguments environment)
  (funcall (runtime-core-operations-apply (runtime-session-core-operations session))
           function arguments environment))

;;; ---------------------------------------------------------------------------
;;; Session callback/service registration

(defun runtime-session-register-service (session name function)
  "Install FUNCTION in SESSION.  This is deliberately session-local."
  (unless (functionp function)
    (runtime-session-error "runtime service must be a function" "runtime.service"))
  (setf (gethash name (runtime-session-services session))
        (make-runtime-service name function))
  function)

(defun runtime-session-unregister-service (session name)
  (remhash name (runtime-session-services session)))

(defun runtime-session-find-service (session name)
  (let ((entry (gethash name (runtime-session-services session))))
    (and entry
         (if (eq name :process-records)
             (funcall (runtime-service-function entry))
             (runtime-service-function entry)))))

(defun runtime-session-service (session name)
  (or (runtime-session-find-service session name)
      (runtime-session-error
       (format nil "runtime service is unavailable: ~A" name)
       "runtime.service")))

(defun runtime-session-call-service (session name &rest arguments)
  (apply (runtime-session-service session name) arguments))

(defun runtime-session-register-callback (session name function)
  "Register a host callback and connect known evaluator seams to it.
Unknown callback names remain ordinary session services, avoiding a registry
outside the session."
  (runtime-session-register-service session name function)
  (let ((state (runtime-session-evaluator session)))
    (cond
      ((and (eq name :perform)
            (fboundp 'runtime-evaluator-state-perform-function))
       (setf (runtime-evaluator-state-perform-function state) function))
      ((and (eq name :with-capabilities)
            (fboundp 'runtime-evaluator-state-with-capabilities-function))
       (setf (runtime-evaluator-state-with-capabilities-function state) function))
      ((and (eq name :with-handlers)
            (fboundp 'runtime-evaluator-state-with-handlers-function))
       (setf (runtime-evaluator-state-with-handlers-function state) function))
      ((and (eq name :with-config)
            (fboundp 'runtime-evaluator-state-with-config-function))
       (setf (runtime-evaluator-state-with-config-function state) function))
      ((and (eq name :load)
            (fboundp 'runtime-evaluator-state-load-function))
       (setf (runtime-evaluator-state-load-function state) function))
      ((and (eq name :load-module)
            (fboundp 'runtime-evaluator-state-load-module-function))
       (setf (runtime-evaluator-state-load-module-function state) function))
      ((and (eq name :island)
            (fboundp 'runtime-evaluator-state-island-function))
       (setf (runtime-evaluator-state-island-function state) function))
      ((and (eq name :node-force)
            (fboundp 'runtime-evaluator-state-node-force-function))
       (setf (runtime-evaluator-state-node-force-function state) function)))
  function))

(defun runtime-session-register-callbacks (session callbacks)
  (dolist (entry callbacks session)
    (destructuring-bind (name . function) entry
      (runtime-session-register-callback session name function))))

;;; ---------------------------------------------------------------------------
;;; Reset boundaries

(defun runtime-session--clear-hash (table)
  (clrhash table)
  table)
 
(defun runtime-session--reset-wanted-nodes (session)
  "Discard wanted-node requests from the previous lifecycle boundary."
  (runtime-session--clear-hash
   (runtime-run-state-wanted-nodes (runtime-session-run session)))
  session)



(defun runtime-session--restore-preseeded (source target)
  (maphash (lambda (key value) (setf (gethash key target) value)) source))

(defun runtime-session-reset-pass-state (session)
  (let* ((domains (runtime-session-domains session))
         (run (runtime-session-run session))
         (fenced (runtime-session-fenced session)))
    (runtime-session--clear-hash (runtime-domain-state-probes domains))
    (runtime-session--clear-hash (runtime-run-state-sealed-pins run))
    (runtime-session--clear-hash (runtime-run-state-run-pins run))
    (runtime-session--reset-wanted-nodes session)
    (runtime-session--restore-preseeded
     (runtime-domain-state-preseeded-probes domains)
     (runtime-domain-state-probes domains))
    (runtime-session--restore-preseeded
     (runtime-run-state-preseeded-run-pins run)
     (runtime-run-state-run-pins run))
    (setf (runtime-run-state-observations run) nil
          (runtime-run-state-events run) nil
          (runtime-fenced-state-fenced-actions fenced) nil)
    session))
(defun runtime-session--set-evaluator-slot (state accessor value)
  (let* ((symbol (if (symbolp accessor)
                     accessor
                     (intern accessor (find-package '#:pp.runtime))))
         (setf-name (list 'setf symbol)))
    (when (and (fboundp symbol) (fboundp setf-name))
      (funcall (fdefinition setf-name) value state)))
  value)
(defun runtime-session--evaluator-slot (state accessor)
  (let ((symbol (if (symbolp accessor)
                    accessor
                    (intern accessor (find-package '#:pp.runtime)))))
    (and (fboundp symbol) (funcall symbol state))))


(defun runtime-session-reset-primitive-gensym (state)
  "Reset the language-owned primitive gensym scope at an evaluation boundary.

The catalog owns the counter used by the GENSYM primitive; keep that
implementation detail behind the narrow language hook rather than mutating
the catalog slot from session code.  Older language images without the hook
remain usable, while current images reset the actual catalog counter."
  (let ((catalog (runtime-session--evaluator-slot
                  state 'runtime-evaluator-state-catalog)))
    (when (and catalog (fboundp 'runtime-primitive-reset-gensym))
      (funcall #'runtime-primitive-reset-gensym catalog)))
  state)

(defun runtime-session--reset-gensym-state (session)
  "Reset both session and primitive gensym counters for a fresh boundary."
  (let ((evaluation (runtime-session-evaluation session))
        (state (runtime-session-evaluator session)))
    (setf (runtime-evaluation-state-gensym evaluation) 0)
    (runtime-session-reset-primitive-gensym state))
  session)

(defun runtime-session-reset-evaluator-state (state)
  ;; Keep the evaluator's persistent cache and initial capabilities; all
  ;; expression-local machine state and dynamic frames are fresh.
  (runtime-session--set-evaluator-slot state 'runtime-evaluator-state-steps 0)
  (runtime-session--set-evaluator-slot state 'runtime-evaluator-state-depth 0)
  (runtime-session--set-evaluator-slot state 'runtime-evaluator-state-force-stack nil)
  (runtime-session--set-evaluator-slot state 'runtime-evaluator-state-force-count 0)
  (runtime-session--set-evaluator-slot state 'runtime-evaluator-state-config-stack nil)
  (runtime-session--set-evaluator-slot state 'runtime-evaluator-state-handler-stack nil)
  (let ((macro-state
          (runtime-session--evaluator-slot state
                                           'runtime-evaluator-state-macro-state)))
    (when (and macro-state
               (fboundp 'runtime-macro-state-macros)
               (fboundp 'runtime-macro-state-expansion-count))
      (clrhash (runtime-macro-state-macros macro-state))
      (runtime-session--set-evaluator-slot
       macro-state 'runtime-macro-state-expansion-count 0)))
  state)

(defun runtime-session-begin-pass (session)
  (runtime-session-reset-pass-state session)
  (runtime-session--reset-gensym-state session)
  (let ((fenced (runtime-session-fenced session)))
    (unless (runtime-fenced-state-fenced-epoch-recovered fenced)
      (setf (runtime-fenced-state-fenced-epoch fenced) "")))
  session)

(defun runtime-session-begin-evaluation (session &key (retain-thunks nil))
  (let* ((evaluation (runtime-session-evaluation session))
         (domains (runtime-session-domains session))
         (run (runtime-session-run session))
         (fenced (runtime-session-fenced session))
         (state (runtime-session-evaluator session)))
    (unless retain-thunks
      (runtime-session--clear-hash (runtime-evaluation-state-thunks evaluation))
      (runtime-session--clear-hash (runtime-evaluation-state-node-thunks evaluation))
      (runtime-session--clear-hash (runtime-evaluation-state-node-keys evaluation))
      (runtime-session--clear-hash
       (runtime-evaluation-state-node-dependents evaluation)))
    (runtime-session--clear-hash (runtime-evaluation-state-macros evaluation))
    (setf (runtime-evaluation-state-force-path evaluation) nil
          (runtime-evaluation-state-cache-bust evaluation) 0)
    (runtime-session--clear-hash (runtime-domain-state-domains domains))
    (runtime-session-reset-pass-state session)
    (setf (runtime-run-state-runtime-manifest run) nil
          (runtime-run-state-reporters run) nil)
    (runtime-session-reset-evaluator-state state)
    (runtime-session--reset-gensym-state session)
    ;; A recovered epoch is consumed by the next evaluation.
    (if (runtime-fenced-state-fenced-epoch-recovered fenced)
        (setf (runtime-fenced-state-fenced-epoch-recovered fenced) nil)
        (setf (runtime-fenced-state-fenced-epoch fenced) "")))
  session)

(defun runtime-session-begin-watch (session)
  (runtime-session--reset-wanted-nodes session)
  (runtime-session--reset-gensym-state session)
  (let ((evaluation (runtime-session-evaluation session)))
    (runtime-session--clear-hash (runtime-evaluation-state-node-thunks evaluation))
    (runtime-session--clear-hash (runtime-evaluation-state-node-keys evaluation))
    (runtime-session--clear-hash
     (runtime-evaluation-state-node-dependents evaluation)))
  session)

;;; ---------------------------------------------------------------------------
;;; Evaluation state accessors and registries

(defun runtime-session-global-env (session)
  (runtime-evaluation-state-global-env (runtime-session-evaluation session)))

(defun (setf runtime-session-global-env) (value session)
  (setf (runtime-evaluation-state-global-env (runtime-session-evaluation session))
        value))

(defun runtime-session-find-thunk (session name)
  (gethash name (runtime-evaluation-state-thunks (runtime-session-evaluation session))))

(defun runtime-session-add-thunk (session name thunk)
  (setf (gethash name (runtime-evaluation-state-thunks
                        (runtime-session-evaluation session))) thunk))

(defun runtime-session-find-macro (session name)
  (gethash name (runtime-evaluation-state-macros (runtime-session-evaluation session))))

(defun runtime-session-set-macro (session name macro)
  (setf (gethash name (runtime-evaluation-state-macros
                        (runtime-session-evaluation session))) macro))

(defun runtime-session-next-gensym (session)
  (incf (runtime-evaluation-state-gensym (runtime-session-evaluation session))))

(defun runtime-session-find-domain (session name)
  (gethash name (runtime-domain-state-domains (runtime-session-domains session))))

(defun runtime-session-register-domain (session name entry)
  (setf (gethash name (runtime-domain-state-domains (runtime-session-domains session)))
        entry))

(defun runtime-session-register-probe (session name entry)
  (runtime-session-register-domain session name entry))

(defun runtime-session-fold-domains (session function initial)
  (let ((result initial))
    (maphash (lambda (name entry) (setf result (funcall function name entry result)))
             (runtime-domain-state-domains (runtime-session-domains session)))
    result))

(defun runtime-session-find-probe (session name)
  (gethash name (runtime-domain-state-probes (runtime-session-domains session))))

(defun runtime-session-set-probe (session name value)
  (setf (gethash name (runtime-domain-state-probes (runtime-session-domains session))) value))

(defun runtime-session-preseed-probe (session name value)
  (setf (gethash name (runtime-domain-state-preseeded-probes
                        (runtime-session-domains session))) value)
  (runtime-session-set-probe session name value))

(defun runtime-session-iter-probes (session function)
  (maphash function (runtime-domain-state-probes (runtime-session-domains session))))

(defun runtime-session-find-sealed-pin (session cell)
  (gethash cell (runtime-run-state-sealed-pins (runtime-session-run session))))

(defun runtime-session-set-sealed-pin (session cell hash)
  (setf (gethash cell (runtime-run-state-sealed-pins (runtime-session-run session))) hash))

(defun runtime-session-observations (session)
  (copy-list (runtime-run-state-observations (runtime-session-run session))))

(defun runtime-session-add-observation (session observation)
  (push observation (runtime-run-state-observations (runtime-session-run session))))

(defun runtime-session-clear-observations (session)
  (setf (runtime-run-state-observations (runtime-session-run session)) nil))

(defun runtime-session-add-event (session event)
  (push event (runtime-run-state-events (runtime-session-run session))))

(defun runtime-session-events (session)
  (nreverse (copy-list (runtime-run-state-events (runtime-session-run session)))))

(defun runtime-session-register-reporter (session reporter)
  (push reporter (runtime-run-state-reporters (runtime-session-run session))))

(defun runtime-session-reporters (session)
  (nreverse (copy-list (runtime-run-state-reporters (runtime-session-run session)))))

(defun runtime-session-set-runtime-manifest (session value)
  (setf (runtime-run-state-runtime-manifest (runtime-session-run session)) value))

(defun runtime-session-runtime-manifest (session)
  (runtime-run-state-runtime-manifest (runtime-session-run session)))

(defun runtime-session-add-wanted-node (session key)
  (setf (gethash (runtime-session-key key)
                 (runtime-run-state-wanted-nodes (runtime-session-run session))) t))

(defun runtime-session-wanted-nodes (session)
  (let (keys)
    (maphash (lambda (key ignored) (declare (ignore ignored)) (push key keys))
             (runtime-run-state-wanted-nodes (runtime-session-run session)))
    (sort keys #'string< :key (lambda (key) (if (stringp key) key (princ-to-string key))))))

(defun runtime-session-add-fenced-action (session action)
  (push action (runtime-fenced-state-fenced-actions (runtime-session-fenced session))))

(defun runtime-session-take-fenced-actions (session)
  (let* ((fenced (runtime-session-fenced session))
         (actions (nreverse (runtime-fenced-state-fenced-actions fenced))))
    (setf (runtime-fenced-state-fenced-actions fenced) nil)
    actions))

(defun runtime-session-find-run-pin (session cell)
  (gethash cell (runtime-run-state-run-pins (runtime-session-run session))))

(defun runtime-session-set-run-pin (session cell hash)
  (setf (gethash cell (runtime-run-state-run-pins (runtime-session-run session))) hash))

(defun runtime-session-preseed-run-pin (session cell hash)
  (setf (gethash cell (runtime-run-state-preseeded-run-pins (runtime-session-run session))) hash)
  (runtime-session-set-run-pin session cell hash))

(defun runtime-session-remove-run-pin (session cell)
  (remhash cell (runtime-run-state-run-pins (runtime-session-run session))))

(defun runtime-session-iter-run-pins (session function)
  (maphash function (runtime-run-state-run-pins (runtime-session-run session))))

(defun runtime-session-set-node-thunk (session key thunk)
  (let ((evaluation (runtime-session-evaluation session)))
    (setf (gethash (runtime-session-key key)
                   (runtime-evaluation-state-node-thunks evaluation)) thunk)
    (when (and (fboundp 'thunk-hash) (thunk-hash thunk))
      (setf (gethash (thunk-hash thunk)
                     (runtime-evaluation-state-node-keys evaluation)) key))))

(defun runtime-session-find-node-thunk (session key)
  (gethash (runtime-session-key key)
           (runtime-evaluation-state-node-thunks (runtime-session-evaluation session))))

(defun runtime-session-node-key (session thunk)
  (and (fboundp 'thunk-hash) (thunk-hash thunk)
       (gethash (thunk-hash thunk)
                (runtime-evaluation-state-node-keys (runtime-session-evaluation session)))))

(defun runtime-session-node-key-by-id (session id)
  (gethash id (runtime-evaluation-state-node-keys (runtime-session-evaluation session))))

(defun runtime-session-add-node-dependent (session id key)
  (let* ((table (runtime-evaluation-state-node-dependents
                 (runtime-session-evaluation session)))
         (key (runtime-session-key key))
         (existing (gethash id table)))
    (unless (member key existing :test #'equal)
      (setf (gethash id table) (cons key existing)))))

(defun runtime-session-iter-node-dependents (session function)
  (maphash function (runtime-evaluation-state-node-dependents
                     (runtime-session-evaluation session))))

(defun runtime-session-force-path (session)
  (copy-list (runtime-evaluation-state-force-path (runtime-session-evaluation session))))

(defun runtime-session-set-force-path (session path)
  (setf (runtime-evaluation-state-force-path (runtime-session-evaluation session))
        (copy-list path)))

(defun runtime-session-next-cache-bust (session)
  (incf (runtime-evaluation-state-cache-bust (runtime-session-evaluation session))))

(defun runtime-session-fenced-epoch (session)
  (runtime-fenced-state-fenced-epoch (runtime-session-fenced session)))

(defun runtime-session-start-fenced-epoch (session epoch)
  (let ((fenced (runtime-session-fenced session)))
    (setf (runtime-fenced-state-fenced-epoch fenced) epoch
          (runtime-fenced-state-fenced-epoch-recovered fenced) nil)))

(defun runtime-session-resume-fenced-epoch (session epoch)
  (let ((fenced (runtime-session-fenced session)))
    (setf (runtime-fenced-state-fenced-epoch fenced) epoch
          (runtime-fenced-state-fenced-epoch-recovered fenced) t)))

(defun runtime-session-clear-fenced-epoch (session)
  (let ((fenced (runtime-session-fenced session)))
    (setf (runtime-fenced-state-fenced-epoch fenced) ""
          (runtime-fenced-state-fenced-epoch-recovered fenced) nil)))

(defun runtime-session-next-fenced-epoch-nonce (session)
  (incf (runtime-fenced-state-fenced-epoch-nonce (runtime-session-fenced session))))

;;; Narrow compatibility spellings used by the evaluator/app integration.
(setf (symbol-function 'session-begin-evaluation) #'runtime-session-begin-evaluation)
(setf (symbol-function 'session-begin-pass) #'runtime-session-begin-pass)
(setf (symbol-function 'session-begin-watch) #'runtime-session-begin-watch)
(setf (symbol-function 'session-force) #'runtime-session-force)
(setf (symbol-function 'runtime-session-create) #'make-runtime-session)
(setf (symbol-function 'create-runtime-session) #'make-runtime-session)
(setf (symbol-function 'session-create) #'make-runtime-session)
(setf (symbol-function 'session-begin-evaluation) #'runtime-session-begin-evaluation)
