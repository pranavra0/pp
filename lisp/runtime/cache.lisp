;;;; Verified cache lookup and trace decisions.
(in-package #:pp.rt.cache)

(defstruct (runtime-cache-policy (:constructor %make-runtime-cache-policy))
  (no-cache nil) (why nil) (check nil) (volatile-count 0))
(defstruct (runtime-cache-result (:constructor make-runtime-cache-result (kind value trace))) kind value trace)
(defun runtime-cache-policy-create () (%make-runtime-cache-policy))
(defun make-runtime-cache-policy () (runtime-cache-policy-create))
(defun runtime-cache-configure (policy &key no-cache why check)
  (setf (runtime-cache-policy-no-cache policy) (not (null no-cache))
        (runtime-cache-policy-why policy) (not (null why))
        (runtime-cache-policy-check policy) (not (null check))) policy)
(defun runtime-cache-enable-no-cache (p) (setf (runtime-cache-policy-no-cache p) t))
(defun runtime-cache-enable-why (p) (setf (runtime-cache-policy-why p) t))
(defun runtime-cache-set-why (p x) (setf (runtime-cache-policy-why p) (not (null x))))
(defun runtime-cache-why-enabled-p (p) (runtime-cache-policy-why p))
(defun runtime-cache-enable-check (p) (setf (runtime-cache-policy-check p) t))
(defun runtime-cache-check-enabled-p (p) (runtime-cache-policy-check p))
(defun runtime-cache-note-volatile (p) (incf (runtime-cache-policy-volatile-count p)))
(defun runtime-cache-reset-volatile (p) (setf (runtime-cache-policy-volatile-count p) 0))
(defun runtime-cache-volatile-count (p) (runtime-cache-policy-volatile-count p))
(defun runtime-cache-error (message)
  (if (fboundp 'language-fail) (language-fail message "runtime.cache") (error "~A" message)))
(defun runtime-cache-key-string (key)
  (handler-case
      (cond ((typep key 'node-key) (node-key-to-string key))
            ((typep key 'cache-key) (cache-key-to-string key))
            ((stringp key) key)
            (t (runtime-cache-error "cache key must be a node/cache identity")))
    (error () (runtime-cache-error "cache key is malformed"))))
(defun runtime-cache-short-key (key)
  (let ((s (runtime-cache-key-string key)))
    (if (> (length s) 12) (subseq s 0 12) s)))
(defun runtime-cache-event (kind key reason)
  (when (fboundp 'pp.rt.scope:runtime-dynamic-record-event)
    (pp.rt.scope:runtime-dynamic-record-event
     (make-vmap (list (cons (make-vkeyword "kind") (make-vkeyword kind))
                      (cons (make-vkeyword "node") (make-vstring (runtime-cache-short-key key)))
                      (cons (make-vkeyword "reason") (make-vkeyword reason)))))))
(defun runtime-cache-diagnose (policy text)
  (when (runtime-cache-policy-why policy)
    (let ((fn (runtime-observation-service :diagnose))) (when fn (funcall fn text)))))
(defun runtime-cache-result-hit-p (r) (member (runtime-cache-result-kind r) '(:ok :failed)))
(defun runtime-cache-hit-ok-p (r) (eq (runtime-cache-result-kind r) :ok))
(defun runtime-cache-hit-failed-p (r) (eq (runtime-cache-result-kind r) :failed))
(defun runtime-cache-miss-p (r) (eq (runtime-cache-result-kind r) :miss))



(defun runtime-cache-lookup (&key policy traces objects blobs key observe-id replay authorized reachable-blobs)
  (let ((policy (or policy (runtime-cache-policy-create)))
        (key (runtime-cache-key-string key)))
    (when (runtime-cache-policy-no-cache policy)
      (runtime-cache-event "node-cache" key "disabled")
      (runtime-cache-diagnose
       policy
       (format nil "node ~A: miss — cache reads disabled (--no-cache)"
               (runtime-cache-short-key key)))
      (return-from runtime-cache-lookup (make-runtime-cache-result :miss nil nil)))
    (unless (and traces objects blobs observe-id replay authorized)
      (runtime-cache-error "cache lookup requires explicit repositories and callbacks"))
    (labels ((authorized-p (cell-id)
               (handler-case (funcall authorized cell-id)
                 (error () nil)))
             (observe (cell-id)
               (handler-case (funcall observe-id cell-id)
                 (error () nil)))
             (load-object (hash)
               (handler-case
                   (object-repository-get objects :key hash)
                 (error () nil)))
             (reachable-p (value)
               (or (null reachable-blobs)
                   (handler-case
                       (every (lambda (hash) (blob-repository-get blobs hash))
                              (funcall reachable-blobs value))
                     (error () nil))))
      )
      (let ((usable nil)
            (all-traces (trace-repository-load traces :key key))
            (index 0))
        (dolist (trace all-traces)
          (incf index)
          (let ((bad-auth
                  (find-if
                   (lambda (read)
                     (not (authorized-p
                           (cell-id-of-string
                            (store-identity-string
                             (store-trace-read-cell read))))))
                   (store-trace-reads trace)))
                (stale
                  (find-if
                   (lambda (read)
                     (let ((current
                             (observe
                              (cell-id-of-string
                               (store-identity-string
                                (store-trace-read-cell read))))))
                       (or (null current)
                           (not (string=
                                 (store-identity-string current)
                                 (store-identity-string
                                  (store-trace-read-hash read)))))))
                   (store-trace-reads trace))))
            (cond
              (bad-auth
               (runtime-cache-diagnose
                policy
                (format nil
                        "node ~A: trace ~D/~D unauthorized — redacted"
                        (runtime-cache-short-key key)
                        index
                        (length all-traces))))
              (stale
               (runtime-cache-diagnose
                policy
                (format nil
                        "node ~A: trace ~D/~D stale — ~A changed"
                        (runtime-cache-short-key key)
                        index
                        (length all-traces)
                        (store-identity-string
                         (store-trace-read-cell stale))))
              )
              (t
               (let ((value
                       (load-object
                        (store-identity-string
                         (store-trace-result-hash trace)))))
                 (when (and value (reachable-p value))
                   (push (cons trace value) usable))))))
        )
        (let ((chosen
                (or (find-if
                     (lambda (entry)
                       (store-trace-outcome-ok-p
                        (store-trace-outcome (car entry))))
                     usable)
                    (find-if
                     (lambda (entry)
                       (store-trace-outcome-failed-p
                        (store-trace-outcome (car entry))))
                     usable))))
          (if (null chosen)
              (progn
                (runtime-cache-event "node-cache" key "miss")
                (runtime-cache-diagnose
                 policy
                 (format nil "node ~A: miss — ~A"
                         (runtime-cache-short-key key)
                         (if (null all-traces)
                             "no stored trace (first build)"
                             "no stored trace usable")))
                (make-runtime-cache-result :miss nil nil))
              (let ((trace (car chosen))
                    (value (cdr chosen)))
                (runtime-cache-diagnose
                 policy
                 (format nil "node ~A: hit — ~A trace verified (~D cells)"
                         (runtime-cache-short-key key)
                         (if (store-trace-outcome-ok-p
                              (store-trace-outcome trace))
                             "ok"
                             "failing")
                         (length (store-trace-reads trace))))
                (if (handler-case
                        (progn (funcall replay (store-trace-reads trace)) t)
                      (error () nil))
                    (progn
                      (runtime-cache-event "node-cache" key "hit")
                      (make-runtime-cache-result
                       (if (store-trace-outcome-ok-p
                            (store-trace-outcome trace))
                           :ok
                           :failed)
                       value trace))
                    (progn
                      (runtime-cache-event "node-cache" key "miss")
                      (make-runtime-cache-result :miss nil nil))))))))
    )
    )
