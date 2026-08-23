;;;; Explicit evaluator state and machine records.
(in-package #:pp.runtime)

(defstruct (runtime-evaluator-state
            (:constructor %make-runtime-evaluator-state))
  catalog
  initial-env
  macro-state
  (max-steps 1000000 :type integer)
  (max-depth 10000 :type integer)
  (steps 0 :type integer)
  (depth 0 :type integer)
  (force-stack nil)
  (force-count 0 :type integer)
  (persistent-cache (make-hash-table :test #'equal))
  (capabilities nil)
  (config-stack nil)
  (handler-stack nil)
  (current-location nil)
  (last-error-location nil)
  (last-error-location-depth 0 :type integer)
  (location-stack nil)
  perform-function
  with-capabilities-function
  with-handlers-function
  with-config-function
  load-function
  load-module-function
  island-function
  node-force-function)

(defstruct (runtime-evaluator-frame (:constructor make-runtime-evaluator-frame (kind data)))
  kind data)

(defstruct (runtime-evaluator-task (:constructor make-runtime-evaluator-task (kind data)))
  kind data)

(defstruct (runtime-definition-scope (:constructor make-runtime-definition-scope
                                                    (environment base-bindings names
                                                     value-thunks)))
  environment
  base-bindings
  names
  value-thunks)

(defun runtime-evaluator-reset-catalog! (catalog)
  "Reset per-evaluation deterministic counters owned by CATALOG.

The language layer installs this accessor when it owns a stateful primitive
counter.  Keeping the call conditional lets older catalogs remain usable while
giving session boundaries one stable hook."
  (when (and catalog
             (fboundp 'runtime-primitive-catalog-gensym-counter))
    (setf (runtime-primitive-catalog-gensym-counter catalog) 0))
  catalog)

(defun runtime-evaluator-reset-boundary! (state)
  "Reset all expression-local evaluator state at a session boundary."
  (check-type state runtime-evaluator-state)
  (setf (runtime-evaluator-state-steps state) 0
        (runtime-evaluator-state-depth state) 0
        (runtime-evaluator-state-force-stack state) nil
        (runtime-evaluator-state-force-count state) 0
        (runtime-evaluator-state-config-stack state) nil
        (runtime-evaluator-state-current-location state) nil
        (runtime-evaluator-state-last-error-location state) nil
        (runtime-evaluator-state-last-error-location-depth state) 0
        (runtime-evaluator-state-location-stack state) nil)
  (runtime-evaluator-reset-catalog!
   (runtime-evaluator-state-catalog state))
  state)

(defun runtime-evaluator-default-state
  (&key catalog initial-env
        (max-steps 1000000)
        (max-depth 10000)
        macro-state
        capabilities
        perform-function
        with-capabilities-function
        with-handlers-function
        with-config-function
        load-function
        load-module-function
        island-function
        node-force-function)
  (let* ((catalog (or catalog (runtime-install-pure-primitives)))
         (initial-env (or initial-env (runtime-primitive-initial-env catalog))))
    (unless (and (integerp max-steps) (plusp max-steps))
      (language-fail "evaluator max-steps must be positive" "evaluator.config"))
    (unless (and (integerp max-depth) (plusp max-depth))
      (language-fail "evaluator max-depth must be positive" "evaluator.config"))
    (%make-runtime-evaluator-state
     :catalog catalog :initial-env initial-env
     :macro-state (or macro-state (make-runtime-macro-state))
     :max-steps max-steps :max-depth max-depth
     :capabilities (copy-list capabilities)
     :perform-function perform-function
     :with-capabilities-function with-capabilities-function
     :with-handlers-function with-handlers-function
     :with-config-function with-config-function
     :load-function load-function
     :load-module-function load-module-function
     :island-function island-function
     :node-force-function node-force-function)))


(defun runtime-evaluator-step! (state)
  (incf (runtime-evaluator-state-steps state))
  (when (> (runtime-evaluator-state-steps state)
           (runtime-evaluator-state-max-steps state))
    (language-fail "evaluation exceeded the deterministic step limit"
                   "evaluator.depth")))

(defun runtime-evaluator-depth-enter! (state)
  (incf (runtime-evaluator-state-depth state))
  (when (> (runtime-evaluator-state-depth state)
           (runtime-evaluator-state-max-depth state))
    (decf (runtime-evaluator-state-depth state))
    (language-fail "evaluation exceeded the deterministic depth limit"
                   "evaluator.depth")))

(defun runtime-evaluator-depth-leave! (state)
  (when (plusp (runtime-evaluator-state-depth state))
    (decf (runtime-evaluator-state-depth state))))

(defun runtime-evaluator-hash-value (value)
  "Hash an environment value without letting malformed thunk capture
  analysis escape as a host condition.

The kernel's capture walker currently assumes every delayed expression child
is a sequence.  Runtime environments still need a deterministic hash for
those thunks, so use their code/environment boundary when that narrow kernel
hash path rejects the value."
  (handler-case
      (hash-value value)
    (error (condition)
      (if (typep value 'value-thunk)
          (let* ((thunk (value-thunk-thunk value))
                 (expression (thunk-expression thunk))
                 (type-ann (thunk-type-ann thunk)))
            (declare (ignore condition))
            (hash-concat
             (list "runtime-thunk"
                   (hash-expr expression)
                   (env-env-hash (thunk-environment thunk))
                   (if type-ann (hash-expr type-ann) "untyped"))))
          (error condition)))))

(defun runtime-evaluator-env-lookup (environment name)
  (let ((entry (find name (env-bindings environment) :key #'car :test #'string=)))
    (and entry (cdr entry))))

(defun runtime-evaluator-env-extend (environment name value)
  (make-env (cons (cons name value) (env-bindings environment))
            :env-id (1+ (env-env-id environment))
            :env-hash (hash-concat (list "env" (env-env-hash environment)
                                         name (runtime-evaluator-hash-value value)))))

(defun runtime-evaluator-env-extend-many (environment names values)
  (unless (= (length names) (length values))
    (language-fail "environment extension arity mismatch" "evaluator.environment"))
  (loop with result = environment
        for name in names
        for value in values
        do (setf result (runtime-evaluator-env-extend result name value))
        finally (return result)))

(defun runtime-evaluator-reset-thunk! (thunk)
  "Return THUNK to its retryable state after a failed force.

Typed thunks are deliberately not poisoned by a failed type check: a later
force must retry the RHS, while the enclosing located expression continues to
own the diagnostic range."
  (setf (thunk-status thunk) (make-thunk-status-unevaluated))
  thunk)

 (defun runtime-evaluator-make-thunk (expression environment
                                      &key name type-ann location
                                        (kind :ephemeral))
  ;; CORE-MODEL's convenience constructor treats an omitted CONFIG-HASH as
  ;; NIL; evaluator thunks always carry the canonical empty hash until a
  ;; runtime scope supplies one.
  (make-thunk expression environment :name name :type-ann type-ann
              :location location :config-hash "" :kind kind))

(defun runtime-evaluator-unwrapped-expression (expression)
  (if (typep expression 'expr-located)
      (runtime-evaluator-unwrapped-expression (expr-located-expression expression))
      expression))

(defun runtime-evaluator-definition-info (expression)
  (let ((expression (runtime-evaluator-unwrapped-expression expression)))
    (cond
      ((typep expression 'expr-def)
       (list (expr-def-name expression) (expr-def-params expression)
             (expr-def-body expression) :function))
      ((typep expression 'expr-defnode)
       (list (expr-defnode-name expression) (expr-defnode-params expression)
             (expr-defnode-body expression) :node))
      ((typep expression 'expr-defvalue)
       (list (expr-defvalue-name expression) nil
             (expr-defvalue-expression expression) :value))
      (t nil))))

 (defun runtime-evaluator-make-scope (state environment expressions)
  "Prebind block definitions, matching OCaml's definition scope.
The returned scope is mutable only as the block advances; all user values remain
kernel records and no host symbol table is involved."
  (declare (ignore state))
  (let ((scope-env environment)
        (base-bindings (env-bindings environment))
        (names nil)
        (closures nil)
        (thunks nil)
        (value-thunks nil))
    ;; Allocate every placeholder/closure before evaluating any right-hand
    ;; side.  This gives all mutually recursive definitions the same scope.
    (dolist (expression expressions)
      (let ((info (runtime-evaluator-definition-info expression)))
        (when info
          (destructuring-bind (name params body kind) info
            (push name names)
            (if (eq kind :value)
                (let ((thunk (runtime-evaluator-make-thunk body scope-env
                                                           :name name)))
                  (push thunk thunks)
                  (push (cons name thunk) value-thunks)
                  (setf scope-env
                        (runtime-evaluator-env-extend
                         scope-env name (make-vthunk thunk))))
                (let ((closure (make-vclosure
                                (make-closure params body scope-env
                                              :fn-name name
                                              :closure-kind kind))))
                  (push closure closures)
                  (setf scope-env
                        (runtime-evaluator-env-extend scope-env name closure))))))))
    ;; Every definition closes over the final prebound environment, not the
    ;; transient environment at construction.
    (dolist (closure closures)
      (setf (closure-env (value-closure-closure closure)) scope-env))
    (dolist (thunk thunks)
      (setf (thunk-environment thunk) scope-env))
    (make-runtime-definition-scope scope-env base-bindings (nreverse names)
                                   (nreverse value-thunks))))

(defun runtime-evaluator-scope-activate-value (scope name value)
  ;; Existing closures retain the prebound environment.  Marking its poison
  ;; thunk evaluated is therefore as important as adding the current binding:
  ;; recursive references must observe the memoized RHS, not evaluate it again.
  (let ((poison (assoc name (runtime-definition-scope-value-thunks scope)
                       :test #'string=)))
    (when poison
      (setf (thunk-status (cdr poison))
            (make-thunk-status-evaluated value))))
  (setf (runtime-definition-scope-environment scope)
        (runtime-evaluator-env-extend
         (runtime-definition-scope-environment scope) name value))
  (runtime-definition-scope-environment scope))

 (defun runtime-evaluator-scope-merge (scope bindings)
  (dolist (entry bindings)
    (runtime-evaluator-scope-activate-value scope (car entry) (cdr entry)))
  (runtime-definition-scope-environment scope))

 (defun runtime-evaluator-scope-export (scope)
  (let ((base (runtime-definition-scope-base-bindings scope))
        (seen (make-hash-table :test #'equal))
        (out nil))
    (dolist (entry (env-bindings (runtime-definition-scope-environment scope)))
      (unless (or (find (car entry) base :key #'car :test #'string=)
                  (gethash (car entry) seen))
        (setf (gethash (car entry) seen) t)
        (push entry out)))
    (make-venvmap (nreverse out))))
