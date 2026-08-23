;;;; Persistent node execution, trace capture, and store callbacks.
(in-package #:pp.runtime)

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
(defun runtime-node-persistent-value-p (value &optional (seen nil))
  (when (member value seen :test #'eq) (return-from runtime-node-persistent-value-p t))
  (let ((seen (cons value seen)))
    (cond ((or (typep value 'value-capability) (typep value 'value-sealed)
               (typep value 'value-closure) (typep value 'value-builtin)
               (typep value 'value-thunk)) nil)
          ((typep value 'value-pair) (and (runtime-node-persistent-value-p (value-pair-car value) seen) (runtime-node-persistent-value-p (value-pair-cdr value) seen)))
          ((typep value 'value-vector) (every (lambda (x) (runtime-node-persistent-value-p x seen)) (coerce (value-vector-values value) 'list)))
          ((typep value 'value-map) (every (lambda (e) (and (runtime-node-persistent-value-p (car e) seen) (runtime-node-persistent-value-p (cdr e) seen))) (value-map-entries value)))
          ((typep value 'value-set) (every (lambda (x) (runtime-node-persistent-value-p x seen)) (value-set-values value)))
          ((typep value 'value-env-map) (every (lambda (e) (runtime-node-persistent-value-p (cdr e) seen)) (value-env-map-bindings value)))
          (t t))))

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
(defun runtime-node-key-of (state thunk)
  (let ((free (runtime-node-forced-free-variables state thunk)))
    (dolist (entry free)
      (let ((kind (and (cdr entry)
                       (runtime-node-authority-kind (cdr entry)))))
        (when kind
          (runtime-node-error
           (format nil
                   (if (eq kind :sealed)
                       "node: free variable '~A' may not be or contain a sealed value"
                       "node: free variable '~A' may not be or contain authority")
                   (car entry))
           "runtime.authority"))))
    (node-key :code (thunk-expression thunk) :free-variables free
              :argument-values (if (typep (thunk-kind thunk) 'thunk-kind-persistent)
                                   (thunk-kind-persistent-argument-values (thunk-kind thunk)) nil))))
(defun runtime-node-key (state thunk) (runtime-node-key-of state thunk))
(defun runtime-node-data-closed-p (state thunk)
  (every (lambda (entry) (or (null (cdr entry)) (runtime-node-persistent-value-p (cdr entry))))
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
  (unless (runtime-node-persistent-value-p value)
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
             (runtime-node-persistent-value-p value))
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

(defun runtime-node-force-in-scope (session state thunk key run)
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
      (return-from runtime-node-force-in-scope
        (runtime-node-serve-hit thunk hit key session)))
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
          (let ((value
                  (runtime-dynamic-with-capabilities
                   captured-capabilities
                   (lambda ()
                     (runtime-dynamic-with-service
                      :record-read collector
                      (lambda ()
                        (runtime-dynamic-with-node
                         (make-runtime-node-frame :key key :persistent t)
                         run)))))))
            (let ((authority-kind (runtime-node-authority-kind value)))
              (when authority-kind
                (runtime-node-error
                 (if (eq authority-kind :sealed)
                     "a node may not return a sealed value"
                     "a node may not return a capability")
                 "runtime.authority")))
            ;; Executable results are process-local.  Return them to the
            ;; caller, but do not publish an object or trace for them.
            (when (runtime-node-persistent-value-p value)
              (when parent (runtime-node-record-child session key value))
              (runtime-node-persist session key value :ok (nreverse reads))
              (setf (thunk-status thunk) (make-thunk-status-evaluated value))
              (runtime-node-check-determinism
               policy key captured-capabilities run value))
            (unless (runtime-node-persistent-value-p value)
              (setf (thunk-status thunk) (make-thunk-status-evaluated value)))
            value)
        (language-error (condition)
          (setf (thunk-status thunk) (make-thunk-status-unevaluated))
          (let ((message (language-error-message condition)))
            (unless (runtime-node-noncacheable-failure-p condition)
              (let ((failure (make-vstring message)))
                (when parent (runtime-node-record-child session key failure))
                (runtime-node-persist session key failure :failed
                                       (nreverse reads)))))
          (error condition))
        (error (condition)
          (setf (thunk-status thunk) (make-thunk-status-unevaluated))
          (error condition)))))))

(defun runtime-node-force-with-session (session state thunk key run)
  (if (runtime-dynamic-current nil)
      (runtime-node-force-in-scope session state thunk key run)
      (runtime-dynamic-with-top-level session (lambda () (runtime-node-force-in-scope session state thunk key run)))))
(defun runtime-node-force-callback (session state thunk key run)
  (runtime-node-force-with-session session state thunk key run))
(defun runtime-node-force (session state thunk key run)
  (runtime-node-force-with-session session state thunk key run))

(defun runtime-node-install-session (session layout)
  (when (fboundp 'runtime-effects-install-session)
    (runtime-effects-install-session session))
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
     (runtime-session-register-callback
      session :node-force
      (lambda (state thunk key run) (runtime-node-force-callback session state thunk key run))
      )
     session)))
(defun node-key-of (state thunk) (runtime-node-key-of state thunk))
(defun node-force-persistent (session state thunk key run)
  (runtime-node-force session state thunk key run))
(defun node-serve-hit (thunk result) (runtime-node-serve-hit thunk result))
