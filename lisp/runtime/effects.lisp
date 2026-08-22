;;;; M4 effect boundary.
(in-package #:pp.runtime)
(defvar *runtime-effects-dispatching* nil)
(defstruct (runtime-effect (:constructor %make-runtime-effect (name function hash authority)) (:conc-name %runtime-effect-)) name function hash authority)
(defun runtime-effects-error (message &optional (code "runtime.effect")) (if (fboundp 'language-fail) (language-fail message code) (error "~A" message)))
(defun make-runtime-effect (&key name function hash authority) (check-type name string) (unless (functionp function) (runtime-effects-error "effect implementation must be a function")) (%make-runtime-effect name function hash authority))
(defun runtime-effect-name (effect) (cond ((typep effect 'runtime-effect) (%runtime-effect-name effect)) ((typep effect 'runtime-effect-frame) (runtime-effect-frame-name effect)) ((consp effect) (car effect))))
(defun runtime-effect-function (effect) (cond ((typep effect 'runtime-effect) (%runtime-effect-function effect)) ((typep effect 'runtime-effect-frame) (runtime-effect-frame-function effect)) ((consp effect) (cdr effect))))
(defun runtime-effect-hash (effect) (and (typep effect 'runtime-effect) (%runtime-effect-hash effect)))
(defun runtime-effect-authority (effect) (and (typep effect 'runtime-effect) (%runtime-effect-authority effect)))
(defun runtime-effects-register (name function &key hash authority)
  (declare (ignore hash))
  (let ((implementation
          (if authority
              (lambda (&rest arguments)
                (unless (runtime-effects-authorized-p authority arguments)
                  (runtime-effects-error
                   (format nil "effect is not authorized: ~A" name)
                   "runtime.authority"))
                (apply function arguments))
              function)))
    (runtime-dynamic-push-effects
     (list (make-runtime-effect-frame name implementation)))
  name))
(defun runtime-effects-with (effects thunk)
  (let ((frames
          (mapcar
           (lambda (effect)
             (if (typep effect 'runtime-effect)
                 (let ((name (%runtime-effect-name effect))
                       (function (%runtime-effect-function effect))
                       (authority (%runtime-effect-authority effect)))
                   (make-runtime-effect-frame
                    name
                    (if authority
                        (lambda (&rest arguments)
                          (unless (runtime-effects-authorized-p authority arguments)
                            (runtime-effects-error "effect is not authorized"
                                                   "runtime.authority"))
                          (apply function arguments))
                        function)))
                 effect))
           effects)))
    (runtime-dynamic-push-effects frames)
    (unwind-protect
         (funcall thunk)
      (runtime-dynamic-pop-effects))))
(defun runtime-effects-authorized-p (authority arguments)
  (if (null authority)
      t
      (handler-case
          (not (null (funcall authority (runtime-dynamic-capabilities) arguments)))
        (error () nil))))
(defun runtime-effect-perform (name arguments &key environment)
  (let ((handler (runtime-dynamic-find-handler name))
        (effect (runtime-dynamic-find-effect name))
        (session (runtime-dynamic-session nil)))
    (cond
      (handler (runtime-dynamic-call-handler handler arguments environment))
      (effect
       (let ((fn (if (functionp effect) effect (runtime-effect-function effect))))
         (unless (functionp fn)
           (runtime-effects-error "effect implementation is unavailable"))
         (apply fn arguments)))
      ((and session (not *runtime-effects-dispatching*))
       (let ((*runtime-effects-dispatching* t))
         (runtime-dynamic-perform name arguments :environment environment)))
      (t (runtime-effects-error (format nil "unhandled effect: ~A" name))))))
(defun runtime-effects-sync-capabilities (state value)
  (declare (ignore state))
  (let ((scope (runtime-dynamic-current nil)))
    (when scope
      ;; Evaluator callbacks pass either one requested capability or the full
      ;; capability list.  Dynamic scope stores a stack whose top is a list.
      (let ((capabilities (if (listp value) (copy-list value) (list value))))
        (setf (runtime-dynamic-scope-capabilities scope)
              (list capabilities))))
    value))
(defun runtime-effects-sync-handlers (state value)
  (let ((scope (runtime-dynamic-current nil)))
    (when scope
      (setf (runtime-dynamic-scope-handlers scope)
            (if (equal value
                       (runtime-evaluator-state-handler-stack state))
                (copy-tree value)
                (cons value
                      (runtime-dynamic-scope-handlers scope))))))
  value)
(defun runtime-effects-sync-config (state value)
  (let ((scope (runtime-dynamic-current nil)))
    (when scope
      (setf (runtime-dynamic-scope-configs scope)
            (if (equal value
                       (runtime-evaluator-state-config-stack state))
                (copy-tree value)
                (cons value
                      (runtime-dynamic-scope-configs scope))))))
  value)
(defun runtime-effects-install-session (session)
  (runtime-session-register-callback
   session :perform
   (lambda (state name arguments environment)
     (declare (ignore state))
     (runtime-effect-perform name arguments :environment environment)))
  (runtime-session-register-callback
   session :with-capabilities #'runtime-effects-sync-capabilities)
  (runtime-session-register-callback
   session :with-handlers #'runtime-effects-sync-handlers)
  (runtime-session-register-callback
   session :with-config #'runtime-effects-sync-config)
  session)
(defun runtime-effects-handler (name handler &key hash) (make-runtime-handler-frame name handler hash))
(defun runtime-effects-with-handlers (handlers thunk)
  (runtime-dynamic-push-handlers handlers)
  (unwind-protect
       (funcall thunk)
    (runtime-dynamic-pop-handlers)))
(defun runtime-effects-handler-identities () (runtime-dynamic-handler-identities))
(defun runtime-effects-current-capabilities () (runtime-dynamic-capabilities))
(defun runtime-effects-require-capability (predicate message) (unless (some predicate (runtime-dynamic-capabilities)) (runtime-effects-error message "runtime.authority")) t)
(defun runtime-effects-record-event (event) (runtime-dynamic-record-event event))
(defun runtime-effects-record-read (cell-id observed-hash) (runtime-dynamic-record-read cell-id observed-hash))
