;;;; Generic observe/diff/apply/verify lifecycle.
(in-package #:pp.rt.domain)

(defstruct (runtime-domain-target
            (:constructor make-runtime-domain-target (name entry desired)))
  name entry desired)
(defstruct (runtime-domain-observed
            (:constructor make-runtime-domain-observed (target state))) target state)
(defstruct (runtime-domain-planned
            (:constructor make-runtime-domain-planned (observed plan summary)))
  observed plan summary)
(defstruct (runtime-domain-pass
            (:constructor make-runtime-domain-pass (invocation forced-desired targets)))
  invocation forced-desired targets)

(defun runtime-domain-force (session value)
  (cond ((and (fboundp 'runtime-evaluator-force-deep)
              (runtime-session-evaluator session))
         (runtime-evaluator-force-deep (runtime-session-evaluator session) value))
        ((and (fboundp 'runtime-session-force) (runtime-session-evaluator session))
         (runtime-session-force session value))
        (t value)))

(defun runtime-domain-string (value)
  (cond ((typep value 'pp.kernel:value-string) (value-string-value value))
        ((typep value 'pp.kernel:value-keyword) (value-keyword-value value))
        ((typep value 'pp.kernel:value-symbol) (value-symbol-value value))
        ((stringp value) value)
        (t nil)))

(defun runtime-domain-map (value)
  (if (typep value 'pp.kernel:value-map)
      (value-map-entries value)
      (error "domain value must be a map, got ~A" value)))

(defun runtime-domain-service-value (session name)
  (let ((service (runtime-session-find-service session name)))
    (and service
         (if (functionp service) (funcall service) service))))
(defun runtime-domain-find (entries name)
  (find-if (lambda (entry)
             (let ((key (runtime-domain-string (car entry))))
               (and key (string= key name)))) entries))

;; Plan policy travels with the registered domain value, not with global
;; generic methods: installing a domain affects exactly one session.  NIL
;; closures fall back to fail-closed defaults — an opaque plan is
;; unrecognized (refused before apply) and unconverged (refuses verify).
(defun runtime-domain-plan-recognized-p (entry plan)
  (let ((valid (runtime-domain-entry-plan-valid-p entry)))
    (if valid (funcall valid plan)
        (typep plan 'pp.kernel:value-map))))

(defun runtime-domain-plan-converged-p (session entry plan)
  (let ((converged (runtime-domain-entry-converged-p entry)))
    (cond (converged (funcall converged session plan))
          ((typep plan 'pp.kernel:value-map)
           (runtime-domain-plan-items-empty-p session plan))
          (t (error "reconcile: no convergence check for plan of type ~A"
                    (type-of plan))))))

(defun runtime-domain-plan-items-empty-p (session plan)
  (let ((items (cdr (runtime-domain-find (runtime-domain-map
                                          (runtime-domain-force session plan))
                                         "items"))))
    (cond ((null items) t)
          ((typep items 'pp.kernel:value-nil) t)
          ((typep items 'pp.kernel:value-vector)
           (zerop (length (value-vector-values items))))
          ((typep items 'pp.kernel:value-pair) nil)
          (t (error "domain diff: :items must be a list or vector")))))

(defun runtime-domain-summary-pair (session value)
  (let ((value (runtime-domain-force session value)))
    (cond
      ((typep value 'pp.kernel:value-vector)
       (let ((values (value-vector-values value)))
         (unless (= (length values) 2)
           (error "domain diff: summary entries must have two values"))
         (values (runtime-domain-string (aref values 0))
                 (runtime-domain-string (runtime-domain-force session (aref values 1))))) )
      ((and (typep value 'pp.kernel:value-pair)
            (typep (runtime-domain-force session (value-pair-cdr value))
                   'pp.kernel:value-pair))
       (let* ((tail (runtime-domain-force session (value-pair-cdr value)))
              (end (runtime-domain-force session (value-pair-cdr tail))))
         (unless (typep end 'pp.kernel:value-nil)
           (error "domain diff: summary pair list is not terminated"))
         (values (runtime-domain-string
                  (runtime-domain-force session (value-pair-car value)))
                 (runtime-domain-string
                  (runtime-domain-force session (value-pair-car tail))))))
      (t (error "domain diff: summary entry is not a pair")))))

(defun runtime-domain-plan-summary (session plan)
  (unless (typep plan 'pp.kernel:value-map)
    (return-from runtime-domain-plan-summary nil))
  (let ((entry (runtime-domain-find
                (runtime-domain-map (runtime-domain-force session plan)) "summary")))
    (unless entry (return-from runtime-domain-plan-summary nil))
    (let ((summary (runtime-domain-force session (cdr entry))))
      (cond
        ((typep summary 'pp.kernel:value-nil) nil)
        ((typep summary 'pp.kernel:value-vector)
         (loop for item across (value-vector-values summary)
               collect (multiple-value-bind (key value)
                           (runtime-domain-summary-pair session item)
                         (cons key value))))
        ((typep summary 'pp.kernel:value-pair)
         (labels ((collect (value)
                    (let ((value (runtime-domain-force session value)))
                      (cond ((typep value 'pp.kernel:value-nil) nil)
                            ((typep value 'pp.kernel:value-pair)
                             (cons (multiple-value-bind (key text)
                                       (runtime-domain-summary-pair
                                        session (value-pair-car value))
                                     (cons key text))
                                   (collect (value-pair-cdr value))))
                            (t (error "domain diff: summary is not a proper list"))))))
           (collect summary)))
        (t (error "domain diff: summary must be a list or vector"))))))

(defun runtime-domain-plan-cache-key (diff observed desired)
  (pp.kernel:hash-concat
   (list "domain-plan"
         (pp.kernel:hash-value diff)
         (pp.kernel:hash-value observed)
         (pp.kernel:hash-value desired))))


(defun runtime-domain-cache-plan (session name diff observed desired)
  (if (functionp diff)
      (runtime-domain-call session diff (list observed desired))
      ;; The diff is a pp closure: force it as a persistent node so the
      ;; plan is cached on (diff code, observed, desired).  Diffs are pure:
      ;; the thunk captures an EMPTY capability set.
      (let ((key-text (runtime-domain-plan-cache-key diff observed desired)))
        (runtime-node-call
         session diff (list observed desired)
         :observer
         (lambda (disposition)
           (when (eq disposition :hit)
             (format *error-output* "domain ~A: plan ~A: hit~%"
                     name key-text)
             (finish-output *error-output*)))))))

(defun runtime-domain-call (session function arguments)
  (cond ((functionp function) (apply function arguments))
        ((and session (fboundp 'runtime-session-call))
         (runtime-session-call session function arguments
                               (runtime-session-global-env session)))
        (t (error "domain callback is unavailable"))))

(defun runtime-domain-with-domain (entry name thunk)
  (let ((cap (runtime-domain-entry-cap entry)))
    (runtime-dynamic-with-domain name
      (lambda ()
        (if cap
            (runtime-dynamic-with-capabilities (list cap) thunk)
            (funcall thunk))))))

(defun runtime-domain-call-uncached (session entry name function arguments)
  (let ((invoke (lambda () (runtime-domain-call session function arguments))))
    (runtime-domain-with-domain
     entry name
     (lambda ()
       (if (fboundp 'runtime-dynamic-with-config)
           (runtime-dynamic-with-config
            (make-vmap
             (list (cons (make-vstring "__pp_q13_cache_bust")
                         (make-vint (runtime-session-next-cache-bust session)))))
            invoke))))))

(defun runtime-domain-observe (session target)
  (let* ((entry (runtime-domain-target-entry target))
         (callback (runtime-domain-entry-observe entry)))
    (unless callback (error "domain has no observe callback"))
    (make-runtime-domain-observed
     target
     (runtime-domain-call-uncached session entry
                                    (runtime-domain-target-name target)
                                    callback nil))))

(defun runtime-domain-diff (session observed)
  (let* ((target (runtime-domain-observed-target observed))
         (entry (runtime-domain-target-entry target))
         (callback (runtime-domain-entry-diff entry)))
    (unless callback (error "domain has no diff callback"))
    (let* ((plan (runtime-domain-cache-plan
                  session (runtime-domain-target-name target) callback
                  (runtime-domain-observed-state observed)
                  (runtime-domain-target-desired target)))
           (planned (make-runtime-domain-planned
                     observed plan (runtime-domain-plan-summary session plan))))
      ;; Fail closed BEFORE apply mutates the world.
      (unless (runtime-domain-plan-recognized-p entry plan)
        (error "reconcile: domain '~A' produced a plan of unrecognized type ~A"
               (runtime-domain-target-name target) (type-of plan)))
      planned)))

(defun runtime-domain-apply (session planned)
  (let* ((observed (runtime-domain-planned-observed planned))
         (target (runtime-domain-observed-target observed))
         (entry (runtime-domain-target-entry target))
         (callback (runtime-domain-entry-apply entry))
         (summary (or (runtime-domain-planned-summary planned)
                      (list (cons "result" "opaque"))))
         (hash (pp.kernel:hash-concat
                (list "domain-pass" (runtime-domain-target-name target)
                      (pp.kernel:hash-value
                       (runtime-domain-target-desired target))))))
    (unless callback (error "domain has no apply callback"))
    (runtime-journal-append
     session (make-runtime-journal-domain-intent hash summary))
    (runtime-domain-with-domain
     entry (runtime-domain-target-name target)
     (lambda ()
       (runtime-domain-call-uncached session entry
                                     (runtime-domain-target-name target)
                                     callback
                                     (list (runtime-domain-planned-plan planned)))))
    (runtime-journal-append session (make-runtime-journal-domain-done hash))
    (format *error-output* "[reconcile:~A] ~{~A~^ ~}~%"
            (runtime-domain-target-name target)
            (mapcar (lambda (pair)
                      (format nil "~A=~A" (car pair) (cdr pair)))
                    summary))
    (finish-output *error-output*)
    planned))

(defun runtime-domain-verify (session planned)
  (let* (
         (target (runtime-domain-observed-target
                  (runtime-domain-planned-observed planned)))
         (entry (runtime-domain-target-entry target))
         (second (runtime-domain-diff
                  session (runtime-domain-observe session target))))
    (unless (runtime-domain-plan-converged-p
             session entry (runtime-domain-planned-plan second))
      (error "reconcile: verify-after-write failed for domain ~A"
             (runtime-domain-target-name target)))
    t))

(defun runtime-domain-run-target (session target)
  (let ((planned (runtime-domain-diff session
                                      (runtime-domain-observe session target))))
    (runtime-domain-apply session planned)
    (runtime-domain-verify session planned)
    planned))

(defun runtime-domain-prefix-p (prefix value)
  (and (stringp prefix) (stringp value)
       (>= (length value) (length prefix))
       (string= prefix value :end2 (length prefix))))

(defun runtime-domain-stratification-check (session targets)
  (dolist (observation (runtime-session-observations session))
    (let ((cell (car observation)))
      (dolist (target targets)
        (when (some (lambda (prefix) (runtime-domain-prefix-p prefix cell))
                    (runtime-domain-entry-namespace
                     (runtime-domain-target-entry target)))
          (error "reconcile: stratification violation (LAW 30): the desired state for domain '~A' observed its own domain: ~A"
                 (runtime-domain-target-name target) cell))))))

(defun runtime-domain-prepare-pass (session invocation desired)
  (let* ((forced (runtime-domain-force session desired))
         (entries (runtime-domain-map forced))
         (targets nil))
    (dolist (entry entries)
      (let ((name (runtime-domain-string (car entry))))
        (unless name (error "reconcile: domain name must be a string or keyword"))
        (let ((domain (runtime-session-find-domain session name)))
          (unless domain (error "reconcile: no domain registered under name '~A'" name))
          (unless (and (runtime-domain-entry-diff domain)
                       (runtime-domain-entry-apply domain))
            (error "reconcile: domain '~A' has no diff/apply" name))
          (push (make-runtime-domain-target name domain (cdr entry)) targets))))
    (setf targets (nreverse targets))
    (runtime-domain-stratification-check session targets)
    (make-runtime-domain-pass invocation forced targets)))

(defun runtime-domain-invocation-keep (invocation)
  (cond ((and (listp invocation) (getf invocation :keep-epochs))
         (getf invocation :keep-epochs))
        ((and (numberp invocation) (>= invocation 0)) invocation)
        (t 0)))

(defun runtime-domain-record-epoch (session invocation forced)
  (let ((hash (pp.kernel:hash-value forced))
        (layout (and (fboundp 'runtime-session-store-layout)
                     (runtime-session-store-layout session))))
    (when (and layout (fboundp 'object-repository-put)
               (runtime-session-find-service session :store-objects))
      (object-repository-put
       (runtime-domain-service-value session :store-objects)
       :key hash :value forced)
      (runtime-journal-append session (make-runtime-journal-epoch hash))
      (when (fboundp 'gc-roots-record)
        (gc-roots-record
         layout (make-store-gc-root hash (runtime-session-wanted-nodes session))
         :keep (runtime-domain-invocation-keep invocation))))
    hash))

(defun runtime-domain-run-pass (session pass)
  (dolist (target (runtime-domain-pass-targets pass))
    (runtime-domain-run-target session target))
  (runtime-domain-record-epoch session
                               (runtime-domain-pass-invocation pass)
                               (runtime-domain-pass-forced-desired pass))
  pass)

(defun runtime-domain-any-write-domain-registered-p (session)
  (runtime-session-fold-domains
   session (lambda (name entry result)
             (declare (ignore name))
             (or result (and (runtime-domain-entry-diff entry)
                             (runtime-domain-entry-apply entry))))
   nil))

