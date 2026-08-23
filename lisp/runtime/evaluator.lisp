;;;; M3 explicit continuation/work-queue evaluator.
;;;; No host EVAL, READ, or INTERN is used here.  All user syntax is already a
;;;; pp.kernel expression and all execution proceeds through the machine below.
(in-package #:pp.runtime)

;;; ---------------------------------------------------------------------------
;;; Errors, macro services, and force machinery

(defun runtime-evaluator-error
    (message &optional (code "evaluator.error") range)
  ;; Keep the range separate from MESSAGE.  The app/CLI normalizer can then
  ;; select the innermost range once, rather than having nested evaluator
  ;; boundaries accumulate textual prefixes.
  (language-fail message code range))

(defun runtime-evaluator-services (state)
  (make-runtime-macro-services
   :eval (lambda (expression environment)
           (runtime-evaluator-run-expression state expression environment))
   :force-deep (lambda (value) (runtime-evaluator-force-deep state value))
   :initial-env (lambda () (runtime-evaluator-state-initial-env state))))

(defun runtime-evaluator-expand-expression (state expression)
  (runtime-expand-expression
   (runtime-evaluator-services state)
   (runtime-evaluator-state-macro-state state)
   expression))

(defun runtime-evaluator-expand-toplevel (state expressions)
  (runtime-expand-toplevel
   (runtime-evaluator-services state)
   (runtime-evaluator-state-macro-state state)
   expressions))

 (defun runtime-evaluator-force-cycle (state thunk)
  (let* ((active (reverse (runtime-evaluator-state-force-stack state)))
         (start (or (cl:position thunk active :test #'eq) 0))
         (cycle (append (nthcdr start active) (list thunk))))
    (runtime-evaluator-error
     (format nil "cyclic binding: ~{~A~^ -> ~}"
             (mapcar (lambda (item)
                       (or (thunk-name item) "<anonymous binding>")) cycle))
     "evaluator.cycle")))

(defun runtime-evaluator-authority-value-p (state value)
  "Return an authority tag when VALUE or anything reachable carries authority."
  (let ((jobs (list value))
        (seen (make-hash-table :test #'eq)))
    (loop while jobs do
      (let ((item (pop jobs)))
        (unless (gethash item seen)
          (setf (gethash item seen) t)
          (cond
            ((typep item 'value-sealed)
             (return-from runtime-evaluator-authority-value-p :sealed))
            ((typep item 'value-capability)
             (return-from runtime-evaluator-authority-value-p :capability))
            ((typep item 'value-thunk)
             (push (runtime-evaluator-force state item) jobs))
            ((typep item 'value-closure)
             ;; A closure is authoritative only through the values its body
             ;; can actually reference.  Do not reject an otherwise ordinary
             ;; closure merely because its environment also contains caps;
             ;; follow the same free-variable boundary used by node keys.
             (let ((closure (value-closure-closure item)))
               (dolist (name (runtime-free-variable-names
                              (closure-body closure)))
                 (let ((captured
                         (runtime-evaluator-env-lookup
                          (closure-env closure) name)))
                   (when captured
                     (push captured jobs))))))
            ((typep item 'value-pair)
             (push (value-pair-car item) jobs)
             (push (value-pair-cdr item) jobs))
            ((typep item 'value-vector)
             (loop for member across (value-vector-values item)
                   do (push member jobs)))
            ((typep item 'value-map)
             (dolist (entry (value-map-entries item))
               (push (car entry) jobs)
               (push (cdr entry) jobs)))
            ((typep item 'value-set)
             (dolist (member (value-set-values item))
               (push member jobs)))
            ((typep item 'value-env-map)
             (dolist (entry (value-env-map-bindings item))
               (push (cdr entry) jobs)))))))
    nil))

(defun runtime-evaluator-sync-dynamic-state! (state)
  "Mirror the active dynamic extent into evaluator-owned callback state."
  (when (and (fboundp 'runtime-dynamic-current)
             (runtime-dynamic-current nil))
    (setf (runtime-evaluator-state-capabilities state)
          (copy-tree (runtime-dynamic-capabilities))
          (runtime-evaluator-state-config-stack state)
          (copy-tree (runtime-dynamic-config))
          (runtime-evaluator-state-handler-stack state)
          (copy-tree (runtime-dynamic-handlers))))
  state)

(defun runtime-evaluator-node-key (state thunk)
  (runtime-evaluator-sync-dynamic-state! state)
  (let ((expression (thunk-expression thunk))
        (environment (thunk-environment thunk)))
    (node-key
     :code expression
     :free-variables
     (mapcar
      (lambda (name)
        (let* ((value (runtime-evaluator-env-lookup environment name))
               (authority-kind
                 (and value (runtime-evaluator-authority-value-p state value))))
          (when authority-kind
            (runtime-evaluator-error
             (format nil
                     "node: free variable '~A' may not be or contain ~A"
                     name
                     (cond ((eq authority-kind :sealed) "a sealed value")
                           ((eq authority-kind :capability) "a capability")
                           (t "authority")))
             "evaluator.authority"))
          (cons name (and value (runtime-evaluator-force state value)))))
      (runtime-free-variable-names expression))
     :argument-values
     (if (typep (thunk-kind thunk) 'thunk-kind-persistent)
         (thunk-kind-persistent-argument-values (thunk-kind thunk))
         nil))))

(defun runtime-evaluator-type-name (type-expression)
  (cond
    ((typep type-expression 'expr-symbol) (expr-symbol-name type-expression))
    ((typep type-expression 'expr-literal)
     (let ((value (expr-literal-value type-expression)))
       (typecase value
         (value-symbol (value-symbol-value value))
         (value-keyword (value-keyword-value value))
         (value-string (value-string-value value))
         (t nil))))
    (t nil)))

 (defun runtime-evaluator-value-type-p (value type-name)
  (cond
    ((string= type-name "int") (typep value 'value-int))
    ((string= type-name "float") (typep value 'value-float))
    ((string= type-name "string") (typep value 'value-string))
    ((string= type-name "bool") (typep value 'value-bool))
    ((string= type-name "nil") (typep value 'value-nil))
    (t nil)))

(defun runtime-evaluator-value-description (value)
  "Describe VALUE without traversing delayed syntax or invoking host printers.

Typed boundaries are deliberately allowed to reject a thunk.  In particular,
the value held by a delay is still a kernel value-thunk, whose eventual
expression may be an expression record rather than a runtime value.  Calling
RUNTIME-STRING-OF-VALUE on that record leaks a host sequence/type condition
instead of the language type error we owe the caller."
  (typecase value
    (value-thunk "#<thunk>")
    (value-nil "nil")
    (value-bool (if (value-bool-value value) "true" "false"))
    (value-int (canonical-integer-string (value-int-value value)))
    (value-float
     (handler-case
         (runtime-string-of-value value)
       (error () "#<float>")))
    (value-string
     (handler-case
         (runtime-string-of-value value)
       (error () "#<string>")))
    (value-keyword (format nil ":~A" (value-keyword-value value)))
    (value-symbol (value-symbol-value value))
    (value-pair "#<pair>")
    (value-vector "#<vector>")
    (value-map "#<map>")
    (value-set "#<set>")
    (value-closure "#<fn>")
    (value-builtin "#<builtin>")
    (value-capability "#<capability>")
    (value-env-map "#<envmap>")
    (value-sealed "#<sealed>")
    ;; A malformed host object must still become a stable language error, not
    ;; an implementation-dependent printer/type condition.
    (t (format nil "#<~A>" (string-downcase (symbol-name (type-of value)))))))

(defun runtime-evaluator-enforce-thunk-type (thunk value)
  (let ((type-ann (thunk-type-ann thunk)))
    (when type-ann
      (let ((type-name (or (runtime-evaluator-type-name type-ann) "unknown")))
        (unless (runtime-evaluator-value-type-p value type-name)
          (runtime-evaluator-error
           (format nil "type mismatch: expected ~A, got ~A"
                   type-name (runtime-evaluator-value-description value))
           "evaluator.type" (thunk-location thunk)))))))

 (defun runtime-evaluator-force-thunk (state thunk)
  (when (member thunk (runtime-evaluator-state-force-stack state) :test #'eq)
    (runtime-evaluator-force-cycle state thunk))
  (runtime-evaluator-depth-enter! state)
  (push thunk (runtime-evaluator-state-force-stack state))
  (incf (runtime-evaluator-state-force-count state))
  (unwind-protect
       (handler-case
           (let* ((persistent (typep (thunk-kind thunk) 'thunk-kind-persistent))
                  (key (and persistent (runtime-evaluator-node-key state thunk)))
                  (key-string (and key (node-key-to-string key)))
                  (cached (and key-string
                               (gethash key-string
                                        (runtime-evaluator-state-persistent-cache state))))
                  (status (thunk-status thunk)))
             (cond
               ((typep status 'thunk-status-evaluating)
                (runtime-evaluator-force-cycle state thunk))
               ((typep status 'thunk-status-evaluated)
                (let ((result (thunk-status-evaluated-value status)))
                  (runtime-evaluator-enforce-thunk-type thunk result)
                  result))
               (cached
                (runtime-evaluator-enforce-thunk-type thunk cached)
                (setf (thunk-status thunk) (make-thunk-status-evaluated cached))
                cached)
               (t
                (setf (thunk-status thunk) (make-thunk-status-evaluating))
                (handler-case
                    (let* ((run (lambda ()
                                  (runtime-evaluator-run-expression
                                   state (thunk-expression thunk)
                                   (thunk-environment thunk))))
                           (result
                             (cond
                               ((not persistent) (funcall run))
                               ((runtime-evaluator-state-node-force-function state)
                                (funcall
                                 (runtime-evaluator-state-node-force-function state)
                                 state thunk key run))
                               (t
                                (runtime-evaluator-error
                                 "persistent node forcing requires an explicit node backend"
                                 "evaluator.node")))))
                      (when (and persistent
                                 (runtime-evaluator-authority-value-p state result))
                        (runtime-evaluator-error
                         "a node may not return a capability or sealed value"
                         "evaluator.authority"))
                      (runtime-evaluator-enforce-thunk-type thunk result)
                      (when persistent
                        (setf (gethash key-string
                                       (runtime-evaluator-state-persistent-cache state))
                              result))
                      (setf (thunk-status thunk)
                            (make-thunk-status-evaluated result))
                      result)
                  (language-error (condition)
                    (runtime-evaluator-reset-thunk! thunk)
                    (error condition))
                  (error (condition)
                    (runtime-evaluator-reset-thunk! thunk)
                    (runtime-evaluator-error
                     (format nil "~A" condition) "evaluator.host"))))))
         (language-error (condition) (error condition))
         (error (condition)
           (runtime-evaluator-error (format nil "~A" condition) "evaluator.host")))
    (setf (runtime-evaluator-state-force-stack state)
          (remove thunk (runtime-evaluator-state-force-stack state) :test #'eq))
    (runtime-evaluator-depth-leave! state)))
(defun runtime-evaluator-force (state value)
  "Force VALUE through the sole ephemeral/persistent thunk boundary."
  (let ((current value))
    (loop while (typep current 'value-thunk) do
      (setf current
            (runtime-evaluator-force-thunk
             state (value-thunk-thunk current))))
    current))

 (defun runtime-evaluator-force-deep (state value)
  "Force a value and all collection members using an explicit work stack."
  (let ((jobs (list (list :visit value)))
        (results nil))
    (loop while jobs do
      (runtime-evaluator-step! state)
      (let* ((job (pop jobs))
             (kind (first job))
             (item (second job)))
        (case kind
          (:visit
           (let ((forced (runtime-evaluator-force state item)))
             (typecase forced
               (value-pair
                (push (list :pair) jobs)
                (push (list :visit (value-pair-cdr forced)) jobs)
                (push (list :visit (value-pair-car forced)) jobs))
               (value-vector
                (let ((length (length (value-vector-values forced))))
                  (push (list :vector length) jobs)
                  (loop for index downfrom (1- length) to 0 do
                    (push (list :visit
                                (aref (value-vector-values forced) index))
                          jobs))))
               (value-map
                (let ((entries (value-map-entries forced)))
                  (push (list :map (length entries)) jobs)
                  (dolist (entry (reverse entries))
                    (push (list :visit (cdr entry)) jobs)
                    (push (list :visit (car entry)) jobs))))
               (value-set
                (let ((members (value-set-values forced)))
                  (push (list :set (length members)) jobs)
                  (dolist (member (reverse members))
                    (push (list :visit member) jobs))))
               (t (push forced results)))))
          (:pair
           (let ((cdr-value (pop results))
                 (car-value (pop results)))
             (push (make-vpair car-value cdr-value) results)))
          (:vector
           (let ((members (loop repeat item collect (pop results))))
             (push (make-vvector (coerce (nreverse members) 'vector))
                   results)))
          (:map
           (let ((entries nil))
             (loop repeat item do
               (let ((value (pop results))
                     (key (pop results)))
                 (push (cons key value) entries)))
             (push (make-vmap (canonical-map-entries (nreverse entries)))
                   results)))
          (:set
           (let ((members (loop repeat item collect (pop results))))
             (push (make-vset (canonical-set-elements (nreverse members)))
                   results))))))
    (or (pop results)
        (runtime-evaluator-error "deep force produced no value"
                                 "evaluator.force"))))

;;; ---------------------------------------------------------------------------
;;; Machine scheduling helpers

(defun runtime-evaluator-schedule (tasks kind data)
  (push (make-runtime-evaluator-task kind data) tasks)
  tasks)

(defun runtime-evaluator-schedule-eval (tasks expression environment continuation)
  (runtime-evaluator-schedule tasks :eval
                             (list expression environment continuation)))

(defun runtime-evaluator-schedule-continue (tasks value continuation)
  (runtime-evaluator-schedule tasks :continue (list value continuation)))

(defun runtime-evaluator-schedule-force (tasks value continuation)
  (runtime-evaluator-schedule tasks :force (list value continuation)))

(defun runtime-evaluator-frame (kind &rest data)
  (make-runtime-evaluator-frame kind data))

(defun runtime-evaluator-true-p (value)
  (not (or (typep value 'value-nil)
           (and (typep value 'value-bool)
                (not (value-bool-value value))))))

(defun runtime-evaluator-lookup (state environment name)
  (or (runtime-evaluator-env-lookup environment name)
      (runtime-primitive-lookup (runtime-evaluator-state-catalog state) name)
      (runtime-evaluator-error (format nil "unbound symbol: ~A" name)
                               "evaluator.unbound")))

(defun runtime-evaluator-string-like (value)
  (or (runtime-string-like value)
      (runtime-evaluator-error "expected a string, keyword, or symbol"
                               "evaluator.type")))

 (defun runtime-evaluator-config-lookup (state name)
  (loop for config in (runtime-evaluator-state-config-stack state)
        do (dolist (entry (value-map-entries config))
             (let ((key (runtime-string-like (car entry))))
               ;; Config maps are heterogeneous values.  Only string-like
               ;; keys participate in lookup; all other keys are ignored.
               (when (and key (string= name key))
                 (return-from runtime-evaluator-config-lookup
                   (values (cdr entry) t)))))
        finally (return (values nil nil))))

(defun runtime-evaluator-merge-module (scope value)
  (unless (typep value 'value-env-map)
    (runtime-evaluator-error "import expects a module value" "evaluator.import"))
  (runtime-evaluator-scope-merge scope (value-env-map-bindings value)))

;;; ---------------------------------------------------------------------------
;;; Application and continuation transitions

(defun runtime-evaluator-apply-value
    (state function arguments environment &key (defer nil))
  "Apply a function value.

DEFER is used only by callers that explicitly need a lazy callback result.
Ordinary primitive callbacks are eager and therefore run through the same
continuation machine as direct applications."
  (let ((function (runtime-evaluator-force state function))
        (arguments (mapcar (lambda (value)
                             (runtime-evaluator-force state value))
                           arguments)))
    (typecase function
      (value-closure
       (let* ((closure (value-closure-closure function))
              (params (closure-params closure))
              (extended
                (runtime-evaluator-env-extend-many
                 (closure-env closure) params arguments)))
         (unless (= (length params) (length arguments))
           (runtime-evaluator-error
            (format nil "~A expects ~D argument~:P, got ~D"
                    (or (closure-fn-name closure) "#<fn>")
                    (length params) (length arguments))
            "evaluator.arity"))
         (if (typep (closure-closure-kind closure) 'closure-kind-node)
             (make-vthunk
              (runtime-evaluator-make-thunk
               (closure-body closure) extended
               :name (closure-fn-name closure)
               :kind (make-persistent-thunk-kind
                      (copy-list (runtime-evaluator-state-capabilities state))
                      (copy-list arguments))))
             (if defer
                 (make-vthunk
                  (runtime-evaluator-make-thunk
                   (closure-body closure) extended))
                 ;; Callback application uses the explicit machine as its
                 ;; only evaluator; it never falls back to host EVAL/READ.
                 (runtime-evaluator-run
                  state
                  (list (make-runtime-evaluator-task
                         :eval (list (closure-body closure) extended nil))))))))
      (value-builtin
       (if (member (value-builtin-name function) '("map" "apply")
                   :test #'string=)
           ;; Batch callbacks must use the same machine as ordinary
           ;; applications; this path also keeps recursive map/app callbacks
           ;; off the host control stack.
           (runtime-evaluator-run
            state
            (list
             (make-runtime-evaluator-task
              :continue
              (list function
                    (list (runtime-evaluator-frame
                           :apply-final function nil (reverse arguments)
                           environment))))))
           (runtime-primitive-call
            function arguments environment
            :force (lambda (value) (runtime-evaluator-force state value))
            :force-deep (lambda (value)
                          (runtime-evaluator-force-deep state value))
            :eval (lambda (expression env)
                    (runtime-evaluator-run-expression state expression env))
            :eager (lambda (fn args env)
                     (runtime-evaluator-apply-value state fn args env
                                                    :defer nil))
            :apply (lambda (fn args env)
                     (runtime-evaluator-apply-value
                      state fn args env :defer nil)))))
      (t
       (runtime-evaluator-error
        (format nil "not a function: ~A" (runtime-string-of-value function))
        "evaluator.type")))))

(defun runtime-evaluator-notify-restore (callback state value)
  (when callback
    (funcall callback state value)))

(defun runtime-evaluator-notify-capabilities (state value)
  "Synchronize a capability transition with the dynamic scope callback.

The evaluator stores a flat capability list, while the dynamic scope stores
capability frames.  Keep both views aligned before and after a callback so a
callback that observes the scope cannot leak a host list shape."
  (let ((capabilities (if (typep value 'capability)
                          (list value)
                          (copy-list value))))
    (when (fboundp 'runtime-dynamic-sync-capabilities!)
      (runtime-dynamic-sync-capabilities! capabilities))
    (runtime-evaluator-notify-restore
     (runtime-evaluator-state-with-capabilities-function state)
     state value)
    (when (fboundp 'runtime-dynamic-sync-capabilities!)
      (runtime-dynamic-sync-capabilities! capabilities)))
  value)

(defun runtime-evaluator-restore-capabilities! (state saved)
  (setf (runtime-evaluator-state-capabilities state) (copy-list saved))
  (runtime-evaluator-notify-capabilities state saved))

 (defun runtime-evaluator-restore-handlers! (state saved)
  (setf (runtime-evaluator-state-handler-stack state) saved)
  (runtime-evaluator-notify-restore
   (runtime-evaluator-state-with-handlers-function state) state saved))

 (defun runtime-evaluator-restore-config! (state saved)
  (setf (runtime-evaluator-state-config-stack state) saved)
  (runtime-evaluator-notify-restore
   (runtime-evaluator-state-with-config-function state) state saved))

 (defun runtime-evaluator-perform (state name arguments environment)
  (let ((handler (loop for handlers in (runtime-evaluator-state-handler-stack state)
                       for entry = (assoc name handlers :test #'string=)
                       when entry do (return (cdr entry)))))
    (cond
      (handler (runtime-evaluator-apply-value state handler arguments environment))
      ((runtime-evaluator-state-perform-function state)
       (funcall (runtime-evaluator-state-perform-function state)
                state name arguments environment))
      (t (runtime-evaluator-error
          (format nil "unhandled effect: ~A" name) "evaluator.effect")))))

(defun runtime-evaluator-cont (state tasks value continuation)
  (if (null continuation)
      (runtime-evaluator-schedule tasks :finish value)
      (let* ((frame (first continuation))
             (rest (rest continuation))
             (kind (runtime-evaluator-frame-kind frame))
             (data (runtime-evaluator-frame-data frame)))
        (case kind
          (:located
           (let ((saved (first data)))
             (setf (runtime-evaluator-state-current-location state) saved
                   (runtime-evaluator-state-location-stack state)
                   (rest (runtime-evaluator-state-location-stack state)))
             (runtime-evaluator-schedule-continue tasks value rest)))
          (:force
           (runtime-evaluator-schedule-force tasks value rest))
          (:branch
           (destructuring-bind (yes no environment) data
             (runtime-evaluator-schedule-eval
              tasks (if (runtime-evaluator-true-p value) yes no)
              environment rest)))
          (:apply-function
           (destructuring-bind (arguments environment) data
             (if arguments
                 (runtime-evaluator-schedule-eval
                  tasks (first arguments) environment
                  (cons (runtime-evaluator-frame
                         :apply-argument
                         value (rest arguments) nil environment)
                        rest))
                 ;; An empty argument list still performs an application.
                 (runtime-evaluator-schedule-continue
                  tasks value
                  (cons (runtime-evaluator-frame
                         :apply-final value nil nil environment)
                        rest)))))
          (:apply-argument
           (destructuring-bind (function remaining reversed environment) data
             (if remaining
                 (runtime-evaluator-schedule-eval
                  tasks (first remaining) environment
                  (cons (runtime-evaluator-frame
                         :apply-argument function (rest remaining)
                         (cons value reversed) environment)
                        rest))
                 (runtime-evaluator-schedule-continue
                  tasks value
                  (cons (runtime-evaluator-frame
                         :apply-final function nil (cons value reversed)
                         environment)
                        rest)))))
          (:apply-final
           (destructuring-bind (function ignored reversed environment) data
             (declare (ignore ignored))
             ;; Tail application is represented by scheduling the body in the
             ;; current machine rather than calling a recursive evaluator.
             (let ((function (runtime-evaluator-force state function))
                   (arguments (mapcar (lambda (item)
                                        (runtime-evaluator-force state item))
                                      (reverse reversed))))
               (typecase function
                 (value-closure
                  (let* ((closure (value-closure-closure function))
                         (params (closure-params closure)))
                    (unless (= (length params) (length arguments))
                      (runtime-evaluator-error
                       (format nil "~A expects ~D argument~:P, got ~D"
                               (or (closure-fn-name closure) "#<fn>")
                               (length params) (length arguments))
                       "evaluator.arity"))
                    (if (typep (closure-closure-kind closure)
                               'closure-kind-node)
                        (runtime-evaluator-schedule-continue
                         tasks
                         (make-vthunk
                          (runtime-evaluator-make-thunk
                           (closure-body closure)
                           (runtime-evaluator-env-extend-many
                            (closure-env closure) params arguments)
                           :name (closure-fn-name closure)
                           :kind (make-persistent-thunk-kind
                                  (copy-list
                                   (runtime-evaluator-state-capabilities state))
                                  (copy-list arguments))))
                         rest)
                        (runtime-evaluator-schedule-eval
                         tasks (closure-body closure)
                         (runtime-evaluator-env-extend-many
                          (closure-env closure) params arguments)
                         rest))))
                 (value-builtin
                  (let ((name (value-builtin-name function)))
                    (cond
                      ((string= name "map")
                       (unless (= (length arguments) 2)
                         (runtime-primitive-arity-error
                          "map" 2 (length arguments)))
                       (setf tasks
                             (runtime-evaluator-schedule
                              tasks :map-step
                              (list (first arguments) (second arguments)
                                    nil environment rest))))
                      ((string= name "apply")
                       (unless (>= (length arguments) 2)
                         (runtime-primitive-arity-error
                          "apply" "a function and at least one list segment"
                          (length arguments)))
                       (setf tasks
                             (runtime-evaluator-schedule
                              tasks :apply-segments
                              (list (first arguments) (rest arguments) nil
                                    environment rest))))
                      (t
                       (runtime-evaluator-schedule-continue
                        tasks
                        (runtime-primitive-call
                         function arguments environment
                         :force (lambda (item)
                                  (runtime-evaluator-force state item))
                         :force-deep (lambda (item)
                                       (runtime-evaluator-force-deep state item))
                         :eval (lambda (expression env)
                                 (runtime-evaluator-run-expression
                                  state expression env))
                         :eager (lambda (fn args env)
                                  (runtime-evaluator-apply-value
                                   state fn args env :defer nil))
                         :apply (lambda (fn args env)
                                  (runtime-evaluator-apply-value
                                   state fn args env :defer nil)))
                        rest)))))
                 (t (runtime-evaluator-error
                     (format nil "not a function: ~A"
                             (runtime-string-of-value function))
                     "evaluator.type"))))))
          (:letstar
           (destructuring-bind (name remaining body environment) data
             (let ((next-env
                     (runtime-evaluator-env-extend environment name value)))
               (if remaining
                   (runtime-evaluator-schedule-eval
                    tasks (cdar remaining) next-env
                    (cons (runtime-evaluator-frame
                           :letstar (caar remaining) (rest remaining)
                           body next-env)
                          rest))
                   (runtime-evaluator-schedule-eval
                    tasks body next-env rest)))))
          (:perform-argument
           (destructuring-bind (name remaining reversed environment) data
             (let ((forced (runtime-evaluator-force state value)))
               (if remaining
                   (runtime-evaluator-schedule-eval
                    tasks (first remaining) environment
                    (cons (runtime-evaluator-frame
                           :perform-argument name (rest remaining)
                           (cons forced reversed) environment)
                          rest))
                   (runtime-evaluator-schedule-continue
                    tasks
                    (runtime-evaluator-perform
                     state name (reverse (cons forced reversed)) environment)
                    rest)))))
          (:caps
           (let ((capability (runtime-evaluator-force state value)))
             (unless (typep capability 'value-capability)
               (runtime-evaluator-error
                "with-caps expects a capability value" "evaluator.capability"))
             (let ((requested (value-capability-capability capability))
                   (saved (copy-list
                           (runtime-evaluator-state-capabilities state))))
               (unless (capability-subseteq-p
                        requested (runtime-evaluator-state-capabilities state))
                 (runtime-evaluator-error
                  "with-caps cannot widen ambient capabilities"
                  "evaluator.capability"))
               ;; Re-enter in a task after any nested force machine has
               ;; restored its own saved ambient.
               (setf tasks
                     (runtime-evaluator-schedule
                      tasks :caps-enter
                      (list requested (first data) (second data)
                            saved rest))))))
          (:config-scope
           (let ((config (runtime-evaluator-force state value)))
             (unless (typep config 'value-map)
               (runtime-evaluator-error
                "with-config expects a map" "evaluator.config"))
             (let ((saved (runtime-evaluator-state-config-stack state)))
               (when (runtime-evaluator-state-with-config-function state)
                 (funcall (runtime-evaluator-state-with-config-function state)
                          state config))
               (setf (runtime-evaluator-state-config-stack state)
                     (cons config saved))
               (runtime-evaluator-schedule-eval
                tasks (first data) (second data)
                (cons (runtime-evaluator-frame :with-config saved) rest)))))
          (:handler-one
           (destructuring-bind (pending evaluated environment body) data
             (runtime-evaluator-schedule
              tasks :handler-eval
              (list (rest pending)
                    (cons (cons (first (first pending))
                                (runtime-evaluator-force state value))
                          evaluated)
                    environment body rest))))
          (:import
           (unless (typep value 'value-env-map)
             (runtime-evaluator-error
              "import expects a module value" "evaluator.import"))
           (runtime-evaluator-schedule-continue tasks value rest))
          (:match-scrutinee
           (runtime-evaluator-schedule
            tasks :match-try (list value (first data) (second data) rest)))
          (:match-guard
           (destructuring-bind (scrutinee body arm-env remaining) data
             (let ((guard (runtime-evaluator-force state value)))
               (if (runtime-evaluator-true-p guard)
                   (runtime-evaluator-schedule-eval tasks body arm-env rest)
                   (runtime-evaluator-schedule
                    tasks :match-try
                    (list scrutinee remaining arm-env rest))))))
          (:with-handlers
           (let ((saved (first data)))
             (runtime-evaluator-restore-handlers! state saved)
             (runtime-evaluator-schedule-continue tasks value rest)))
          (:with-caps
           (let ((saved (first data)))
             (runtime-evaluator-restore-capabilities! state saved)
             (runtime-evaluator-schedule-continue tasks value rest)))
          (:with-config
           (let ((saved (first data)))
             (runtime-evaluator-restore-config! state saved)
             (runtime-evaluator-schedule-continue tasks value rest)))
          (:map-result
           (destructuring-bind (function remaining results environment) data
             (runtime-evaluator-schedule
              tasks :map-step
              (list function remaining (cons value results)
                    environment rest))))
          (:typed
           (runtime-evaluator-schedule-continue tasks value rest))
          (:do-step
           (destructuring-bind (scope remaining mode) data
             (runtime-evaluator-schedule
              tasks :do-step (list scope remaining mode rest))))
          (:do-activate
           (destructuring-bind (scope name mode) data
             (runtime-evaluator-scope-activate-value scope name value)
             (if (eq mode :module)
                 ;; Module definitions are sequenced for their side effect;
                 ;; the module expression itself returns its export map.
                 (runtime-evaluator-schedule
                  tasks :do-step (list scope nil mode rest))
                 (runtime-evaluator-schedule-continue tasks value rest))))
          (:do-import
           (destructuring-bind (scope remaining finalp mode) data
             (runtime-evaluator-merge-module scope value)
             (if (eq mode :module)
                 ;; Imports in a module contribute bindings and never become
                 ;; the module result; finish by exporting the scope.
                 (runtime-evaluator-schedule
                  tasks :do-step
                  (list scope (if finalp nil remaining) mode rest))
                 (if finalp
                     ;; Import is a sequencing form: its module is merged,
                     ;; but the do-block result is nil even when terminal.
                     (runtime-evaluator-schedule-continue
                      tasks (make-vnil) rest)
                     (runtime-evaluator-schedule
                      tasks :do-step (list scope remaining nil rest))))))
          (:do-result
           (destructuring-bind (scope remaining finalp mode) data
             (when (typep value 'value-env-map)
               (runtime-evaluator-scope-merge
                scope (value-env-map-bindings value)))
             (if (eq mode :module)
                 ;; A module always evaluates all body forms and returns its
                 ;; exported environment, rather than its final expression.
                 (runtime-evaluator-schedule
                  tasks :do-step
                  (list scope (if finalp nil remaining) mode rest))
                 (if finalp
                     (runtime-evaluator-schedule-continue tasks value rest)
                     (runtime-evaluator-schedule tasks :do-step
                                                 (list scope remaining nil rest))))))
          (:module-result
           (let ((scope (first data)))
             (runtime-evaluator-schedule-continue
              tasks (runtime-evaluator-scope-export scope) rest)))
          (:handler-evaluated
           (destructuring-bind (scope pending evaluated environment body) data
             (declare (ignore scope))
             (runtime-evaluator-schedule
              tasks :handler-eval
              (list pending (cons (cons (first (first pending)) value) evaluated)
                    environment body rest))))
          (:config
           (destructuring-bind (default environment) data
             (multiple-value-bind (configured present)
                 (runtime-evaluator-config-lookup state
                                                  (runtime-evaluator-string-like value))
               (cond
                 (present (runtime-evaluator-schedule-continue tasks configured rest))
                 (default (runtime-evaluator-schedule-eval tasks default environment rest))
                 (t (runtime-evaluator-schedule-continue tasks (make-vnil) rest))))))
          (:load
           (destructuring-bind (scope remaining mode finalp) data
             ;; A loader returns the exports of its evaluated forms.  Merge
             ;; those bindings before sequencing the enclosing block so later
             ;; forms can resolve names from the loaded source.
             (when (typep value 'value-env-map)
               (runtime-evaluator-scope-merge
                scope (value-env-map-bindings value)))
             (if (eq mode :module)
                 ;; Loading in a module is also sequencing; preserve the
                 ;; exported-module result at the end of the body.
                 (runtime-evaluator-schedule
                  tasks :do-step
                  (list scope (if finalp nil remaining) mode rest))
                 (if finalp
                     ;; A load in a do-block is sequencing, not the block
                     ;; value.
                     (runtime-evaluator-schedule-continue tasks (make-vnil) rest)
                     (runtime-evaluator-schedule
                      tasks :do-step (list scope remaining mode rest))))))
          (otherwise
           (runtime-evaluator-error
            (format nil "unknown evaluator continuation ~A" kind)
            "evaluator.machine")))))
  )

;;; ---------------------------------------------------------------------------
;;; Machine evaluator


(defun runtime-evaluator-eval-form (state expression environment continuation tasks)
  (cond
    ((typep expression 'expr-literal)
     (runtime-evaluator-schedule-continue
      tasks (expr-literal-value expression) continuation))
    ((typep expression 'expr-symbol)
     (runtime-evaluator-schedule-force
      tasks
      (runtime-evaluator-lookup state environment
                                (expr-symbol-name expression))
      continuation))
    ((typep expression 'expr-located)
     (let* ((range (expr-located-range expression))
            (inner (expr-located-expression expression))
            (saved (runtime-evaluator-state-current-location state)))
       (push range (runtime-evaluator-state-location-stack state))
       (setf (runtime-evaluator-state-current-location state) range)
       (if (typep inner 'expr-typed)
           (runtime-evaluator-schedule-continue
            tasks
            (make-vthunk
             (runtime-evaluator-make-thunk
              (expr-typed-expression inner) environment
              :type-ann (expr-typed-type inner) :location range))
            (cons (runtime-evaluator-frame :located saved) continuation))
           (runtime-evaluator-schedule-eval
            tasks inner environment
            (cons (runtime-evaluator-frame :located saved) continuation)))))
    ((typep expression 'expr-if)
     (runtime-evaluator-schedule-eval
      tasks (expr-if-condition expression) environment
      (cons (runtime-evaluator-frame :force)
            (cons (runtime-evaluator-frame
                   :branch (expr-if-then expression)
                   (expr-if-else expression) environment)
                  continuation))))
    ((typep expression 'expr-let)
     (let* ((bindings (expr-let-bindings expression))
            (scope environment)
            (thunks (mapcar (lambda (binding)
                              (runtime-evaluator-make-thunk
                               (cdr binding) environment :name (car binding)))
                            bindings)))
       (dolist (binding (mapcar #'cons (mapcar #'car bindings) thunks))
         (setf scope
               (runtime-evaluator-env-extend
                scope (car binding) (make-vthunk (cdr binding)))))
       (dolist (thunk thunks) (setf (thunk-environment thunk) scope))
       (runtime-evaluator-schedule-eval
        tasks (expr-let-body expression) scope continuation)))
    ((typep expression 'expr-letstar)
     (let ((bindings (expr-letstar-bindings expression)))
       (if bindings
           (runtime-evaluator-schedule-eval
            tasks (cdar bindings) environment
            (cons (runtime-evaluator-frame
                   :letstar
                   (car (first bindings)) (rest bindings)
                   (expr-letstar-body expression) environment)
                  continuation))
           (runtime-evaluator-schedule-eval
            tasks (expr-letstar-body expression) environment continuation))))
    ((typep expression 'expr-fn)
     (runtime-evaluator-schedule-continue
      tasks
      (make-vclosure
       (make-closure (expr-fn-params expression) (expr-fn-body expression)
                     environment))
      continuation))
    ((typep expression 'expr-apply)
     (runtime-evaluator-schedule-eval
      tasks (expr-apply-function expression) environment
      (cons (runtime-evaluator-frame :force)
            (cons (runtime-evaluator-frame
                   :apply-function (expr-apply-arguments expression)
                   environment)
                  continuation))))
    ((typep expression 'expr-quote)
     (runtime-evaluator-schedule-continue
      tasks (runtime-quote-to-value (expr-quote-expression expression))
      continuation))
    ((typep expression 'expr-force)
     (runtime-evaluator-schedule-eval
      tasks (expr-force-expression expression) environment
      (cons (runtime-evaluator-frame :force) continuation)))
    ((typep expression 'expr-delay)
     (runtime-evaluator-schedule-continue
      tasks (make-vthunk
             (runtime-evaluator-make-thunk
              (expr-delay-expression expression) environment))
      continuation))
    ((typep expression 'expr-node)
     (runtime-evaluator-schedule-continue
      tasks (make-vthunk
             (runtime-evaluator-make-thunk
              (expr-node-expression expression) environment
              :kind
              (make-persistent-thunk-kind
               (copy-list (runtime-evaluator-state-capabilities state))
               nil)))
      continuation))
    ((typep expression 'expr-typed)
     (runtime-evaluator-schedule-continue
      tasks (make-vthunk
             (runtime-evaluator-make-thunk
              (expr-typed-expression expression) environment
              :type-ann (expr-typed-type expression)))
      continuation))
    ((typep expression 'expr-with-caps)
     (runtime-evaluator-schedule-eval
      tasks (expr-with-caps-caps expression) environment
      (cons (runtime-evaluator-frame :force)
            (cons (runtime-evaluator-frame
                   :caps (expr-with-caps-body expression) environment)
                  continuation))))
    ((typep expression 'expr-perform)
     (let ((arguments (expr-perform-arguments expression)))
       (if arguments
           (runtime-evaluator-schedule-eval
            tasks (first arguments) environment
            (cons (runtime-evaluator-frame
                   :perform-argument
                   (expr-perform-name expression) (rest arguments)
                   nil environment)
                  continuation))
           (runtime-evaluator-schedule-continue
            tasks (runtime-evaluator-perform state
                                             (expr-perform-name expression)
                                             nil environment)
            continuation))))
    ((typep expression 'expr-with-handler)
     (runtime-evaluator-schedule
      tasks :handler-eval
      (list (expr-with-handler-handlers expression) nil environment
            (expr-with-handler-body expression) continuation)))
    ((typep expression 'expr-def)
     (runtime-evaluator-schedule-continue
      tasks (make-vclosure
             (make-closure (expr-def-params expression) (expr-def-body expression)
                           environment :fn-name (expr-def-name expression)))
      continuation))
    ((typep expression 'expr-defnode)
     (runtime-evaluator-schedule-continue
      tasks (make-vclosure
             (make-closure (expr-defnode-params expression)
                           (expr-defnode-body expression) environment
                           :fn-name (expr-defnode-name expression)
                           :closure-kind :node))
      continuation))
    ((typep expression 'expr-defvalue)
     (runtime-evaluator-schedule-eval
      tasks (expr-defvalue-expression expression) environment continuation))
    ((typep expression 'expr-do)
     (let ((scope (runtime-evaluator-make-scope
                   state environment (expr-do-expressions expression))))
       (runtime-evaluator-schedule tasks :do-step
                                   (list scope (expr-do-expressions expression)
                                         nil continuation))))
    ((typep expression 'expr-module)
     (let* ((base (runtime-evaluator-state-initial-env state))
            (scope (runtime-evaluator-make-scope
                    state base (expr-module-expressions expression))))
       (runtime-evaluator-schedule tasks :do-step
                                   (list scope (expr-module-expressions expression)
                                         :module continuation))))
    ((typep expression 'expr-import)
     (runtime-evaluator-schedule-eval
      tasks (expr-import-expression expression) environment
      (cons (runtime-evaluator-frame :force)
            (cons (runtime-evaluator-frame :import) continuation))))
    ((typep expression 'expr-load)
     (unless (runtime-evaluator-state-load-function state)
       (runtime-evaluator-error "load requires an explicit loader callback"
                                "evaluator.load"))
     (runtime-evaluator-schedule-continue
      tasks (funcall (runtime-evaluator-state-load-function state)
                     state (expr-load-path expression) environment)
      continuation))
    ((typep expression 'expr-loadmodule)
     (unless (runtime-evaluator-state-load-module-function state)
       (runtime-evaluator-error "load-module requires an explicit loader callback"
                                "evaluator.load"))
     (runtime-evaluator-schedule-continue
      tasks (funcall (runtime-evaluator-state-load-module-function state)
                     state (expr-loadmodule-path expression))
      continuation))
    ((typep expression 'expr-island)
     (unless (runtime-evaluator-state-island-function state)
       (runtime-evaluator-error "island requires an explicit resolver callback"
                                "evaluator.island"))
     (runtime-evaluator-schedule-continue
      tasks (funcall (runtime-evaluator-state-island-function state)
                     state (expr-island-uri expression) (expr-island-pin expression))
      continuation))
    ((typep expression 'expr-with-config)
     (runtime-evaluator-schedule-eval
      tasks (expr-with-config-map-expression expression) environment
      (cons (runtime-evaluator-frame :force)
            (cons (runtime-evaluator-frame
                   :config-scope (expr-with-config-body expression)
                   environment)
                  continuation))))
    ((typep expression 'expr-config)
     (runtime-evaluator-schedule-eval
      tasks (expr-config-key-expression expression) environment
      (cons (runtime-evaluator-frame :force)
            (cons (runtime-evaluator-frame
                   :config (expr-config-default expression) environment)
                  continuation))))
    ((typep expression 'expr-match)
     (runtime-evaluator-schedule-eval
      tasks (expr-match-scrutinee expression) environment
      (cons (runtime-evaluator-frame :force)
            (cons (runtime-evaluator-frame
                   :match-scrutinee (expr-match-arms expression) environment)
                  continuation))))
    (t (runtime-evaluator-error "unknown expression structure"
                                "evaluator.expression"))))

(defun runtime-evaluator-more-inner-location-p
    (candidate previous candidate-depth previous-depth)
  "Whether CANDIDATE is a more specific source location than PREVIOUS.

Nested machine runs can unwind in caller order.  The active located-expression
depth is authoritative across source paths; same-depth ranges are compared by
containment as a defensive fallback."
  (and candidate previous
       (or (> candidate-depth previous-depth)
           (and (= candidate-depth previous-depth)
                (string= (source-range-source candidate)
                         (source-range-source previous))
                (<= (compare-positions
                     (source-range-start previous)
                     (source-range-start candidate))
                    0)
                (<= (compare-positions
                     (source-range-end candidate)
                     (source-range-end previous))
                    0)
                (or (/= (compare-positions
                         (source-range-start previous)
                         (source-range-start candidate))
                        0)
                    (/= (compare-positions
                         (source-range-end candidate)
                         (source-range-end previous))
                        0))))))


(defun runtime-evaluator-unwind-state!
    (state capabilities handlers configs location
     &optional (location-stack nil))
  "Restore dynamic extents when the machine exits through a condition.

The evaluator can have nested machine runs (for example, a primitive callback
or a metaprogramming operation).  Only an unwind with a live location observed
an error; retain the most specific location so outer cleanup cannot replace an
innermost source range with its caller's range (or NIL)."
  (unless (equal (runtime-evaluator-state-capabilities state) capabilities)
    (setf (runtime-evaluator-state-capabilities state)
          (copy-list capabilities))
    (ignore-errors
      (runtime-evaluator-notify-capabilities state capabilities)))
  (unless (equal (runtime-evaluator-state-handler-stack state) handlers)
    (setf (runtime-evaluator-state-handler-stack state) handlers)
    (ignore-errors
      (runtime-evaluator-notify-restore
       (runtime-evaluator-state-with-handlers-function state)
       state handlers)))
  (unless (equal (runtime-evaluator-state-config-stack state) configs)
    (setf (runtime-evaluator-state-config-stack state) configs)
    (ignore-errors
      (runtime-evaluator-notify-restore
       (runtime-evaluator-state-with-config-function state)
       state configs)))
  (let* ((error-location (runtime-evaluator-state-current-location state))
         (error-stack (runtime-evaluator-state-location-stack state))
         (error-depth (length error-stack))
         (previous (runtime-evaluator-state-last-error-location state))
         (previous-depth
           (runtime-evaluator-state-last-error-location-depth state)))
    (when (and error-location
               (or (null previous)
                   (runtime-evaluator-more-inner-location-p
                    error-location previous error-depth previous-depth)))
      (setf (runtime-evaluator-state-last-error-location state)
            error-location
            (runtime-evaluator-state-last-error-location-depth state)
            error-depth))
    (setf (runtime-evaluator-state-current-location state) location
          ;; Preserve the active error stack while conditions unwind through
          ;; nested machine runs; successful runs restore their saved stack.
          (runtime-evaluator-state-location-stack state)
          (if (and error-location error-stack)
              error-stack
              location-stack))))

 (defun runtime-evaluator-run (state initial-tasks)
  (runtime-evaluator-sync-dynamic-state! state)
  (let ((tasks initial-tasks)
        (result nil)
        (finished nil)
        (saved-capabilities (copy-tree
                             (runtime-evaluator-state-capabilities state)))
        (saved-handlers (copy-tree
                         (runtime-evaluator-state-handler-stack state)))
        (saved-configs (copy-tree
                        (runtime-evaluator-state-config-stack state)))
        (saved-location (runtime-evaluator-state-current-location state))
        (saved-location-stack
          (copy-tree (runtime-evaluator-state-location-stack state))))
    (unwind-protect
         (loop until finished do
      (unless tasks
        (runtime-evaluator-error "machine stopped without a result"
                                 "evaluator.machine"))
      (runtime-evaluator-step! state)
      (let* ((task (pop tasks))
             (kind (runtime-evaluator-task-kind task))
             (data (runtime-evaluator-task-data task)))
        (case kind
          (:finish
           (setf result data finished t))
          (:eval
           (destructuring-bind (expression environment continuation) data
             (setf tasks
                   (runtime-evaluator-eval-form
                    state expression environment continuation tasks))))
          (:force
           (destructuring-bind (value continuation) data
             (setf tasks
                   (runtime-evaluator-schedule-continue
                    tasks (runtime-evaluator-force state value) continuation))))
          (:continue
           (destructuring-bind (value continuation) data
             (setf tasks
                   (runtime-evaluator-cont state tasks value continuation))))
          (:caps-enter
           (destructuring-bind (requested body environment saved continuation)
               data
             (runtime-evaluator-notify-capabilities state requested)
             (setf (runtime-evaluator-state-capabilities state)
                   (list requested))
             (when (fboundp 'runtime-dynamic-sync-capabilities!)
               (runtime-dynamic-sync-capabilities! (list requested)))
             (setf tasks
                   (runtime-evaluator-schedule-eval
                    tasks body environment
                    (cons (runtime-evaluator-frame :with-caps saved)
                          continuation)))))
          (:handler-eval
           (destructuring-bind (pending evaluated environment body continuation) data
             (if pending
                 (setf tasks
                       (runtime-evaluator-schedule-eval
                        tasks (cdr (first pending)) environment
                        (cons (runtime-evaluator-frame
                               :handler-one pending evaluated environment body)
                              continuation)))
                 (let ((saved (runtime-evaluator-state-handler-stack state))
                       (handlers (nreverse evaluated)))
                   (when (runtime-evaluator-state-with-handlers-function state)
                     (funcall (runtime-evaluator-state-with-handlers-function state)
                              state handlers))
                   (setf (runtime-evaluator-state-handler-stack state)
                         (cons handlers saved))
                   (setf tasks
                         (runtime-evaluator-schedule-eval
                          tasks body environment
                          (cons (runtime-evaluator-frame :with-handlers saved)
                                continuation)))))))
          (:match-try
           (destructuring-bind (value arms environment continuation) data
             (if (null arms)
                 (runtime-evaluator-error "match failure" "evaluator.match")
                 (destructuring-bind (pattern guard body) (first arms)
                   (multiple-value-bind (bindings matched)
                       (runtime-match-pattern value pattern)
                     (if matched
                         (let ((arm-environment environment))
                           (dolist (entry bindings)
                             (setf arm-environment
                                   (runtime-evaluator-env-extend
                                    arm-environment (car entry) (cdr entry))))
                           (if guard
                               (setf tasks
                                     (runtime-evaluator-schedule-eval
                                      tasks guard arm-environment
                                      (cons (runtime-evaluator-frame
                                             :match-guard value body
                                             arm-environment (rest arms))
                                            continuation)))
                               (setf tasks
                                     (runtime-evaluator-schedule-eval
                                      tasks body arm-environment continuation))))
                         (setf tasks
                               (runtime-evaluator-schedule
                                tasks :match-try
                                (list value (rest arms) environment continuation)))))))))
          (:map-step
           (destructuring-bind
               (function remaining results environment continuation)
               data
             (let ((list-value (runtime-evaluator-force state remaining)))
               (typecase list-value
                 (value-nil
                  (setf tasks
                        (runtime-evaluator-schedule-continue
                         tasks (value-list (nreverse results))
                         continuation)))
                 (value-pair
                  (setf tasks
                        (runtime-evaluator-schedule-continue
                         tasks function
                         (cons (runtime-evaluator-frame
                                :apply-final function nil
                                (list (value-pair-car list-value))
                                environment)
                               (cons (runtime-evaluator-frame
                                      :map-result function
                                      (value-pair-cdr list-value)
                                      results environment)
                                     continuation)))))
                 (t
                  (runtime-evaluator-error
                   "map expects a proper list" "primitive.type"))))))
          (:apply-segments
           (destructuring-bind
               (function segments collected environment continuation)
               data
             (if (null segments)
                 (setf tasks
                       (runtime-evaluator-schedule-continue
                        tasks function
                        (cons (runtime-evaluator-frame
                               :apply-final function nil collected environment)
                              continuation)))
                 (let ((segment (runtime-evaluator-force state
                                                         (first segments))))
                   (typecase segment
                     (value-nil
                      (setf tasks
                            (runtime-evaluator-schedule
                             tasks :apply-segments
                             (list function (rest segments) collected
                                   environment continuation))))
                     (value-pair
                      (setf tasks
                            (runtime-evaluator-schedule
                             tasks :apply-segments
                             (list function
                                   (cons (value-pair-cdr segment)
                                         (rest segments))
                                   (cons (value-pair-car segment) collected)
                                   environment continuation))))
                     (t
                      (runtime-evaluator-error
                       "apply expects proper list segments"
                       "primitive.type")))))))
          (:do-step
           (destructuring-bind (scope remaining mode continuation) data
             (if (null remaining)
                 (setf tasks
                       (runtime-evaluator-cont
                        state tasks
                        (if (eq mode :module)
                            (runtime-evaluator-scope-export scope)
                            (make-vnil))
                        continuation))
                 (let* ((expression (first remaining))
                        (rest-forms (rest remaining))
                        (inner (runtime-evaluator-unwrapped-expression expression))
                        (lastp (null rest-forms))
                        (scope-env (runtime-definition-scope-environment scope)))
                   (cond
                    ((or (typep inner 'expr-def)
                         (typep inner 'expr-defnode))
                     (let ((name (if (typep inner 'expr-def)
                                     (expr-def-name inner)
                                     (expr-defnode-name inner))))
                       (if (and lastp (eq mode :module))
                           ;; A module definition is evaluated for its
                           ;; binding, then the module returns its exports.
                           (setf tasks
                                 (runtime-evaluator-schedule
                                  tasks :do-step
                                  (list scope nil mode continuation)))
                           (setf tasks
                                 (runtime-evaluator-cont
                                  state tasks
                                  (runtime-evaluator-env-lookup scope-env name)
                                  (if lastp
                                      continuation
                                      (cons (runtime-evaluator-frame
                                             :do-step scope rest-forms mode)
                                            continuation)))))))
                    ((typep inner 'expr-defvalue)
                     (let ((after
                             (if lastp
                                 (if (eq mode :module)
                                     (cons (runtime-evaluator-frame
                                            :do-step scope nil mode)
                                           continuation)
                                     continuation)
                                 (cons (runtime-evaluator-frame
                                        :do-step scope rest-forms mode)
                                       continuation))))
                       (setf tasks
                             (runtime-evaluator-schedule-eval
                              tasks (expr-defvalue-expression inner) scope-env
                              (cons (runtime-evaluator-frame
                                     :do-activate scope
                                     (expr-defvalue-name inner)
                                     mode)
                                    after)))))
                    ((typep inner 'expr-load)
                     (setf tasks
                           (runtime-evaluator-schedule-eval
                            tasks expression scope-env
                            (cons (runtime-evaluator-frame :force)
                                  (cons (runtime-evaluator-frame
                                         :load scope rest-forms mode lastp)
                                        continuation)))))
                    ((typep inner 'expr-import)
                     (setf tasks
                           (runtime-evaluator-schedule-eval
                            tasks (expr-import-expression inner) scope-env
                            (cons (runtime-evaluator-frame :force)
                                  (cons (runtime-evaluator-frame
                                         :do-import scope rest-forms lastp mode)
                                        continuation)))))
                    ((typep inner 'expr-loadmodule)
                     (setf tasks
                           (runtime-evaluator-schedule-eval
                            tasks inner scope-env
                            (cons (runtime-evaluator-frame
                                   :do-import scope rest-forms lastp mode)
                                  continuation))))
                    (t
                     (setf tasks
                           (runtime-evaluator-schedule-eval
                            tasks expression scope-env
                            (cons (runtime-evaluator-frame :force)
                                  (cons (runtime-evaluator-frame
                                         :do-result scope rest-forms lastp mode)
                                        continuation))))))
                   )
             )
             )
             )
          (otherwise
           (runtime-evaluator-error
            (format nil "unknown evaluator task ~A" kind)
            "evaluator.machine"))
             )
      (let* ((scope (and (fboundp 'runtime-dynamic-current)
                         (runtime-dynamic-current nil)))
             (live-capabilities
               (and scope
                    (fboundp 'runtime-dynamic-capabilities)
                    (runtime-dynamic-capabilities)))
             ;; Preserve a live outer extent on normal nested return; errors
             ;; restore the machine's entry ambient.
             (capabilities
               (if (and finished
                        live-capabilities
                        (not (equal live-capabilities saved-capabilities)))
                   (copy-list live-capabilities)
                   saved-capabilities)))
         state capabilities saved-handlers saved-configs saved-location
         saved-location-stack))
    ))
    result))

(defun runtime-evaluator-reraise-error (state condition)
  (let* ((condition-range
           (and (typep condition 'language-error)
                (language-error-range condition)))
         (range (or condition-range
                    (runtime-evaluator-state-last-error-location state)
                    (runtime-evaluator-state-current-location state))))
    (if (and range (typep condition 'language-error))
        (let ((prefix (source-range-format range))
              (message (language-error-message condition)))
          (if (and (>= (length message) (length prefix))
                   (string= prefix message :end2 (length prefix)))
              (error condition)
              (error 'language-error
                     :code (language-error-code condition)
                     :message (format nil "~A: ~A" prefix message)
                     :range range)))
        (error condition))))
(defun runtime-evaluator-run-expression (state expression environment)
  (runtime-evaluator-run
   state (list (make-runtime-evaluator-task
                :eval (list expression environment nil)))))

(defun runtime-evaluator-eval (state expression &key environment (expand t))
  "Evaluate one Core_model expression with a fresh deterministic step budget.
ENVIRONMENT defaults to the evaluator's initial environment."
  (check-type state runtime-evaluator-state)
  (setf (runtime-evaluator-state-steps state) 0
        (runtime-evaluator-state-depth state) 0
        (runtime-evaluator-state-current-location state) nil
        (runtime-evaluator-state-last-error-location state) nil
        (runtime-evaluator-state-last-error-location-depth state) 0
        (runtime-evaluator-state-location-stack state) nil)
  (handler-case
      (runtime-evaluator-run-expression
       state (if expand (runtime-evaluator-expand-expression state expression)
                 expression)
       (or environment (runtime-evaluator-state-initial-env state)))
    (language-error (condition)
      (runtime-evaluator-reraise-error state condition))
    (error (condition)
      (let ((wrapped
              (handler-case
                  (runtime-evaluator-error (format nil "~A" condition)
                                           "evaluator.host")
                (language-error (error-condition) error-condition))))
        (runtime-evaluator-reraise-error state wrapped)))))

(defun runtime-evaluator-eval-expressions (state expressions &key environment)
  "Expand and evaluate a top-level sequence, registering defmacro forms first."
  (check-type state runtime-evaluator-state)
  (setf (runtime-evaluator-state-steps state) 0
        (runtime-evaluator-state-depth state) 0
        (runtime-evaluator-state-current-location state) nil
        (runtime-evaluator-state-last-error-location state) nil
        (runtime-evaluator-state-last-error-location-depth state) 0
        (runtime-evaluator-state-location-stack state) nil)
  (handler-case
      (let ((expanded (runtime-evaluator-expand-toplevel state expressions)))
        (runtime-evaluator-run
         state (list (make-runtime-evaluator-task
                      :eval (list (make-edo expanded)
                                  (or environment
                                      (runtime-evaluator-state-initial-env state))
                                  nil)))))
    (language-error (condition)
      (runtime-evaluator-reraise-error state condition))
    (error (condition)
      (let ((wrapped
              (handler-case
                  (runtime-evaluator-error (format nil "~A" condition)
                                           "evaluator.host")
                (language-error (error-condition) error-condition))))
        (runtime-evaluator-reraise-error state wrapped)))))

(defun make-runtime-evaluator (&rest arguments)
  "Construct an explicit evaluator state.  Callback keyword arguments are
intentionally the only host/runtime seams; absent effect and loader callbacks
fail with normalized language errors."
  (apply #'runtime-evaluator-default-state arguments))

;; Compatibility names for the later session/app owner.  They remain narrow
;; aliases and do not introduce a second evaluator.
(setf (symbol-function 'eval-expression) #'runtime-evaluator-eval)
(setf (symbol-function 'eval-expressions) #'runtime-evaluator-eval-expressions)
(setf (symbol-function 'force-value) #'runtime-evaluator-force)
(setf (symbol-function 'force-deep-value) #'runtime-evaluator-force-deep)
(setf (symbol-function 'apply-value) #'runtime-evaluator-apply-value)
