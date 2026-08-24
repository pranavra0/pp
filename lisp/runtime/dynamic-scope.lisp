;;;; Dynamic scope boundary.
;;;;
;;;; The only special binding here is the deliberately dynamic current scope.
;;;; It is not a registry: every stack and every callback belongs to the scope's
;;;; explicit session, and all brackets restore state on normal or exceptional
;;;; exit.

(in-package #:pp.runtime)

(defstruct (runtime-effect-frame
            (:constructor make-runtime-effect-frame (name function)))
  name function)

(defstruct (runtime-handler-frame
            (:constructor make-runtime-handler-frame (name function hash)))
  name function hash)

(defstruct (runtime-node-frame
            (:constructor make-runtime-node-frame
                (&key key persistent sandbox)))
  key persistent sandbox)

(defstruct (runtime-dynamic-scope
            (:constructor %make-runtime-dynamic-scope))
  session invocation
  (effects nil)
  (capabilities nil)
  (configs nil)
  (handlers nil)
  (nodes nil)
  (domains nil)
  (observations nil)
  (services nil)
  (in-node nil)
  sandbox)

(defvar *runtime-dynamic-scope* nil
  "The current dynamic extent only; it is never used as a process registry.")

(defun runtime-dynamic-error (message &optional (code "runtime.dynamic-scope"))
  (if (fboundp 'language-fail)
      (language-fail message code)
      (error "~A" message)))

(defun runtime-dynamic-current (&optional (required t))
  (if *runtime-dynamic-scope*
      *runtime-dynamic-scope*
      (if required
          (runtime-dynamic-error "no runtime dynamic scope is installed"
                                 "runtime.scope")
          nil)))

(defun runtime-dynamic-session (&optional (required t))
  (let ((scope (runtime-dynamic-current required)))
    (and scope (runtime-dynamic-scope-session scope))))

(defun runtime-dynamic-copy-stack (stack)
  (copy-list stack))

(defun runtime-dynamic-state-slot (state accessor)
  (and state (fboundp accessor) (funcall accessor state)))

(defun runtime-dynamic-set-state-slot (state accessor value)
  (let* ((symbol (if (symbolp accessor)
                     accessor
                     (intern accessor (find-package '#:pp.runtime))))
         (setf-name (list 'setf symbol)))
    (when (and state (fboundp symbol) (fboundp setf-name))
      (funcall (fdefinition setf-name) value state)))
  value)

(defun runtime-dynamic-initial-capabilities (session capabilities)
  (if capabilities
      (copy-list capabilities)
      (let ((state (and session (runtime-session-evaluator session))))
        (copy-list
         (or (runtime-dynamic-state-slot
              state 'runtime-evaluator-state-capabilities)
             nil)))))
 
(defun runtime-dynamic-capability-frames (scope)
  "Return SCOPE's capability stack in canonical frame form.

Evaluator callbacks carry the evaluator's flat capability list, while a
dynamic scope stores a stack of such lists.  Normalize both forms at this
boundary so a callback cannot expose a host list-shape/type condition."
  (let ((stack (and scope (runtime-dynamic-scope-capabilities scope))))
    (cond
      ((null stack) nil)
      ;; A callback may have assigned the evaluator's flat list directly.
      ((typep (first stack) 'capability)
       (list (copy-list stack)))
      ;; A callback can briefly wrap that flat list once more while restoring.
      ((and (consp (first stack))
            (consp (first (first stack)))
            (typep (first (first (first stack))) 'capability))
       (copy-list (first stack)))
      (t (copy-list stack)))))

(defun runtime-dynamic-sync-capabilities! (capabilities)
  "Replace the current scope's ambient capability frame.

CAPABILITIES is the evaluator's flat capability list.  This operation is
idempotent and deliberately updates only the current dynamic extent."
  (let ((scope (runtime-dynamic-current nil))
        (capabilities (copy-list capabilities)))
    (when scope
      (setf (runtime-dynamic-scope-capabilities scope)
            (list capabilities)))
    capabilities))

(defun runtime-dynamic-scope-new (session &key invocation capabilities
                                            (reset nil) configs handlers
                                            effects nodes domains observations
                                            sandbox services in-node)
  "Build a scope record.  RESET starts a top-level extent; otherwise current
stacks are copied, so nested scopes cannot mutate their parent by accident."
  (let ((parent (and (not reset) *runtime-dynamic-scope*)))
    (%make-runtime-dynamic-scope
     :session (or session (and parent (runtime-dynamic-scope-session parent)))
     :invocation (or invocation (and parent (runtime-dynamic-scope-invocation parent)))
     :effects (copy-list (or effects (and parent (runtime-dynamic-scope-effects parent))))
     :capabilities
     (cond
       (capabilities
        (list (runtime-dynamic-initial-capabilities
               (or session (and parent (runtime-dynamic-scope-session parent)))
               capabilities)))
       (parent (copy-list (runtime-dynamic-scope-capabilities parent)))
       (t (list (runtime-dynamic-initial-capabilities session nil))))
     :configs (copy-list (or configs (and parent (runtime-dynamic-scope-configs parent))))
     :handlers (copy-list (or handlers (and parent (runtime-dynamic-scope-handlers parent))))
     :nodes (copy-list (or nodes (and parent (runtime-dynamic-scope-nodes parent))))
     :domains (copy-list (or domains (and parent (runtime-dynamic-scope-domains parent))))
     :observations
     (if observations
         (list t)
         (if parent
             (copy-list (runtime-dynamic-scope-observations parent))
             (list t)))
     :services (copy-list (or services (and parent (runtime-dynamic-scope-services parent))))
     :in-node (if in-node t (and parent (runtime-dynamic-scope-in-node parent)))
     :sandbox sandbox)))

(defun runtime-dynamic-call (thunk &optional argument argument-p)
  (if argument-p (funcall thunk argument) (funcall thunk)))

(defun runtime-dynamic-with-scope (scope thunk &key argument (argument-p nil))
  (let ((*runtime-dynamic-scope* scope))
    (runtime-dynamic-call thunk argument argument-p)))

(defun runtime-dynamic-install-perform-callback (session thunk)
  "Temporarily connect evaluator PERFORM to this scope."
  (let ((state (and session (runtime-session-evaluator session))))
    (if (and state (fboundp 'runtime-evaluator-state-perform-function))
        (let ((old (runtime-evaluator-state-perform-function state)))
          (unless old
            (setf (runtime-evaluator-state-perform-function state) thunk))
          old)
        nil)))

(defun runtime-dynamic-restore-perform-callback (session old)
  (let ((state (and session (runtime-session-evaluator session))))
    (when (and state (fboundp 'runtime-evaluator-state-perform-function))
      (setf (runtime-evaluator-state-perform-function state) old))))

(defun runtime-dynamic-with-top-level (session thunk &key invocation capabilities argument)
  "Run THUNK with fresh top-level stacks for SESSION.
The extent is exception-safe and restores an outer dynamic scope."
  (unless session
    (runtime-dynamic-error "top-level evaluation requires a session"
                           "runtime.session"))
  (let* ((scope (runtime-dynamic-scope-new
                 session :invocation invocation :capabilities capabilities
                 :reset t))
         (state (runtime-session-evaluator session))
         (old-capabilities
           (runtime-dynamic-state-slot state 'runtime-evaluator-state-capabilities))
         (old-config
           (runtime-dynamic-state-slot state 'runtime-evaluator-state-config-stack))
         (old-handlers
           (runtime-dynamic-state-slot state 'runtime-evaluator-state-handler-stack))
         (old-perform
           (runtime-dynamic-install-perform-callback
            session
            (lambda (ignored-state name arguments environment)
              (declare (ignore ignored-state))
              (runtime-dynamic-perform name arguments
                                       :environment environment)))))
    (runtime-dynamic-set-state-slot
     state 'runtime-evaluator-state-capabilities
     (copy-list (or (first (runtime-dynamic-scope-capabilities scope)) nil)))
    (runtime-dynamic-set-state-slot state 'runtime-evaluator-state-config-stack nil)
    (runtime-dynamic-set-state-slot state 'runtime-evaluator-state-handler-stack nil)
    (unwind-protect
         (let ((*runtime-dynamic-scope* scope))
           (if (null argument)
               (funcall thunk)
               (funcall thunk argument)))
      (runtime-dynamic-set-state-slot
       state 'runtime-evaluator-state-capabilities old-capabilities)
      (runtime-dynamic-set-state-slot
       state 'runtime-evaluator-state-config-stack old-config)
      (runtime-dynamic-set-state-slot
       state 'runtime-evaluator-state-handler-stack old-handlers)
      (runtime-dynamic-restore-perform-callback session old-perform))))

(defun runtime-dynamic-with-session (session thunk &rest arguments)
  "Compatibility spelling for a fresh top-level dynamic extent."
  (apply #'runtime-dynamic-with-top-level session thunk arguments))

;;; ---------------------------------------------------------------------------
;;; Generic push/pop and tail-safe brackets

(defun runtime-dynamic-slot-symbol (accessor)
  (intern (format nil "RUNTIME-DYNAMIC-SCOPE-~A" accessor)
          (find-package '#:pp.runtime)))

(defun runtime-dynamic-slot-value (scope accessor)
  (funcall (runtime-dynamic-slot-symbol accessor) scope))

(defun runtime-dynamic-slot-set (scope accessor value)
  (let* ((symbol (runtime-dynamic-slot-symbol accessor))
         (setf-name (list 'setf symbol)))
    (unless (fboundp setf-name)
      (runtime-dynamic-error
       (format nil "dynamic stack is not mutable: ~A" accessor)
       "runtime.scope"))
    (funcall (fdefinition setf-name) value scope))
  value)

(defun runtime-dynamic-push (accessor value)
  (let ((scope (runtime-dynamic-current)))
    (runtime-dynamic-slot-set
     scope accessor
     (cons value (runtime-dynamic-slot-value scope accessor)))))

(defun runtime-dynamic-pop (accessor)
  (let* ((scope (runtime-dynamic-current))
         (stack (runtime-dynamic-slot-value scope accessor)))
    (unless stack
      (runtime-dynamic-error
       (format nil "dynamic ~A stack underflow" accessor) "runtime.scope"))
    (runtime-dynamic-slot-set scope accessor (rest stack))
    (first stack)))

(defun runtime-dynamic-with-stack (accessor value thunk)
  (runtime-dynamic-push accessor value)
  (let ((closed nil))
    (labels ((leave ()
               (unless closed
                 (setf closed t)
                 (runtime-dynamic-pop accessor))))
      (unwind-protect
           (funcall thunk #'leave)
        (leave)))))

(defun runtime-dynamic-push-effects (effects)
  (runtime-dynamic-push 'effects effects))
(defun runtime-dynamic-pop-effects () (runtime-dynamic-pop 'effects))

(defun runtime-dynamic-push-capabilities (capabilities)
  (let* ((scope (runtime-dynamic-current))
         (capabilities (copy-list capabilities))
         (frames (runtime-dynamic-capability-frames scope)))
    (setf (runtime-dynamic-scope-capabilities scope)
          (cons capabilities frames))
    (let ((state (runtime-session-evaluator (runtime-dynamic-session nil))))
      (when (and state (fboundp 'runtime-evaluator-state-capabilities))
        (runtime-dynamic-set-state-slot
         state 'runtime-evaluator-state-capabilities capabilities)))
    capabilities))

(defun runtime-dynamic-pop-capabilities ()
  (let* ((scope (runtime-dynamic-current))
         (frames (runtime-dynamic-capability-frames scope)))
    (unless frames
      (runtime-dynamic-error
       "dynamic capabilities stack underflow" "runtime.scope"))
    (setf (runtime-dynamic-scope-capabilities scope) (rest frames))
    (let ((state (runtime-session-evaluator (runtime-dynamic-session nil))))
      (when (and state (fboundp 'runtime-evaluator-state-capabilities))
        (runtime-dynamic-set-state-slot
         state 'runtime-evaluator-state-capabilities
         (copy-list (or (first (rest frames)) nil)))))
    (first frames)))
(defun runtime-dynamic-push-config (config)
  (runtime-dynamic-push 'configs config)
  (let ((state (runtime-session-evaluator (runtime-dynamic-session nil))))
    (when (and state (fboundp 'runtime-evaluator-state-config-stack))
      (runtime-dynamic-set-state-slot
       state 'runtime-evaluator-state-config-stack
       (cons config (runtime-dynamic-state-slot
                     state 'runtime-evaluator-state-config-stack)))))
  config)
(defun runtime-dynamic-pop-config ()
  (let* ((value (runtime-dynamic-pop 'configs))
         (state (runtime-session-evaluator (runtime-dynamic-session nil))))
    (when (and state (fboundp 'runtime-evaluator-state-config-stack))
      (runtime-dynamic-set-state-slot
       state 'runtime-evaluator-state-config-stack
       (rest (runtime-dynamic-state-slot
              state 'runtime-evaluator-state-config-stack))))
    value))
(defun runtime-dynamic-push-handlers (handlers)
  (runtime-dynamic-push 'handlers handlers)
  (let ((state (runtime-session-evaluator (runtime-dynamic-session nil))))
    (when (and state (fboundp 'runtime-evaluator-state-handler-stack))
      (runtime-dynamic-set-state-slot
       state 'runtime-evaluator-state-handler-stack
       (cons handlers (runtime-dynamic-state-slot
                       state 'runtime-evaluator-state-handler-stack)))))
  handlers)
(defun runtime-dynamic-pop-handlers ()
  (let* ((value (runtime-dynamic-pop 'handlers))
         (state (runtime-session-evaluator (runtime-dynamic-session nil))))
    (when (and state (fboundp 'runtime-evaluator-state-handler-stack))
      (runtime-dynamic-set-state-slot
       state 'runtime-evaluator-state-handler-stack
       (rest (runtime-dynamic-state-slot
              state 'runtime-evaluator-state-handler-stack))))
    value))
(defun runtime-dynamic-push-node (node) (runtime-dynamic-push 'nodes node))
(defun runtime-dynamic-pop-node () (runtime-dynamic-pop 'nodes))
(defun runtime-dynamic-push-domain (domain) (runtime-dynamic-push 'domains domain))
(defun runtime-dynamic-pop-domain () (runtime-dynamic-pop 'domains))
(defun runtime-dynamic-push-observation-collection (enabled)
  (runtime-dynamic-push 'observations (not (null enabled))))
(defun runtime-dynamic-pop-observation-collection ()
  (runtime-dynamic-pop 'observations))

(defun runtime-dynamic-with-effects (effects thunk)
  (runtime-dynamic-with-stack 'effects effects thunk))
(defun runtime-dynamic-with-capabilities (capabilities thunk)
  (runtime-dynamic-push-capabilities capabilities)
  (unwind-protect (funcall thunk) (runtime-dynamic-pop-capabilities)))
(defun runtime-dynamic-with-config (config thunk)
  (runtime-dynamic-push-config config)
  (unwind-protect (funcall thunk) (runtime-dynamic-pop-config)))
(defun runtime-dynamic-with-handlers (handlers thunk)
  (runtime-dynamic-push-handlers handlers)
  (unwind-protect (funcall thunk) (runtime-dynamic-pop-handlers)))
(defun runtime-dynamic-with-node (node thunk)
  (let* ((scope (runtime-dynamic-current))
         (old (runtime-dynamic-scope-in-node scope)))
    (runtime-dynamic-push-node node)
    (setf (runtime-dynamic-scope-in-node scope) t)
    (unwind-protect (funcall thunk)
      (setf (runtime-dynamic-scope-in-node scope) old)
      (runtime-dynamic-pop-node))))
(defun runtime-dynamic-with-domain (domain thunk)
  (runtime-dynamic-push-domain domain)
  (unwind-protect (funcall thunk) (runtime-dynamic-pop-domain)))
(defun runtime-dynamic-with-observation-collection (enabled thunk)
  (runtime-dynamic-push-observation-collection enabled)
  (unwind-protect (funcall thunk)
    (runtime-dynamic-pop-observation-collection)))

;;; Tail brackets pass an idempotent leave callback and remain safe for
;;; ordinary zero-argument callbacks.
(defun runtime-dynamic-with-tail-capabilities (capabilities thunk)
  (runtime-dynamic-push-capabilities capabilities)
  (let ((closed nil))
    (labels ((leave ()
               (unless closed
                 (setf closed t)
                 (runtime-dynamic-pop-capabilities))))
      (unwind-protect (funcall thunk #'leave) (leave)))))
(defun runtime-dynamic-with-tail-config (config thunk)
  (runtime-dynamic-push-config config)
  (let ((closed nil))
    (labels ((leave ()
               (unless closed
                 (setf closed t)
                 (runtime-dynamic-pop-config))))
      (unwind-protect (funcall thunk #'leave) (leave)))))
(defun runtime-dynamic-with-tail-handlers (handlers thunk)
  (runtime-dynamic-push-handlers handlers)
  (let ((closed nil))
    (labels ((leave ()
               (unless closed
                 (setf closed t)
                 (runtime-dynamic-pop-handlers))))
      (unwind-protect (funcall thunk #'leave) (leave)))))

;;; ---------------------------------------------------------------------------
;;; Stack views and effect/config/handler operations

(defun runtime-dynamic-effects ()
  (copy-list (runtime-dynamic-scope-effects (runtime-dynamic-current))))

(defun runtime-dynamic-capabilities ()
  (let ((frames (runtime-dynamic-capability-frames
                 (runtime-dynamic-current))))
    (copy-list (or (first frames) nil))))

(defun runtime-dynamic-config ()
  (copy-list (runtime-dynamic-scope-configs (runtime-dynamic-current))))

(defun runtime-dynamic-handlers ()
  (copy-list (runtime-dynamic-scope-handlers (runtime-dynamic-current))))

(defun runtime-dynamic-nodes ()
  (copy-list (runtime-dynamic-scope-nodes (runtime-dynamic-current))))

(defun runtime-dynamic-domains ()
  (copy-list (runtime-dynamic-scope-domains (runtime-dynamic-current))))

(defun runtime-dynamic-observation-collection-p ()
  (not (null (first (runtime-dynamic-scope-observations
                     (runtime-dynamic-current))))))

(defun runtime-dynamic-in-node-p ()
  (not (null (runtime-dynamic-scope-in-node (runtime-dynamic-current)))))

(defun runtime-dynamic-current-node ()
  (first (runtime-dynamic-nodes)))

(defun runtime-dynamic-current-domain ()
  (first (runtime-dynamic-domains)))

(defun runtime-dynamic-config-lookup (key)
  (labels ((key-string (value)
             (cond ((and (fboundp 'runtime-string-like)
                         (runtime-string-like value))
                    (runtime-string-like value))
                   ((stringp value) value)
                   (t (princ-to-string value))))
           (find-in (config)
             (when (and (fboundp 'value-map-entries)
                        (typep config 'value-map))
               (find (key-string key) (value-map-entries config)
                     :key (lambda (entry) (key-string (car entry)))
                     :test #'string=
                     :from-end nil))))
    (loop for config in (runtime-dynamic-config)
          for entry = (find-in config)
          when entry do (return (values (cdr entry) t))
          finally (return (values nil nil)))))
(defun runtime-dynamic-handler-hash (handler)
  (cond ((typep handler 'runtime-handler-frame)
         (runtime-handler-frame-hash handler))
        ((consp handler)
         (let ((entry (if (consp (first handler))
                          (first handler)
                          handler)))
           (and (consp (cdr entry)) (third entry))))
        (t nil)))


(defun runtime-dynamic-handler-name (handler)
  (cond ((typep handler 'runtime-handler-frame)
         (runtime-handler-frame-name handler))
        ((consp handler) (if (consp (first handler)) (first (first handler))
                            (first handler)))
        (t nil)))

(defun runtime-dynamic-handler-function (handler)
  (cond ((typep handler 'runtime-handler-frame)
         (runtime-handler-frame-function handler))
        ((consp handler)
         (let ((entry (if (consp (first handler))
                          (first handler)
                          handler)))
           (if (consp (cdr entry))
               (second entry)
               (cdr entry))))
        (t nil)))

(defun runtime-dynamic-find-handler (name)
  (loop for frame in (runtime-dynamic-handlers)
        for handlers = (if (listp frame) frame (list frame))
        for entry = (find name handlers :key #'runtime-dynamic-handler-name
                           :test #'string=)
        when entry do (return (runtime-dynamic-handler-function entry))
        finally (return nil)))

(defun runtime-dynamic-handler-identities ()
  (loop for frame in (runtime-dynamic-handlers)
        append (loop for handler in (if (listp frame) frame (list frame))
                     for name = (runtime-dynamic-handler-name handler)
                     when name collect
                     (cons name (runtime-dynamic-handler-hash handler)))))

(defun runtime-dynamic-effect-name (effect)
  (cond ((typep effect 'runtime-effect-frame) (runtime-effect-frame-name effect))
        ((consp effect) (car effect))
        (t nil)))

(defun runtime-dynamic-effect-function (effect)
  (cond ((typep effect 'runtime-effect-frame) (runtime-effect-frame-function effect))
        ((consp effect) (cdr effect))
        (t nil)))

(defun runtime-dynamic-find-effect (name)
  (loop for frame in (runtime-dynamic-effects)
        for effects = (if (listp frame) frame (list frame))
        for entry = (find name effects :key #'runtime-dynamic-effect-name
                           :test #'equal)
        when entry do (return (runtime-dynamic-effect-function entry))
        finally (return nil)))

(defun runtime-dynamic-call-handler (handler arguments environment)
  (cond
    ((functionp handler) (apply handler arguments))
    ((and (runtime-dynamic-session nil)
          (runtime-session-core-operations (runtime-dynamic-session nil)))
     (runtime-session-call (runtime-dynamic-session nil) handler arguments environment))
    (t (runtime-dynamic-error "handler service is unavailable"
                             "runtime.handler"))))

(defun runtime-dynamic-find-service (name)
  (let ((scope (runtime-dynamic-current nil)))
    (or (and scope
             (let ((entry (assoc name (runtime-dynamic-scope-services scope))))
               (and entry (cdr entry))))
        (and scope
             (runtime-session-find-service
              (runtime-dynamic-scope-session scope) name)))))

(defun runtime-dynamic-perform (name arguments &key environment)
  "Dispatch an effect through dynamic handlers/effect frames, then the
session-owned :PERFORM service.  Missing services fail closed."
  (let* ((handler (runtime-dynamic-find-handler name))
         (effect (runtime-dynamic-find-effect name))
         (session (runtime-dynamic-session))
         (service (runtime-dynamic-find-service :perform)))
    (cond
      (handler
       (progn
         (when (fboundp 'runtime-observation-record-handler)
           (runtime-observation-record-handler name))
         (runtime-dynamic-call-handler handler arguments environment)))
      (effect (apply effect arguments))
      (service
       (funcall service (runtime-session-evaluator session) name arguments environment))
      (t (runtime-dynamic-error
          (format nil "unhandled effect: ~A" name) "runtime.effect")))))

;;; ---------------------------------------------------------------------------
;;; Observation/event/node records and service registration

(defun runtime-dynamic-record-read (cell-id observed-hash)
  (let ((session (runtime-dynamic-session))
        (service (runtime-dynamic-find-service :record-read)))
    (when (runtime-dynamic-observation-collection-p)
      (runtime-session-add-observation session (cons cell-id observed-hash)))
    (when service (funcall service session cell-id observed-hash))
    nil))

(defun runtime-dynamic-record-event (event)
  (let ((session (runtime-dynamic-session))
        (service (runtime-dynamic-find-service :record-event)))
    (runtime-session-add-event session event)
    (when service (funcall service session event))
    nil))

(defun runtime-dynamic-record-node-force (id)
  (let ((session (runtime-dynamic-session))
        (service (runtime-dynamic-find-service :record-node-force)))
    (let ((key (runtime-session-node-key-by-id session id)))
      (when key (runtime-session-add-wanted-node session key)))
    (when service (funcall service session id))
    nil))


(defun runtime-dynamic-register-service (name function)
  (runtime-session-register-service (runtime-dynamic-session) name function))

(defun runtime-dynamic-call-service (name &rest arguments)
  (apply #'runtime-session-call-service (runtime-dynamic-session) name arguments))

(defun runtime-dynamic-with-service (name function thunk)
  (let ((scope (runtime-dynamic-current))
        (old-services (runtime-dynamic-scope-services
                      (runtime-dynamic-current))))
    (push (cons name function) (runtime-dynamic-scope-services scope))
    (unwind-protect
         (funcall thunk)
      (setf (runtime-dynamic-scope-services scope) old-services))))

(defun runtime-dynamic-service (name)
  (or (runtime-dynamic-find-service name)
      (runtime-dynamic-error
       (format nil "runtime service is unavailable: ~A" name)
       "runtime.service")))

;;; Deterministic observation identities used by configuration and handler
;;; traces.
(defun runtime-dynamic-observe-config (key)
  (multiple-value-bind (value present) (runtime-dynamic-config-lookup key)
    (if present
        (if (and (fboundp 'hash-value)
                 (runtime-dynamic-session nil))
            (hash-value (runtime-session-force (runtime-dynamic-session nil) value))
            (format nil "config:~A" value))
        "config-cell:absent")))

(defun runtime-dynamic-observe-handler (name)
  (let ((handler (runtime-dynamic-find-handler name)))
    (if handler
        (or (runtime-dynamic-handler-hash handler)
            (format nil "handler:~A" name))
        "handler-cell:builtin")))

(defun runtime-dynamic-invocation (&optional (required t))
  (let ((scope (runtime-dynamic-current required)))
    (and scope (runtime-dynamic-scope-invocation scope))))

(defun runtime-dynamic-current-sandbox (&optional (required t))
  (let ((scope (runtime-dynamic-current required)))
    (and scope (runtime-dynamic-scope-sandbox scope))))

(defun runtime-dynamic-require-script-tier (message)
  (when (runtime-dynamic-in-node-p)
    (runtime-dynamic-error message "runtime.tier"))
  t)

(defun runtime-dynamic-without-observations (thunk)
  (runtime-dynamic-with-observation-collection nil thunk))

(defun runtime-dynamic-tail-capabilities-at (depth)
  (let ((stack (runtime-dynamic-capability-frames
                (runtime-dynamic-current))))
    (and (integerp depth) (>= depth 0)
         (> (length stack) (1+ depth))
         (copy-list (nth (1+ depth) stack)))))

(defun runtime-dynamic-tail-capability-depth ()
  (max 0 (1- (length (runtime-dynamic-capability-frames
                      (runtime-dynamic-current))))))

(defun runtime-dynamic-tail-handler-identities ()
  (runtime-dynamic-handler-identities))

(defun runtime-dynamic-tail-lookup-handler (name)
  (runtime-dynamic-find-handler name))

;;; Narrow compatibility spellings used by later runtime clients.
(setf (symbol-function 'current-capabilities) #'runtime-dynamic-capabilities)
(setf (symbol-function 'current-config) #'runtime-dynamic-config)
(setf (symbol-function 'current-handlers) #'runtime-dynamic-handlers)
(setf (symbol-function 'with-top-level) #'runtime-dynamic-with-top-level)

(setf (symbol-function 'runtime-with-top-level) #'runtime-dynamic-with-top-level)
(setf (symbol-function 'runtime-with-capabilities) #'runtime-dynamic-with-capabilities)
(setf (symbol-function 'runtime-with-config) #'runtime-dynamic-with-config)
(setf (symbol-function 'runtime-with-handlers) #'runtime-dynamic-with-handlers)
(setf (symbol-function 'runtime-with-node) #'runtime-dynamic-with-node)
(setf (symbol-function 'runtime-with-domain) #'runtime-dynamic-with-domain)