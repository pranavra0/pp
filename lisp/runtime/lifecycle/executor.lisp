;;;; Closed execution boundary. Providers are trusted only through classification.
(in-package #:pp.runtime)

(defstruct (runtime-executor-request
            (:constructor make-runtime-executor-request
                (&key tool tool-path arguments inputs environment platform policy outputs)))
  tool tool-path arguments inputs environment platform policy outputs)
(defstruct (runtime-executor-result
            (:constructor make-runtime-executor-result
                (&key exit-status stdout stderr outputs evidence resources)))
  exit-status stdout stderr outputs evidence resources)
(defstruct (runtime-executor-cacheable (:constructor make-runtime-executor-cacheable ())))
(defstruct (runtime-executor-scripting-only
            (:constructor make-runtime-executor-scripting-only (reason))) reason)
(defstruct (runtime-executor
            (:constructor %make-runtime-executor (classify execute))) classify execute)

(defun make-runtime-executor (&key classify execute)
  (unless (functionp classify) (error "executor classifier is unavailable"))
  (unless (functionp execute) (error "executor provider is unavailable"))
  (%make-runtime-executor classify execute))

(defun runtime-executor-classification-cacheable-p (value)
  (or (typep value 'runtime-executor-cacheable)
      (eq value :cacheable) (eq value 'cacheable)))

(defun runtime-executor-classification-scripting-only-p (value)
  (or (typep value 'runtime-executor-scripting-only)
      (and (consp value) (eq (car value) :scripting-only))))

(defun runtime-executor-classification-reason (value)
  (cond ((typep value 'runtime-executor-scripting-only)
         (runtime-executor-scripting-only-reason value))
        ((and (consp value) (cdr value)) (princ-to-string (cdr value)))
        (t "provider did not promise deterministic execution")))
(defun runtime-executor-request-data-p (value &optional (seen nil))
  (when (member value seen :test #'eq) (return-from runtime-executor-request-data-p nil))
  (let ((seen (cons value seen)))
    (typecase value
      (null t)
      (pp.kernel:value-nil t) (pp.kernel:value-bool t)
      (pp.kernel:value-int t) (pp.kernel:value-float t)
      (pp.kernel:value-string t) (pp.kernel:value-keyword t)
      (pp.kernel:value-symbol t)
      (pp.kernel:value-pair
       (and (runtime-executor-request-data-p (value-pair-car value) seen)
            (runtime-executor-request-data-p (value-pair-cdr value) seen)))
      (pp.kernel:value-vector
       (every (lambda (item) (runtime-executor-request-data-p item seen))
              (coerce (value-vector-values value) 'list)))
      (pp.kernel:value-map
       (every (lambda (entry)
                (and (runtime-executor-request-data-p (car entry) seen)
                     (runtime-executor-request-data-p (cdr entry) seen)))
              (value-map-entries value)))
      (pp.kernel:value-set
       (every (lambda (item) (runtime-executor-request-data-p item seen))
              (value-set-values value)))
      (t nil))))

(defun runtime-executor-sorted-pairs (pairs label)
  (unless (listp pairs) (error "run-closed!: ~A metadata is not a list" label))
  (let ((copy (copy-list pairs)))
    (dolist (pair copy)
      (unless (and (consp pair) (stringp (car pair)) (stringp (cdr pair)))
        (error "run-closed!: invalid ~A metadata" label))
      (when (or (zerop (length (car pair)))
                (find #\Null (car pair)) (find #\Null (cdr pair)))
        (error "run-closed!: invalid ~A metadata" label)))
    (setf copy (sort copy #'string< :key #'car))
    (loop for tail on copy while (cdr tail) do
      (when (string= (car (first tail)) (car (second tail)))
        (error "run-closed!: executor returned duplicate ~A name: ~A"
               label (car (first tail)))))
    copy))

(defun runtime-executor-validate-result (result)
  (unless (typep result 'runtime-executor-result)
    (error "run-closed!: executor returned an invalid result"))
  (unless (and (integerp (runtime-executor-result-exit-status result))
               (<= 0 (runtime-executor-result-exit-status result)))
    (error "run-closed!: executor returned an invalid exit status"))
  (unless (and (stringp (runtime-executor-result-stdout result))
               (stringp (runtime-executor-result-stderr result)))
    (error "run-closed!: executor returned non-string output"))
  (runtime-executor-sorted-pairs
   (runtime-executor-result-evidence result) "evidence")
  (let ((validator (and (fboundp 'runtime-artifact-tree-validate)
                        (symbol-function 'runtime-artifact-tree-validate))))
    (unless validator (error "run-closed!: artifact tree validator is unavailable"))
    (funcall validator (runtime-executor-result-outputs result)))
  result)

(defun runtime-executor-classify-request (executor request)
  (let ((classification (funcall (runtime-executor-classify executor) request)))
    (unless (or (runtime-executor-classification-cacheable-p classification)
                (runtime-executor-classification-scripting-only-p classification))
      (error "run-closed!: executor returned no cacheability classification"))
    classification))

(defun runtime-executor-run (executor request &key (in-node nil))
  (unless (typep executor 'runtime-executor)
    (error "run-closed!: executor service is unavailable"))
  (unless (typep request 'runtime-executor-request)
    (error "run-closed!: invalid request"))
  (unless (and (stringp (runtime-executor-request-tool-path request))
               (every #'stringp (runtime-executor-request-arguments request))
               (every (lambda (pair) (and (consp pair) (stringp (car pair))
                                           (stringp (cdr pair))))
                      (runtime-executor-request-environment request))
               (every #'stringp (runtime-executor-request-outputs request))
               (runtime-executor-request-data-p
                (runtime-executor-request-policy request)))
    (error "run-closed!: request is not canonical data"))
  (let ((classification (runtime-executor-classify-request executor request)))
    (when (and in-node (runtime-executor-classification-scripting-only-p classification))
      (error "run-closed!: provider is scripting-only: ~A"
             (runtime-executor-classification-reason classification)))
    (runtime-executor-validate-result
     (funcall (runtime-executor-execute executor) request))))
(defun runtime-executor-service (session)
  (let ((executor (and session (runtime-session-executor session))))
    (or executor
        (let ((provider (and session
                            (runtime-session-find-service session :executor))))
          (and provider (funcall provider))))))

(defun runtime-executor-run-in-session (session request)
  (let ((executor (runtime-executor-service session)))
    (unless executor (error "run-closed!: executor service is unavailable"))
    (runtime-executor-run
     executor request
     :in-node (and (runtime-dynamic-current nil)
                   (runtime-dynamic-in-node-p)))))

(setf (symbol-function 'executor-run) #'runtime-executor-run)
