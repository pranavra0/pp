;;;; Persistent node execution, trace capture, and store callbacks.
(in-package #:pp.rt.node)



(defun runtime-node-error (message &optional (code "runtime.node"))
  (if (fboundp 'language-fail) (language-fail message code) (error "~A" message)))
(defun runtime-node-key-object (key)
  (handler-case
      (cond ((typep key 'node-key) key)
            ((typep key 'cache-key) (node-key-of-string (cache-key-to-string key)))
            ((stringp key) (node-key-of-string key))
            (t (runtime-node-error "node key is malformed" "runtime.node")))
    (error () (runtime-node-error "node key is malformed" "runtime.node"))))
(defun runtime-node-service (session name)
  (or (and (runtime-dynamic-current nil) (runtime-dynamic-find-service name))
      (and session (runtime-session-find-service session name))))
(defun runtime-node-repository (session name)
  (let ((service (runtime-node-service session name)))
    (unless service
      (runtime-node-error (format nil "runtime service is unavailable: ~A" name)
                          "runtime.service"))
    (if (functionp service) (funcall service) service)))
(defun runtime-node-authority-value-p (value &optional (seen nil))
  (when (member value seen :test #'eq) (return-from runtime-node-authority-value-p nil))
  (let ((seen (cons value seen)))
    (cond ((or (typep value 'value-capability) (typep value 'value-sealed)) t)
          ((typep value 'value-thunk)
           (runtime-node-authority-value-p
            (let ((s (thunk-status (value-thunk-thunk value))))
              (and (typep s 'thunk-status-evaluated) (thunk-status-evaluated-value s))) seen))
          ((typep value 'value-pair)
           (or (runtime-node-authority-value-p (value-pair-car value) seen)
               (runtime-node-authority-value-p (value-pair-cdr value) seen)))
          ((typep value 'value-vector) (some (lambda (x) (runtime-node-authority-value-p x seen)) (coerce (value-vector-values value) 'list)))
          ((typep value 'value-map) (some (lambda (e) (or (runtime-node-authority-value-p (car e) seen) (runtime-node-authority-value-p (cdr e) seen))) (value-map-entries value)))
          ((typep value 'value-set) (some (lambda (x) (runtime-node-authority-value-p x seen)) (value-set-values value)))
          ((typep value 'value-env-map) (some (lambda (e) (runtime-node-authority-value-p (cdr e) seen)) (value-env-map-bindings value)))
          ((typep value 'value-closure) (let ((c (value-closure-closure value)))
                                          (some (lambda (n) (let ((v (runtime-evaluator-env-lookup (closure-env c) n)))
                                                             (and v (runtime-node-authority-value-p v seen))))
                                                (free-variable-names (closure-body c)))))
          (t nil))))

(defun runtime-node-authority-kind (value &optional (seen nil))
  (when (member value seen :test #'eq)
    (return-from runtime-node-authority-kind nil))
  (let ((seen (cons value seen)))
    (cond
      ((typep value 'value-sealed) :sealed)
      ((typep value 'value-capability) :capability)
      ((typep value 'value-thunk)
       (let ((status (thunk-status (value-thunk-thunk value))))
         (and (typep status 'thunk-status-evaluated)
              (runtime-node-authority-kind
               (thunk-status-evaluated-value status) seen))))
      ((typep value 'value-pair)
       (or (runtime-node-authority-kind (value-pair-car value) seen)
           (runtime-node-authority-kind (value-pair-cdr value) seen)))
      ((typep value 'value-vector)
       (some (lambda (item) (runtime-node-authority-kind item seen))
             (coerce (value-vector-values value) 'list)))
      ((typep value 'value-map)
       (loop for entry in (value-map-entries value)
             thereis (or (runtime-node-authority-kind (car entry) seen)
                         (runtime-node-authority-kind (cdr entry) seen))))
      ((typep value 'value-set)
       (some (lambda (item) (runtime-node-authority-kind item seen))
             (value-set-values value)))
      ((typep value 'value-env-map)
       (loop for entry in (value-env-map-bindings value)
             thereis (runtime-node-authority-kind (cdr entry) seen)))
      ((typep value 'value-closure)
       (let ((closure (value-closure-closure value)))
         (some
          (lambda (name)
            (let ((item (runtime-evaluator-env-lookup
                         (closure-env closure) name)))
              (and item (runtime-node-authority-kind item seen))))
          (free-variable-names (closure-body closure)))))
      (t nil))))

(defun runtime-node-forced-free-variables (state thunk)
  (let ((env (thunk-environment thunk)) (out nil))
    (dolist (name (free-variable-names (thunk-expression thunk)) (nreverse out))
      (let ((value (runtime-evaluator-env-lookup env name)))
        (push (cons name
                    (if value
                        (handler-case
                            (runtime-evaluator-force state value)
                          (language-error () (runtime-evaluator-error "free variable could not be forced" "evaluator.node")))
                        nil)) out)))))
(defmethod runtime-node-key-of-state (state thunk)
  (let ((free (runtime-node-forced-free-variables state thunk)))
    (dolist (entry free)
      (let ((kind (and (cdr entry)
                       (runtime-node-authority-kind (cdr entry)))))
        (when kind
          (runtime-node-error
           (format nil
                   (cond ((eq kind :sealed)
                          "node: free variable '~A' may not be or contain a sealed value")
                         ((eq kind :capability)
                          "node: free variable '~A' may not be or contain a capability")
                         (t
                          "node: free variable '~A' may not be or contain authority"))
                   (car entry))
           "runtime.authority"))))
    (node-key :code (thunk-expression thunk) :free-variables free
              :argument-values (if (typep (thunk-kind thunk) 'thunk-kind-persistent)
                                   (thunk-kind-persistent-argument-values (thunk-kind thunk)) nil))))
(defun runtime-node-key (state thunk) (runtime-node-key-of-state state thunk))
(defun runtime-node-data-closed-p (state thunk)
  (every (lambda (entry) (or (null (cdr entry)) (durable-value-p (cdr entry))))
         (runtime-node-forced-free-variables state thunk)))

(defun runtime-node-record-child (session child-key value)
  (let ((parent (runtime-dynamic-current-node)))
    (when (and parent
               (runtime-node-frame-persistent parent)
               (not (string= (store-identity-string child-key)
                             (store-identity-string
                              (runtime-node-frame-key parent)))))
      (runtime-dynamic-record-read
       (cell-serialize
        (make-cell-node (store-identity-string child-key)))
       (hash-value value))
      (when (and session (fboundp 'thunk-hash))
        (let ((child-thunk (runtime-session-find-node-thunk session child-key)))
          (when child-thunk
            (runtime-session-add-node-dependent
             session (or (thunk-hash child-thunk)
                         (store-identity-string child-key))
             (runtime-node-frame-key parent))))))))
(defmethod runtime-node-engine-force (session state thunk run &key observer)
  "Canonical persistent-node entry used by the evaluator.

OBSERVER, when supplied, receives :hit or :rebuilt for THIS force.
Disposition is an explicit result argument, never ambient hook state."
  (unless session
    (runtime-node-error "persistent node requires a runtime session"
                        "runtime.node"))
  (let* ((key (runtime-node-key-of-state state thunk))
         ;; One injection path: the session's :node-force service (which
         ;; placement/scheduling may replace) in front of the canonical
         ;; engine.  The evaluator never sees a mutable callback.
         (service (runtime-session-find-service session :node-force))
         (result (if service
                     (funcall service state thunk key run observer)
                     (runtime-node-force-with-session
                      session state thunk key run observer))))
    (setf (thunk-status thunk) (make-thunk-status-evaluated result))
    result))
(defmethod runtime-node-engine-invalidate (session keys)
  "Invalidate in-memory node memo state; durable traces remain authoritative."
  (dolist (key keys)
    (let ((thunk (runtime-session-find-node-thunk session key)))
      (when thunk
        (setf (thunk-status thunk) (make-thunk-status-unevaluated)))))
  keys)
(defun runtime-node-serve-hit (thunk result &optional key session)
  (cond ((runtime-cache-hit-ok-p result)
         (let ((value (runtime-cache-result-value result)))
           (when (and key session) (runtime-node-record-child session key value))
           (setf (thunk-status thunk) (make-thunk-status-evaluated value))
           value))
        ((runtime-cache-hit-failed-p result)
         (let ((value (runtime-cache-result-value result)))
           (when (and key session) (runtime-node-record-child session key value))
           (runtime-node-error
            (if (typep value 'value-string)
                (value-string-value value)
                "node failed (cached)")
            "runtime.node.failed")))
        (t nil)))

(defun runtime-node-captured-capabilities (thunk)
  (let ((kind (thunk-kind thunk)))
    (unless (typep kind 'thunk-kind-persistent)
      (runtime-node-error "persistent node has no captured authority"
                          "runtime.authority"))
    ;; NIL is a valid capture: it means the node was created with no
    ;; capabilities, not that forcing may recapture the caller's scope.
    (copy-list (thunk-kind-persistent-captured-caps kind))))
(defun runtime-node-persist (session key value outcome reads)
  (unless (durable-value-p value)
    (runtime-node-error "persistent node result contains authority or code"
                        "runtime.authority"))
  (let ((objects (runtime-node-repository session :store-objects))
        (traces (runtime-node-repository session :store-traces)))
    (runtime-store-put-node-result
     objects traces (runtime-node-key-object key) value outcome reads)))
(defun runtime-node-observed-cell-id (id)
  (let ((observed (runtime-observe-id id)))
    (and observed
         (if (store-digest-p observed)
             observed
             (pp.kernel:hash-string observed)))))

(defun runtime-node-noncacheable-failure-p (condition)
  (let ((code (and (typep condition 'language-error)
                   (language-error-code condition))))
    (and (stringp code)
         (member code
                 '("runtime.authority" "evaluator.authority"
                   "runtime.capability" "evaluator.capability")
                 :test #'string=))))

(defun runtime-node-check-determinism (policy key captured-capabilities run value)
  (when (and (runtime-cache-check-enabled-p policy)
             (durable-value-p value))
    (let* ((second-reads nil)
           (second-collector
            (lambda (ignored-session cell-id hash)
              (declare (ignore ignored-session))
              (let* ((cell-id (runtime-observation-cell-id
                               (cell-parse (store-identity-string cell-id))))
                     (observed (store-identity-string hash))
                     (observed (if (store-digest-p observed)
                                   observed
                                   (pp.kernel:hash-string observed)))
                     (pair (cons cell-id observed)))
                (unless (find pair second-reads :test #'equal)
                  (push pair second-reads))))))
      (let ((second
              (runtime-dynamic-with-capabilities
               captured-capabilities
               (lambda ()
                 (runtime-dynamic-with-service
                  :record-read second-collector
                  (lambda ()
                    (runtime-dynamic-with-node
                     (make-runtime-node-frame :key key :persistent t)
                     run)))))))
        (unless (string= (store-identity-string (hash-value value))
                         (store-identity-string (hash-value second)))
          (runtime-cache-note-volatile policy)
          (runtime-cache-event "node-cache" key "volatile")
          (runtime-cache-diagnose
           policy
           (format nil
                   "node ~A: volatile — an identical run produced a different result hash"
                   (runtime-cache-short-key key))))))))

(defun runtime-node-force-in-scope (session state thunk key run observer)
  (declare (ignore state))
  (let* ((key (runtime-node-key-object key))
         (captured-capabilities (runtime-node-captured-capabilities thunk))
         (parent (runtime-dynamic-current-node)))
    (when session (runtime-session-set-node-thunk session key thunk))
    (let* ((traces (runtime-node-repository session :store-traces))
         (objects (runtime-node-repository session :store-objects))
         (blobs (runtime-node-repository session :store-blobs))
         (policy-service (runtime-node-service session :cache-policy))
         (policy (if (functionp policy-service)
                     (funcall policy-service)
                     (or policy-service (runtime-cache-policy-create))))
         (authorized
           (lambda (id)
             (runtime-observation-authorized-p
              captured-capabilities
              (cell-parse (cell-id-to-string id)))))
         (hit (runtime-cache-lookup
               :policy policy :traces traces :objects objects :blobs blobs
               :key key :observe-id #'runtime-node-observed-cell-id
               :replay #'runtime-observation-replay :authorized authorized)))
    (when (runtime-cache-result-hit-p hit)
      (let ((served (runtime-node-serve-hit thunk hit key session)))
        (when (and served observer) (funcall observer :hit))
        (return-from runtime-node-force-in-scope served)))
    (setf (thunk-status thunk) (make-thunk-status-evaluating))
    (let* ((reads nil)
           (collector
             (lambda (ignored-session cell-id hash)
               (declare (ignore ignored-session))
               (let* ((cell-id (runtime-observation-cell-id
                                (cell-parse (store-identity-string cell-id))))
                      (observed (store-identity-string hash))
                      (observed (if (store-digest-p observed)
                                    observed
                                    (pp.kernel:hash-string observed)))
                      (pair (cons cell-id observed)))
                 (unless (find pair reads :test #'equal)
                   (push pair reads))))))
      (handler-case
          (let* ((caller-caps
                   (copy-list (runtime-dynamic-capabilities)))
                 (value
                   (runtime-dynamic-with-capabilities
                    captured-capabilities
                    (lambda ()
                      (runtime-dynamic-with-service
                       :record-read collector
                       (lambda ()
                         (runtime-dynamic-with-node
                          (make-runtime-node-frame :key key :persistent t)
                          run)))))))
            (runtime-dynamic-replace-top-capability-frame! caller-caps)
            (let ((authority-kind (runtime-node-authority-kind value)))
              (when authority-kind
                (runtime-node-error
                 (if (eq authority-kind :sealed)
                     "a node may not return a sealed value"
                     "a node may not return a capability")
                 "runtime.authority")))
            ;; Executable results are process-local.  Return them to the
            ;; caller, but do not publish an object or trace for them.
            (when (durable-value-p value)
              (when parent (runtime-node-record-child session key value))
              (runtime-node-persist session key value :ok (nreverse reads))
              (setf (thunk-status thunk) (make-thunk-status-evaluated value))
              (runtime-node-check-determinism
               policy key captured-capabilities run value))
            (unless (durable-value-p value)
              (setf (thunk-status thunk) (make-thunk-status-evaluated value)))
            (when observer (funcall observer :rebuilt))
            value)
        (language-error (condition)
          (setf (thunk-status thunk) (make-thunk-status-unevaluated))
          (let ((message (language-error-message condition)))
            (unless (runtime-node-noncacheable-failure-p condition)
              (let ((failure (make-vstring message)))
                (when parent (runtime-node-record-child session key failure))
                (runtime-node-persist session key failure :failed
                                      (nreverse reads))))
            (error condition)))
        (error (condition)
          (setf (thunk-status thunk) (make-thunk-status-unevaluated))
          (error condition)))))))

(defun runtime-node-force-with-session (session state thunk key run observer)
  (if (runtime-dynamic-current nil)
      (runtime-node-force-in-scope session state thunk key run observer)
      (runtime-dynamic-with-top-level
       session
       (lambda () (runtime-node-force-in-scope
                   session state thunk key run observer)))))

(defun runtime-node-call (session function arguments &key observer)
  "Run FUNCTION over ARGUMENTS as one persistent node.

The Node Engine owns every mechanic here: AST application, thunk
manufacture, cache lookup, execution, and durable persistence.  Reconcile
supplies only the pure computation and an optional disposition OBSERVER
receiving :hit or :rebuilt for THIS force."
  (runtime-dynamic-with-capabilities
   nil
   (lambda ()
     (let* ((state (runtime-session-evaluator session))
            (environment (runtime-session-global-env session))
            (expression
              (make-eapply
               (make-eliteral function)
               (mapcar #'make-eliteral arguments)))
            (thunk
              (runtime-evaluator-make-thunk
               expression environment
               :kind (make-persistent-thunk-kind nil arguments)))
            (run
              (lambda ()
                ;; Deep-force before the node boundary persists/wraps the
                ;; result: a lazy body may return unevaluated thunks.
                (runtime-evaluator-force-deep
                 (runtime-session-evaluator session)
                 (runtime-evaluator-run-expression
                  state expression environment)))))
       (runtime-node-engine-force session state thunk run
                                  :observer observer)))))

(defmethod runtime-node-install-session (session layout)
  (runtime-store-with-repositories
   layout
   (lambda (layout objects blobs traces cells)
     (declare (ignore layout))
     (runtime-session-register-service session :store-objects (lambda () objects))
     (runtime-session-register-service session :store-blobs (lambda () blobs))
     (runtime-session-register-service session :store-traces (lambda () traces))
     (runtime-session-register-service session :store-cells (lambda () cells))
     (let ((policy (runtime-cache-policy-create)))
       (runtime-session-register-service session :cache-policy (lambda () policy)))
     (runtime-session-register-service
      session :node-force
      (lambda (state thunk key run observer)
        ;; Track every forced node as a GC root.  The scheduler pins this
        ;; service as its base, so recording survives placement replacement.
        (when key (runtime-session-add-wanted-node session key))
        (runtime-node-force-with-session session state thunk key run observer)))
     session)))
