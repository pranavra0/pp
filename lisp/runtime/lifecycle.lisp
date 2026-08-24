;;;; Session-owned lifecycle orchestration.
(in-package #:pp.runtime)

(defstruct (runtime-lifecycle
            (:constructor make-runtime-lifecycle
                (&key session invocation watch-state executor)))
  session invocation watch-state executor)

(defun runtime-lifecycle-require-session-service (session name)
  (or (runtime-session-find-service session name)
      (error "lifecycle service is unavailable: ~A" name)))

(defun runtime-lifecycle-prepare (session invocation desired)
  (runtime-domain-prepare-pass session invocation desired))

(defun runtime-lifecycle-observe (session target)
  (runtime-domain-observe session target))

(defun runtime-lifecycle-diff (session observed)
  (runtime-domain-diff session observed))

(defun runtime-lifecycle-apply (session planned)
  (runtime-domain-apply session planned))

(defun runtime-lifecycle-verify (session planned)
  (runtime-domain-verify session planned))

(defun runtime-lifecycle-epoch (session invocation desired)
  (runtime-domain-record-epoch session invocation
                               (runtime-domain-force session desired)))
(defun runtime-lifecycle-run-pass (session invocation desired)
  (let ((observations (runtime-session-observations session))
        (fenced-actions (runtime-session-take-fenced-actions session)))
    (runtime-session-begin-pass session)
    (dolist (observation observations)
      (runtime-session-add-observation session observation))
    (dolist (action fenced-actions)
      (runtime-session-add-fenced-action session action))
    (runtime-dynamic-with-top-level
     session
     (lambda ()
       (runtime-domain-run-pass
        session (runtime-lifecycle-prepare session invocation desired))))))

(defun runtime-lifecycle-reconcile (session invocation desired &key fenced)
  (let ((observations (runtime-session-observations session))
        (fenced-actions (runtime-session-take-fenced-actions session)))
    (runtime-session-begin-pass session)
    (dolist (observation observations)
      (runtime-session-add-observation session observation))
    (dolist (action fenced-actions)
      (runtime-session-add-fenced-action session action))
    (runtime-dynamic-with-top-level
     session
     (lambda ()
       (let ((pass (runtime-domain-run-pass
                    session (runtime-lifecycle-prepare session invocation desired))))
         (when fenced (runtime-fenced-drain session))
         pass)))))

(defun runtime-lifecycle-fenced (session kind spec)
  (runtime-fenced-register session kind spec))

(defun runtime-lifecycle-watch (session &key (interval 1.0) stabilize once)
  (runtime-watch-create session :interval interval :stabilize stabilize :once once))

(defun runtime-lifecycle-install-executor (session executor)
  (unless (typep executor 'runtime-executor)
    (error "lifecycle executor is invalid"))
  (runtime-session-register-service session :executor (lambda () executor))
  executor)

(defun runtime-lifecycle-install-process-provider (session start stop)
  (unless (and (functionp start) (functionp stop))
    (error "process provider is unavailable"))
  (runtime-session-register-service session :process-start start)
  (runtime-session-register-service session :process-stop stop)
  session)

(defun runtime-lifecycle-fail-closed (session service &optional message)
  (declare (ignore session))
  (error "lifecycle service ~A is unavailable~@[ (~A)~]"
         service message))

;; Concise compatibility names for app and focused fixtures.
(setf (symbol-function 'lifecycle-prepare-pass) #'runtime-lifecycle-prepare)
(setf (symbol-function 'lifecycle-run-pass) #'runtime-lifecycle-run-pass)
(setf (symbol-function 'lifecycle-reconcile) #'runtime-lifecycle-reconcile)
(setf (symbol-function 'lifecycle-observe) #'runtime-lifecycle-observe)
(setf (symbol-function 'lifecycle-diff) #'runtime-lifecycle-diff)
(setf (symbol-function 'lifecycle-apply) #'runtime-lifecycle-apply)
(setf (symbol-function 'lifecycle-verify) #'runtime-lifecycle-verify)
(setf (symbol-function 'lifecycle-epoch) #'runtime-lifecycle-epoch)
