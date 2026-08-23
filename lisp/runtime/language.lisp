;;;; Pure language operations.
;;;; This file contains no source reader, host EVAL/READ/INTERN, evaluator
;;;; loop, session state, or host effects. The evaluator supplies callbacks.

(in-package #:pp.runtime)

;;; ---------------------------------------------------------------------------
;;; Language errors and small structural helpers

(define-condition language-error (error)
  ((code :initarg :code :reader language-error-code :initform "language.error")
   (message :initarg :message :reader language-error-message :initform "language error")
   ;; Keep the originating source range on the normalized condition.  Runtime
   ;; owners may add the range when they unwrap a located expression; macro
   ;; expansion also uses it when relaying a nested language failure.
   (range :initarg :range :reader language-error-range :initform nil))
  (:report (lambda (condition stream)
            (write-string (language-error-message condition) stream))))

(defun language-fail (message &optional (code "language.error") range)
  (error 'language-error :code code :message message :range range))
(define-condition language-exit (error)
  ((status :initarg :status :reader language-exit-status)))

(defun language-exit (status)
  (error 'language-exit :status status))

(export '(language-exit language-exit-status) (find-package '#:pp.runtime))
(export 'language-error-range (find-package '#:pp.runtime))
 
;;; The evaluator's macro table is explicit state, but primitive callbacks
;;; intentionally remain small.  Expansion entry points publish the state of
;;; the active evaluator run here so eval-pp can continue that same table
;;; without manufacturing a fresh (and invisible) macro scope.  The context
;;; is keyed by the evaluator state rather than held in one process-global
;;; "current source" slot: nested evaluator runs therefore cannot inherit the
;;; caller's source location accidentally.
(defstruct (runtime-macro-context
            (:constructor make-runtime-macro-context (root &optional location)))
  root location)

(defvar *runtime-macro-contexts* nil)

(defun runtime-macro-context-for-state (state)
  (cdr (assoc state *runtime-macro-contexts* :test #'eq)))

(defun runtime-publish-macro-context (services state &optional location)
  (let ((initial-env
          (handler-case
              (funcall (runtime-macro-services-initial-env services))
            (error () nil))))
    (let ((entry (assoc state *runtime-macro-contexts* :test #'eq)))
      ;; The first publication comes from the evaluator's own expansion
      ;; boundary and records its root environment.  eval-pp republishes
      ;; while using a nested caller environment; do not move the root to
      ;; that nested scope or later outer calls would lose the macro table.
      (if entry
          (when location
            (setf (runtime-macro-context-location (cdr entry)) location))
          (push (cons state (make-runtime-macro-context initial-env location))
                *runtime-macro-contexts*))))
  state)

(defun runtime-macro-env-descends-from-p (environment root)
  (or (eq environment root)
      (and root
           (let ((root-bindings (env-bindings root)))
             (and root-bindings
                  (loop for tail = (env-bindings environment)
                          then (cdr tail)
                        while tail
                        thereis (eq tail root-bindings)))))))

(defun runtime-macro-state-for-env (environment)
  (loop for (state . context) in *runtime-macro-contexts*
        when (runtime-macro-env-descends-from-p
              environment (runtime-macro-context-root context))
          do (return state)))

(defun runtime-macro-location-for-env (environment)
  (let ((state (runtime-macro-state-for-env environment)))
    (and state
         (runtime-macro-context-location
          (runtime-macro-context-for-state state)))))

(defun runtime-macro-location-for-state (state)
  (let ((context (runtime-macro-context-for-state state)))
    (and context (runtime-macro-context-location context))))

(defun runtime-eval-pp-source (text location)
  "Prefix TEXT with the caller's source origin for frontend ranges.

The frontend deliberately starts every parse at line one.  Whitespace-only
prefixing preserves the source while making diagnostics and located forms
report the caller's path, line, and column rather than the synthetic `<?>:1`
origin."
  (if (null location)
      text
      (let ((start (source-range-start location)))
        (concatenate
         'string
         (make-string (max 0 (1- (position-line start)))
                      :initial-element #\Newline)
         (make-string (max 0 (1- (position-column start)))
                      :initial-element #\Space)
         text))))

(defun proper-value-list (value)
  "Return VALUE as a host list when it is a proper pp list, else NIL.
NIL is also the representation of the empty pp list; callers that need to
 distinguish failure from an empty list must use PROPER-VALUE-LIST-P first."
  (labels ((walk (v out)
             (typecase v
               (value-nil (nreverse out))
               (value-pair (walk (value-pair-cdr v)
                                 (cons (value-pair-car v) out)))
               (t nil))))
    (walk value nil)))

(defun proper-value-list-p (value)
  (or (typep value 'value-nil)
      (labels ((walk (v)
                 (typecase v
                   (value-nil t)
                   (value-pair (walk (value-pair-cdr v)))
                   (t nil))))
        (walk value))))

(defun value-list (items)
  (if (null items)
      (make-vnil)
 
      (make-vpair (first items) (value-list (rest items)))))

(defun pair-values (value)
  (let ((items (proper-value-list value)))
    (unless (or items (typep value 'value-nil))
      (language-fail "expected a proper list" "language.list"))
    (or items nil)))

(defun runtime-force (value force)
  (if force (funcall force value) value))

(defun runtime-force-deep (value force-deep force)
  (cond (force-deep (funcall force-deep value))
        (force (funcall force value))
        (t value)))

(defun runtime-force-all (values force)
  (mapcar (lambda (value) (runtime-force value force)) values))

;;; ---------------------------------------------------------------------------
;;; Free variables (the node-key boundary's exact symbol analysis)

(defun runtime-name-member-p (name names)
  (member name names :test #'string=))

(defun runtime-name-union (&rest lists)
  (let ((out nil))
    (dolist (list lists (nreverse out))
      (dolist (name list)
        (unless (runtime-name-member-p name out)
          (push name out))))))

(defun runtime-name-minus (names bound)
  (remove-if (lambda (name) (runtime-name-member-p name bound)) names))

(defun runtime-pattern-bound-names (pattern)
  (typecase pattern
    (pattern-variable (list (pattern-variable-name pattern)))
    (pattern-list
     (apply #'runtime-name-union
            (append (mapcar #'runtime-pattern-bound-names
                            (pattern-list-patterns pattern))
                    (if (pattern-list-rest pattern)
                        (list (runtime-pattern-bound-names
                               (pattern-list-rest pattern)))
                        nil))))
    (pattern-tagged
     (apply #'runtime-name-union
            (mapcar #'runtime-pattern-bound-names
                    (pattern-tagged-patterns pattern))))
    (t nil)))

(defun runtime-free-variable-names (expression)
  "Return sorted free pp names.  The result is a fresh list of strings."
  (labels ((block-binders (forms)
             (remove nil
                     (mapcar (lambda (form)
                               (typecase form
                                 (expr-def (expr-def-name form))
                                 (expr-defnode (expr-defnode-name form))
                                 (expr-defvalue (expr-defvalue-name form))
                                 (expr-located
                                  (block-binders
                                   (list (expr-located-expression form))))
                                 (t nil)))
                             forms)))
           (fv (bound e)
             (typecase e
               ((or expr-literal expr-quote expr-load expr-loadmodule expr-island)
                nil)
               (expr-symbol
                (if (runtime-name-member-p (expr-symbol-name e) bound)
                    nil
                    (list (expr-symbol-name e))))
               (expr-if
                (runtime-name-union
                 (fv bound (expr-if-condition e))
                 (fv bound (expr-if-then e))
                 (fv bound (expr-if-else e))))
               (expr-let
                (let* ((bindings (expr-let-bindings e))
                       (names (mapcar #'car bindings))
                       (bound2 (runtime-name-union bound names)))
                  (apply #'runtime-name-union
                         (append (list (fv bound2 (expr-let-body e)))
                                 (mapcar (lambda (binding)
                                           (fv bound2 (cdr binding)))
                                         bindings)))))
               (expr-letstar
                (labels ((walk (bindings current-bound)
                           (if (null bindings)
                               (fv current-bound (expr-letstar-body e))
                               (runtime-name-union
                                (fv current-bound (cdar bindings))
                                (walk (cdr bindings)
                                      (cons (caar bindings) current-bound))))))
                  (walk (expr-letstar-bindings e) bound)))
               (expr-fn
                (fv (runtime-name-union bound (expr-fn-params e))
                    (expr-fn-body e)))
               (expr-apply
                ;; needs-value is an internal closure marker and is not an
                ;; input dependency; it must not leak into a node key.
                (if (and (typep (expr-apply-function e) 'expr-symbol)
                         (string= (expr-symbol-name (expr-apply-function e))
                                  (format nil "~Cneeds-value" (code-char 0))))
                    nil
                    (apply #'runtime-name-union
                           (cons (fv bound (expr-apply-function e))
                                 (mapcar (lambda (x) (fv bound x))
                                         (expr-apply-arguments e))))))
               (expr-force (fv bound (expr-force-expression e)))
               (expr-with-caps
                (runtime-name-union
                 (fv bound (expr-with-caps-caps e))
                 (fv bound (expr-with-caps-body e))))
               (expr-perform
                (apply #'runtime-name-union
                       (mapcar (lambda (x) (fv bound x))
                               (expr-perform-arguments e))))
               (expr-with-handler
                (apply #'runtime-name-union
                       (cons (fv bound (expr-with-handler-body e))
                             (mapcar (lambda (handler)
                                       (fv bound (cdr handler)))
                                     (expr-with-handler-handlers e)))))
               ((or expr-delay expr-node)
                (fv bound (if (typep e 'expr-delay)
                              (expr-delay-expression e)
                              (expr-node-expression e))))
               ((or expr-def expr-defnode)
                (let ((name (if (typep e 'expr-def)
                                (expr-def-name e)
                                (expr-defnode-name e)))
                      (params (if (typep e 'expr-def)
                                  (expr-def-params e)
                                  (expr-defnode-params e)))
                      (body (if (typep e 'expr-def)
                                (expr-def-body e)
                                (expr-defnode-body e))))
                  (fv (runtime-name-union bound (list name) params) body)))
               (expr-defvalue (fv bound (expr-defvalue-expression e)))
               ((or expr-do expr-module)
                (let* ((forms (if (typep e 'expr-do)
                                  (expr-do-expressions e)
                                  (expr-module-expressions e)))
                       (bound2 (runtime-name-union bound
                                                    (block-binders forms))))
                  (apply #'runtime-name-union
                         (mapcar (lambda (x) (fv bound2 x)) forms))))
               (expr-import (fv bound (expr-import-expression e)))
               (expr-with-config
                (runtime-name-union
                 (fv bound (expr-with-config-map-expression e))
                 (fv bound (expr-with-config-body e))))
               (expr-config
                (runtime-name-union
                 (fv bound (expr-config-key-expression e))
                 (if (expr-config-default e)
                     (fv bound (expr-config-default e))
                     nil)))
               (expr-typed (fv bound (expr-typed-expression e)))
               (expr-located (fv bound (expr-located-expression e)))
               (expr-match
                (runtime-name-union
                 (fv bound (expr-match-scrutinee e))
                 (apply #'runtime-name-union
                        (mapcar (lambda (arm)
                                  (destructuring-bind (pattern guard body) arm
                                    (let ((arm-bound
                                            (runtime-name-union
                                             bound
                                             (runtime-pattern-bound-names
                                              pattern))))
                                      (runtime-name-union
                                       (if guard (fv arm-bound guard) nil)
                                       (fv arm-bound body)))))
                                (expr-match-arms e)))))
               (t (language-fail "unknown expression structure"
                                 "language.expression")))))
    (sort (copy-list (fv nil expression)) #'string<)))

;;; ---------------------------------------------------------------------------
;;; Quotation and reification

(defun runtime-quote-pattern (pattern)
  (typecase pattern
    (pattern-literal
     (value-list (list (make-vsymbol "lit")
                       (pattern-literal-value pattern))))
    (pattern-variable
     (value-list (list (make-vsymbol "var")
                       (make-vstring (pattern-variable-name pattern)))))
    (pattern-wildcard (make-vsymbol "_"))
    (pattern-list
     (value-list
      (list (make-vsymbol "list")
            (value-list (mapcar #'runtime-quote-pattern
                                (pattern-list-patterns pattern)))
            (if (pattern-list-rest pattern)
                (runtime-quote-pattern (pattern-list-rest pattern))
                (make-vnil)))))
    (pattern-tagged
     (value-list
      (cons (make-vsymbol "tagged")
            (cons (make-vstring (pattern-tagged-tag pattern))
                  (mapcar #'runtime-quote-pattern
                          (pattern-tagged-patterns pattern))))))
    (t (language-fail "unknown pattern structure" "language.pattern"))))

(defun runtime-quote-to-value (expression)
  (typecase expression
    (expr-literal (expr-literal-value expression))
    (expr-symbol (make-vsymbol (expr-symbol-name expression)))
    (expr-if (value-list (list (make-vsymbol "if")
                               (runtime-quote-to-value (expr-if-condition expression))
                               (runtime-quote-to-value (expr-if-then expression))
                               (runtime-quote-to-value (expr-if-else expression)))))
    (expr-let
     (value-list
      (list (make-vsymbol "let")
            (value-list
             (mapcar (lambda (binding)
                       (value-list (list (make-vsymbol (car binding))
                                         (runtime-quote-to-value (cdr binding)))))
                     (expr-let-bindings expression)))
            (runtime-quote-to-value (expr-let-body expression)))))
    (expr-fn
     (value-list (list (make-vsymbol "fn")
                       (make-vvector-from-list
                        (mapcar #'make-vsymbol (expr-fn-params expression)))
                       (runtime-quote-to-value (expr-fn-body expression)))))
    (expr-apply
     (value-list (cons (runtime-quote-to-value (expr-apply-function expression))
                       (mapcar #'runtime-quote-to-value
                               (expr-apply-arguments expression)))))
    (expr-quote (value-list (list (make-vsymbol "quote")
                                  (runtime-quote-to-value
                                   (expr-quote-expression expression)))))
    (expr-force (value-list (list (make-vsymbol "force")
                                  (runtime-quote-to-value
                                   (expr-force-expression expression)))))
    (expr-delay (value-list (list (make-vsymbol "delay")
                                  (runtime-quote-to-value
                                   (expr-delay-expression expression)))))
    (expr-node (value-list (list (make-vsymbol "node")
                                 (runtime-quote-to-value
                                  (expr-node-expression expression)))))
    ((or expr-def expr-defnode)
     (let ((name (if (typep expression 'expr-def)
                     (expr-def-name expression)
                     (expr-defnode-name expression)))
           (params (if (typep expression 'expr-def)
                       (expr-def-params expression)
                       (expr-defnode-params expression)))
           (body (if (typep expression 'expr-def)
                     (expr-def-body expression)
                     (expr-defnode-body expression))))
       (value-list
        (list (make-vsymbol (if (typep expression 'expr-def) "def" "defnode"))
              (make-vsymbol name)
              (value-list (mapcar #'make-vsymbol params))
              (runtime-quote-to-value body)))))
    (expr-defvalue
     (value-list (list (make-vsymbol "def")
                       (make-vsymbol (expr-defvalue-name expression))
                       (runtime-quote-to-value
                        (expr-defvalue-expression expression)))))
    (expr-letstar
     (value-list
      (list (make-vsymbol "let*")
            (value-list
             (mapcar (lambda (binding)
                       (value-list (list (make-vsymbol (car binding))
                                         (runtime-quote-to-value (cdr binding)))))
                     (expr-letstar-bindings expression)))
            (runtime-quote-to-value (expr-letstar-body expression)))))
    (expr-do
     (value-list (cons (make-vsymbol "do")
                       (mapcar #'runtime-quote-to-value
                               (expr-do-expressions expression)))))
    (expr-with-caps
     (value-list (list (make-vsymbol "with-caps")
                       (runtime-quote-to-value (expr-with-caps-caps expression))
                       (runtime-quote-to-value (expr-with-caps-body expression)))))
    (expr-perform
     (value-list (cons (make-vsymbol "perform")
                       (cons (make-vsymbol (expr-perform-name expression))
                             (mapcar #'runtime-quote-to-value
                                     (expr-perform-arguments expression))))))
    (expr-with-handler
     (value-list
      (list (make-vsymbol "with-handler")
            (value-list
             (mapcar (lambda (handler)
                       (value-list (list (make-vsymbol (car handler))
                                         (runtime-quote-to-value (cdr handler)))))
                     (expr-with-handler-handlers expression)))
            (runtime-quote-to-value (expr-with-handler-body expression)))))
    (expr-module
     (value-list (cons (make-vsymbol "module")
                       (mapcar #'runtime-quote-to-value
                               (expr-module-expressions expression)))))
    (expr-import (value-list (list (make-vsymbol "import")
                                   (runtime-quote-to-value
                                    (expr-import-expression expression)))))
    (expr-load (value-list (list (make-vsymbol "load")
                                 (make-vstring (expr-load-path expression)))))
    (expr-loadmodule (value-list (list (make-vsymbol "load-module")
                                       (make-vstring
                                        (expr-loadmodule-path expression)))))
    (expr-island
     (value-list (list (make-vsymbol "island")
                       (make-vstring (expr-island-uri expression))
                       (if (expr-island-pin expression)
                           (make-vstring (expr-island-pin expression))
                           (make-vnil)))))
    (expr-with-config
     (value-list (list (make-vsymbol "with-config")
                       (runtime-quote-to-value
                        (expr-with-config-map-expression expression))
                       (runtime-quote-to-value (expr-with-config-body expression)))))
    (expr-config
     (value-list (list (make-vsymbol "config")
                       (runtime-quote-to-value
                        (expr-config-key-expression expression))
                       (if (expr-config-default expression)
                           (runtime-quote-to-value (expr-config-default expression))
                           (make-vnil)))))
    (expr-typed
     (value-list (list (make-vsymbol ":")
                       (runtime-quote-to-value (expr-typed-expression expression))
                       (runtime-quote-to-value (expr-typed-type expression)))))
    (expr-located (runtime-quote-to-value (expr-located-expression expression)))
    (expr-match
     (value-list
      (list (make-vsymbol "match")
            (runtime-quote-to-value (expr-match-scrutinee expression))
            (value-list
             (mapcar (lambda (arm)
                       (destructuring-bind (pattern guard body) arm
                         (value-list
                          (if guard
                              (list (runtime-quote-pattern pattern)
                                    (runtime-quote-to-value guard)
                                    (runtime-quote-to-value body))
                              (list (runtime-quote-pattern pattern)
                                    (runtime-quote-to-value body))))))
                     (expr-match-arms expression))))))
    (t (language-fail "unknown expression structure" "language.expression"))))
(defun runtime-symbol-name (value)
  (typecase value
    (value-symbol (value-symbol-value value))
    (value-keyword (value-keyword-value value))
    (t (language-fail "expected a symbol in quoted syntax" "language.quote"))))

(defun runtime-parameter-name (value)
  "Decode a function/definition parameter; keywords are data, not binders."
  (typecase value
    (value-symbol (value-symbol-value value))
    (t (language-fail "expected a symbol in quoted syntax"
                      "language.quote"))))

(defun runtime-symbol-list (value)
  (let ((items (pair-values value)))
    (mapcar #'runtime-parameter-name items)))


(declaim (ftype function runtime-value-to-expr runtime-expr-of-list
                runtime-value-to-pattern))

(defun runtime-binding-pairs (value)
  (if (typep value 'value-vector)
      (let ((items (coerce (value-vector-values value) 'list)))
        (when (oddp (length items))
          (language-fail "odd element in binding vector" "language.quote"))
        (loop for (name expression) on items by #'cddr
              collect (cons (runtime-symbol-name name)
                            (runtime-value-to-expr expression))))
      (mapcar (lambda (item)
                (let ((parts (pair-values item)))
                  (unless (= (length parts) 2)
                    (language-fail "malformed binding pair" "language.quote"))
                  (cons (runtime-symbol-name (first parts))
                        (runtime-value-to-expr (second parts)))))
              (pair-values value))))

(defun runtime-value-to-expr (value)
  (typecase value
    ((or value-nil value-bool value-int value-float value-string value-keyword)
     (make-eliteral value))
    (value-symbol (make-esymbol (value-symbol-value value)))
    (value-vector
     (make-eapply (make-esymbol "vector")
                  (map 'list #'runtime-value-to-expr
                       (value-vector-values value))))
    (value-map
     (make-eapply
      (make-esymbol "hash-map")
      (mapcan (lambda (entry)
                (list (runtime-value-to-expr (car entry))
                      (runtime-value-to-expr (cdr entry))))
              (canonical-map-entries (value-map-entries value)))))
    (value-set
     (make-eapply (make-esymbol "hash-set")
                  (mapcar #'runtime-value-to-expr
                          (canonical-set-elements (value-set-values value)))))
    (value-pair
     (let ((items (pair-values value)))
       (unless (and items (not (typep value 'value-nil)))
         (language-fail "cannot convert an improper list to syntax"
                        "language.quote"))
       (runtime-expr-of-list items)))
    ((or value-closure value-builtin value-capability value-thunk
         value-env-map value-sealed)
     (language-fail
      (typecase value
        (value-closure "cannot convert a closure to syntax")
        (value-builtin "cannot convert a builtin to syntax")
        (value-capability "cannot convert a capability to syntax")
        (value-thunk "cannot convert an unevaluated thunk to syntax")
        (value-env-map "cannot convert a module to syntax")
        (t "cannot convert a sealed value to syntax"))
      "language.quote"))
    (t (language-fail "unknown value structure" "language.quote"))))

(defun runtime-expr-of-list (items)
  (let ((head (and (typep (first items) 'value-symbol)
                   (value-symbol-value (first items)))))
    (cond
      ((and (string= head "if") (= (length items) 4))
       (make-eif (runtime-value-to-expr (second items))
                 (runtime-value-to-expr (third items))
                 (runtime-value-to-expr (fourth items))))
      ((and (string= head "let") (= (length items) 3))
       (make-elet (runtime-binding-pairs (second items))
                  (runtime-value-to-expr (third items))))
      ((and (string= head "let*") (= (length items) 3))
       (make-eletstar (runtime-binding-pairs (second items))
                      (runtime-value-to-expr (third items))))
      ((and (string= head "fn") (= (length items) 3)
            (typep (second items) 'value-vector))
       (make-efn (mapcar #'runtime-parameter-name
                         (coerce (value-vector-values (second items)) 'list))
                 (runtime-value-to-expr (third items))))
      ((and (string= head "quote") (= (length items) 2))
       (make-equote (runtime-value-to-expr (second items))))
      ((and (string= head "force") (= (length items) 2))
       (make-eforce (runtime-value-to-expr (second items))))
      ((and (string= head "delay") (= (length items) 2))
       (make-edelay (runtime-value-to-expr (second items))))
      ((and (string= head "node") (= (length items) 2))
       (make-enode (runtime-value-to-expr (second items))))
      ((and (string= head "defnode") (= (length items) 4)
            (typep (second items) 'value-symbol))
       (make-edefnode (value-symbol-value (second items))
                      (runtime-symbol-list (third items))
                      (runtime-value-to-expr (fourth items))))
      ((and (string= head "def") (= (length items) 4)
            (typep (second items) 'value-symbol))
       (make-edef (value-symbol-value (second items))
                  (runtime-symbol-list (third items))
                  (runtime-value-to-expr (fourth items))))
      ((and (string= head "def") (= (length items) 3)
            (typep (second items) 'value-symbol))
       (make-edefvalue (value-symbol-value (second items))
                       (runtime-value-to-expr (third items))))
      ((and (member head '("def" "defnode") :test #'string=)
            (= (length items) 3))
       (let ((parts (pair-values (second items))))
         (unless parts (language-fail "malformed definition form" "language.quote"))
         (if (string= head "def")
             (make-edef (runtime-symbol-name (first parts))
                        (mapcar #'runtime-parameter-name (rest parts))
                        (runtime-value-to-expr (third items)))
             (make-edefnode (runtime-symbol-name (first parts))
                            (mapcar #'runtime-parameter-name (rest parts))
                            (runtime-value-to-expr (third items))))))
      ((and (string= head "with-caps") (= (length items) 3))
       (make-ewith-caps (runtime-value-to-expr (second items))
                        (runtime-value-to-expr (third items))))
      ((and (string= head "perform") (>= (length items) 2))
       (make-eperform (runtime-symbol-name (second items))
                      (mapcar #'runtime-value-to-expr (cddr items))))
      ((and (string= head "with-handler") (= (length items) 3))
       (make-ewith-handler (runtime-binding-pairs (second items))
                           (runtime-value-to-expr (third items))))
      ((and (string= head "module") (>= (length items) 1))
       (make-emodule (mapcar #'runtime-value-to-expr (rest items))))
      ((and (string= head "import") (= (length items) 2))
       (make-eimport (runtime-value-to-expr (second items))))
      ((and (string= head "load") (= (length items) 2)
            (typep (second items) 'value-string))
       (make-eload (value-string-value (second items))))
      ((and (string= head "load-module") (= (length items) 2)
            (typep (second items) 'value-string))
       (make-eloadmodule (value-string-value (second items))))
      ((and (string= head "island") (= (length items) 3)
            (typep (second items) 'value-string))
       (make-eisland (value-string-value (second items))
                     (typecase (third items)
                       (value-nil nil)
                       (value-string (value-string-value (third items)))
                       (t (language-fail "island pin must be a string"
                                         "language.quote")))))
      ((and (string= head "with-config") (= (length items) 3))
       (make-ewith-config (runtime-value-to-expr (second items))
                          (runtime-value-to-expr (third items))))
      ((and (string= head "config") (= (length items) 3))
       (make-econfig (runtime-value-to-expr (second items))
                     (runtime-value-to-expr (third items))))
      ((and (string= head ":") (= (length items) 3))
       (make-typed (runtime-value-to-expr (second items))
                   (runtime-value-to-expr (third items))))
      ((and (string= head "do") (>= (length items) 1))
       (make-edo (mapcar #'runtime-value-to-expr (rest items))))
      ((and (string= head "match") (= (length items) 3))
       (let ((arms (pair-values (third items))))
         (make-ematch
          (runtime-value-to-expr (second items))
          (mapcar (lambda (arm)
                    (let ((parts (pair-values arm)))
                      (cond
                        ((= (length parts) 2)
                         (list (runtime-value-to-pattern (first parts))
                               nil
                               (runtime-value-to-expr (second parts))))
                        ((= (length parts) 3)
                         (list (runtime-value-to-pattern (first parts))
                               (runtime-value-to-expr (second parts))
                               (runtime-value-to-expr (third parts))))
                        (t (language-fail "malformed match arm"
                                          "language.quote")))))
                  arms))))
      (t (make-eapply (runtime-value-to-expr (first items))
                      (mapcar #'runtime-value-to-expr (rest items)))))))

(defun runtime-value-to-pattern (value)
  (let ((head (and (typep value 'value-pair)
                   (proper-value-list value))))
    (cond
      ((and (typep value 'value-symbol)
            (string= (value-symbol-value value) "_"))
       (make-pwildcard))
      ((and head (= (length head) 2)
            (typep (first head) 'value-symbol)
            (string= (value-symbol-value (first head)) "lit"))
       (make-pliteral (second head)))
      ((and head (= (length head) 2)
            (typep (first head) 'value-symbol)
            (string= (value-symbol-value (first head)) "var")
            (typep (second head) 'value-string))
       (make-pvariable (value-string-value (second head))))
      ((and head (= (length head) 3)
            (typep (first head) 'value-symbol)
            (string= (value-symbol-value (first head)) "list"))
       (make-plist (mapcar #'runtime-value-to-pattern (pair-values (second head)))
                   (unless (typep (third head) 'value-nil)
                     (runtime-value-to-pattern (third head)))))
      ((and head (>= (length head) 2)
            (typep (first head) 'value-symbol)
            (string= (value-symbol-value (first head)) "tagged")
            (typep (second head) 'value-string))
       (make-ptagged (value-string-value (second head))
                     (mapcar #'runtime-value-to-pattern (cddr head))))
      (t (language-fail "value cannot be converted to a pattern"
                        "language.pattern")))))
(defun runtime-pp-value-equal (left right)
  "Pattern literals use direct value equality, not content hashes.
In particular NaN is unequal to itself while signed zeroes compare equal."
  (cond
    ((and (typep left 'value-float) (typep right 'value-float))
     (and (not (canonical-float-nan-p (value-float-value left)))
          (not (canonical-float-nan-p (value-float-value right)))
          (= (value-float-value left) (value-float-value right))))
    ((and (typep left 'value-pair) (typep right 'value-pair))
     (and (runtime-pp-value-equal (value-pair-car left)
                                  (value-pair-car right))
          (runtime-pp-value-equal (value-pair-cdr left)
                                  (value-pair-cdr right))))
    ((and (typep left 'value-vector) (typep right 'value-vector))
     (let ((a (value-vector-values left))
           (b (value-vector-values right)))
       (and (= (length a) (length b))
            (loop for i below (length a)
                  always (runtime-pp-value-equal (aref a i) (aref b i))))))
    ((and (typep left 'value-map) (typep right 'value-map))
     (let ((a (canonical-map-entries (value-map-entries left)))
           (b (canonical-map-entries (value-map-entries right))))
       (and (= (length a) (length b))
            (every (lambda (entries)
                     (and (runtime-pp-value-equal (caar entries) (caadr entries))
                          (runtime-pp-value-equal (cdar entries) (cdadr entries))))
                   (mapcar #'list a b)))))
    ((and (typep left 'value-set) (typep right 'value-set))
     (let ((a (canonical-set-elements (value-set-values left)))
           (b (canonical-set-elements (value-set-values right))))
       (and (= (length a) (length b))
            (every (lambda (pair)
                     (runtime-pp-value-equal (first pair) (second pair)))
                   (mapcar #'list a b)))))
    ((and (typep left 'value-nil) (typep right 'value-nil)) t)
    ((and (typep left 'value-bool) (typep right 'value-bool))
     (eql (value-bool-value left) (value-bool-value right)))
    ((and (typep left 'value-int) (typep right 'value-int))
     (= (value-int-value left) (value-int-value right)))
    ((and (typep left 'value-string) (typep right 'value-string))
     (string= (value-string-value left) (value-string-value right)))
    ((and (typep left 'value-keyword) (typep right 'value-keyword))
     (string= (value-keyword-value left) (value-keyword-value right)))
    ((and (typep left 'value-symbol) (typep right 'value-symbol))
     (string= (value-symbol-value left) (value-symbol-value right)))
    (t (and (typep left (type-of right))
            (equal-value left right)))))

(defun runtime-match-pattern (value pattern &key (equal #'runtime-pp-value-equal))
  "Return (VALUES BINDINGS MATCHED-P).  BINDINGS is ordered left-to-right."
  (labels ((match-list (v patterns rest-pattern bindings)
             (cond
               ((null patterns)
                (if rest-pattern
                    (match* v rest-pattern bindings)
                    (if (typep v 'value-nil)
                        (values bindings t)
                        (values nil nil))))
               ((typep v 'value-pair)
                (multiple-value-bind (tail-bindings matchedp)
                    (match* (value-pair-car v) (first patterns) bindings)
                  (if matchedp
                      (match-list (value-pair-cdr v) (rest patterns)
                                  rest-pattern tail-bindings)
                      (values nil nil))))
               (t (values nil nil))))
           (match* (v p bindings)
             (typecase p
               (pattern-wildcard (values bindings t))
               (pattern-variable
                (values (append bindings
                                 (list (cons (pattern-variable-name p) v))) t))
               (pattern-literal
                (if (funcall equal v (pattern-literal-value p))
                    (values bindings t)
                    (values nil nil)))
               (pattern-list
                (match-list v (pattern-list-patterns p)
                            (pattern-list-rest p) bindings))
               (pattern-tagged
                (if (and (typep v 'value-pair)
                         (typep (value-pair-car v) 'value-keyword)
                         (string= (value-keyword-value (value-pair-car v))
                                  (pattern-tagged-tag p)))
                    (labels ((walk (tail pats bs)
                               (cond
                                 ((null pats) (values bs t))
                                 ((typep tail 'value-pair)
                                  (multiple-value-bind (bs2 ok)
                                      (match* (value-pair-car tail)
                                              (first pats) bs)
                                    (if ok
                                        (walk (value-pair-cdr tail)
                                              (rest pats) bs2)
                                        (values nil nil))))
                                 ;; Tagged values may carry extra fields.
                                 ;; Preserve those fields' matching behavior.
                                 (t (values nil nil)))))
                      (walk (value-pair-cdr v)
                            (pattern-tagged-patterns p) bindings))
                    (values nil nil)))
               (t (values nil nil)))))
    (match* value pattern nil)))

(defun runtime-pattern-match-p (value pattern)
  (nth-value 1 (runtime-match-pattern value pattern)))

(defun runtime-escape-string (string)
  (with-output-to-string (out)
    (loop for ch across string
          do (case ch
               (#\\ (write-string "\\\\" out))
               (#\" (write-string "\\\"" out))
               (#\Newline (write-string "\\n" out))
               (#\Return (write-string "\\r" out))
               (#\Tab (write-string "\\t" out))
               (#\Backspace (write-string "\\b" out))
               (#\Page (write-string "\\f" out))
               (t (if (< (char-code ch) 32)
                      (format out "\\~3,'0D" (char-code ch))
                      (write-char ch out)))))))

(defun runtime-float-presentation (number)
  "Render floats with pp spellings, never host D exponents."
  (let ((number (coerce number 'double-float)))
    (cond
      ((canonical-float-nan-p number) "nan")
      ((string= (canonical-float-string number) "inf") "inf")
      ((string= (canonical-float-string number) "-inf") "-inf")
      ((zerop number)
       (if (minusp (float-sign number)) "-0." "0."))
      (t
       (let* ((text (string-trim '(#\Space #\Tab)
                                 (substitute #\e #\d
                                             (substitute #\e #\D
                                                         (format nil "~,12G" number)))))
              (epos (cl:position #\e text)))
         (labels ((trim-mantissa (mantissa &optional ensure-dot)
                    (let ((dot (cl:position #\. mantissa)))
                      (if dot
                          (let ((end (length mantissa)))
                            (loop while (and (> end (1+ dot))
                                             (char= (char mantissa (1- end)) #\0))
                                  do (decf end))
                            (if (= end (1+ dot))
                                (if ensure-dot
                                    (subseq mantissa 0 (1+ dot))
                                    (subseq mantissa 0 dot))
                                (subseq mantissa 0 end)))
                          (if ensure-dot
                              (concatenate 'string mantissa ".")
                              mantissa))))
                  (normalize-exp (exp-text)
                    (let* ((exp (parse-integer exp-text))
                           (sign (if (minusp exp) "-" "+"))
                           (digits (format nil "~2,'0D" (abs exp))))
                      (concatenate 'string "e" sign digits))))
           (if epos
               (concatenate 'string
                            (trim-mantissa (subseq text 0 epos))
                            (normalize-exp (subseq text (1+ epos))))
               (trim-mantissa text t))))))))

(defun runtime-string-of-value (value)
  (typecase value
    (value-nil "nil")
    (value-bool (if (value-bool-value value) "true" "false"))
    (value-int (canonical-integer-string (value-int-value value)))
    (value-float
     (if (canonical-float-nan-p (value-float-value value))
         "nan"
         (runtime-float-presentation (value-float-value value))))
    (value-string (concatenate 'string "\""
                               (runtime-escape-string (value-string-value value))
                               "\""))
    (value-keyword (concatenate 'string ":" (value-keyword-value value)))
    (value-symbol (value-symbol-value value))
    (value-pair
     (labels ((walk (v)
                (typecase v
                  (value-pair
                   (concatenate 'string
                                (runtime-string-of-value (value-pair-car v))
                                (if (typep (value-pair-cdr v) 'value-nil)
                                    ""
                                    (concatenate 'string " "
                                                 (walk (value-pair-cdr v))))))
                  (value-nil "")
                  (t (concatenate 'string ". " (runtime-string-of-value v))))))
       (concatenate 'string "(" (walk value) ")")))
    (value-vector
     (format nil "[~{~A~^ ~}]"
             (map 'list #'runtime-string-of-value (value-vector-values value))))
    (value-map
     (format nil "{~{~A~^, ~}}"
             (mapcar (lambda (entry)
                       (format nil "~A ~A"
                               (runtime-string-of-value (car entry))
                               (runtime-string-of-value (cdr entry))))
                     (canonical-map-entries (value-map-entries value)))))
    (value-set
     (format nil "#{~{~A~^ ~}}"
             (mapcar #'runtime-string-of-value
                     (canonical-set-elements (value-set-values value)))))
    (value-closure
     (if (closure-fn-name (value-closure-closure value))
         (format nil "#<fn ~A>" (closure-fn-name (value-closure-closure value)))
         "#<fn>"))
    (value-builtin (format nil "#<builtin ~A>" (value-builtin-name value)))
    (value-capability (capability-to-string
                       (value-capability-capability value)))
    (value-thunk
     (let ((status (thunk-status (value-thunk-thunk value))))
       (typecase status
         (thunk-status-unevaluated "#<thunk>")
         (thunk-status-evaluating "#<thunk: evaluating>")
         (thunk-status-evaluated
          (format nil "#<thunk: ~A>"
                  (runtime-string-of-value
                   (thunk-status-evaluated-value status))))
         (t "#<thunk>"))))
    (value-env-map (format nil "#<envmap ~D exports>"
                           (length (value-env-map-bindings value))))
    (value-sealed "#<sealed>")
    (t (language-fail "unknown value structure" "language.presentation"))))

(defun runtime-string-like (value)
  (typecase value
    ((or value-string value-keyword value-symbol)
     (typecase value
       (value-string (value-string-value value))
       (value-keyword (value-keyword-value value))
       (t (value-symbol-value value))))
    (t nil)))
(defun runtime-utf8-slice-to-string (bytes)
  "Decode a byte slice from a pp string, rejecting malformed UTF-8."
  (with-output-to-string (out)
    (labels ((continuation-p (byte)
               (and (<= #x80 byte) (<= byte #xbf)))
             (fail ()
               (language-fail "string operation produced invalid UTF-8"
                              "primitive.string"))
             (next (index)
               (let ((first (aref bytes index)))
                 (cond
                   ((<= first #x7f)
                    (values (code-char first) (1+ index)))
                   ((and (<= #xc2 first #xdf)
                         (< (1+ index) (length bytes))
                         (continuation-p (aref bytes (1+ index))))
                    (values (code-char
                             (+ (ash (logand first #x1f) 6)
                                (logand (aref bytes (1+ index)) #x3f)))
                            (+ index 2)))
                   ((and (<= #xe0 first #xef)
                         (< (+ index 2) (length bytes))
                         (continuation-p (aref bytes (1+ index)))
                         (continuation-p (aref bytes (+ index 2)))
                         (or (not (= first #xe0))
                             (>= (aref bytes (1+ index)) #xa0))
                         (or (not (= first #xed))
                             (< (aref bytes (1+ index)) #xa0)))
                    (values
                     (code-char (+ (ash (logand first #x0f) 12)
                                   (ash (logand (aref bytes (1+ index)) #x3f) 6)
                                   (logand (aref bytes (+ index 2)) #x3f)))
                     (+ index 3)))
                   ((and (<= #xf0 first #xf4)
                         (< (+ index 3) (length bytes))
                         (continuation-p (aref bytes (1+ index)))
                         (continuation-p (aref bytes (+ index 2)))
                         (continuation-p (aref bytes (+ index 3)))
                         (or (not (= first #xf0))
                             (>= (aref bytes (1+ index)) #x90))
                         (or (not (= first #xf4))
                             (< (aref bytes (1+ index)) #x90)))
                    (values
                     (code-char (+ (ash (logand first #x07) 18)
                                   (ash (logand (aref bytes (1+ index)) #x3f) 12)
                                   (ash (logand (aref bytes (+ index 2)) #x3f) 6)
                                   (logand (aref bytes (+ index 3)) #x3f)))
                     (+ index 4)))
                   (t (fail))))))
      (loop with index = 0
            while (< index (length bytes))
            do (multiple-value-bind (character next-index) (next index)
                 (write-char character out)
                 (setf index next-index))))))

;;; ---------------------------------------------------------------------------
;;; Primitive catalog (declarations are mutable only during construction)

(defstruct (runtime-primitive-shape
            (:constructor make-runtime-primitive-shape (kind minimum maximum)))
  kind minimum maximum)

(defun runtime-shape-any ()
  (make-runtime-primitive-shape :any nil nil))
(defun runtime-shape-exact (count)
  (make-runtime-primitive-shape :exact count count))
(defun runtime-shape-range (minimum &optional maximum)
  (make-runtime-primitive-shape :range minimum maximum))

(defstruct (runtime-primitive-descriptor
            (:constructor make-runtime-primitive-descriptor
                (name shape category implementation)))
  name shape category implementation)

(defstruct (runtime-primitive-catalog
            (:constructor %make-runtime-primitive-catalog))
  (declarations nil) (entries nil) (aliases nil)
  (builtins (make-hash-table :test #'equal))
  (finalized-p nil) (gensym-counter 0))

(defun make-runtime-primitive-catalog ()
  (%make-runtime-primitive-catalog))
(defun runtime-primitive-reset-gensym (catalog)
  "Reset the catalog-local gensym sequence at an evaluation boundary."
  (unless (typep catalog 'runtime-primitive-catalog)
    (language-fail "a primitive catalog is required" "primitive.catalog"))
  (setf (runtime-primitive-catalog-gensym-counter catalog) 0)
  catalog)

(defun runtime-primitive-register (catalog name implementation
                                   &key shape category)
  (when (runtime-primitive-catalog-finalized-p catalog)
    (language-fail
     (format nil "cannot register primitive '~A' after finalization" name)
     "primitive.catalog"))
  (push (make-runtime-primitive-descriptor
         name (or shape (runtime-shape-any)) (or category :other)
         implementation)
        (runtime-primitive-catalog-declarations catalog))
  catalog)

(defun runtime-primitive-alias (catalog alias target)
  (when (runtime-primitive-catalog-finalized-p catalog)
    (language-fail "cannot add an alias after finalization" "primitive.catalog"))
  (push (cons alias target) (runtime-primitive-catalog-aliases catalog))
  catalog)

(defun runtime-primitive-finalize (catalog)
  (unless (runtime-primitive-catalog-finalized-p catalog)
    (setf (runtime-primitive-catalog-entries catalog)
          (nreverse (runtime-primitive-catalog-declarations catalog)))
    (dolist (descriptor (runtime-primitive-catalog-entries catalog))
      (setf (gethash (runtime-primitive-descriptor-name descriptor)
                     (runtime-primitive-catalog-builtins catalog))
            (make-vbuiltin (runtime-primitive-descriptor-name descriptor)
                           (runtime-primitive-descriptor-implementation descriptor))))
    (dolist (alias (runtime-primitive-catalog-aliases catalog))
      (let ((target (gethash (cdr alias)
                             (runtime-primitive-catalog-builtins catalog))))
        (unless target
          (language-fail (format nil "primitive alias target is not registered: ~A"
                                 (cdr alias))
                         "primitive.catalog"))
        (setf (gethash (car alias) (runtime-primitive-catalog-builtins catalog))
              target)))
    (setf (runtime-primitive-catalog-finalized-p catalog) t))
  catalog)

(defun runtime-primitive-lookup (catalog name)
  (gethash name (runtime-primitive-catalog-builtins catalog)))

(defun runtime-primitive-initial-env (catalog)
  (make-env
   (sort (loop for name being the hash-keys of
                         (runtime-primitive-catalog-builtins catalog)
               using (hash-value value)
               collect (cons name value))
         #'string< :key #'car)))

(defun runtime-primitive-shape-string (shape)
  (case (runtime-primitive-shape-kind shape)
    (:any "any")
    (:exact (format nil "~D" (runtime-primitive-shape-minimum shape)))
    (:range (if (runtime-primitive-shape-maximum shape)
                (format nil "~D..~D"
                        (runtime-primitive-shape-minimum shape)
                        (runtime-primitive-shape-maximum shape))
                (format nil "~D+" (runtime-primitive-shape-minimum shape))))))

(defun runtime-primitive-render (catalog)
  (with-output-to-string (out)
    (format out "| builtin | arity | category |~%|---|---|---|~%")
    (dolist (descriptor (runtime-primitive-catalog-entries catalog))
      (unless (find (code-char 0) (runtime-primitive-descriptor-name descriptor))
        (format out "| `~A` | ~A | ~A |~%"
                (runtime-primitive-descriptor-name descriptor)
                (runtime-primitive-shape-string
                 (runtime-primitive-descriptor-shape descriptor))
                (string-downcase
                 (string (runtime-primitive-descriptor-category descriptor))))))))

 (defun runtime-primitive-call (builtin args env
                                 &key force force-deep apply eval eager)
   (unless (typep builtin 'value-builtin)
     (language-fail (format nil "not a builtin: ~A" (runtime-string-of-value builtin))
                    "primitive.call"))
   (let ((implementation (value-builtin-implementation builtin))
         (force (or force #'identity))
         (force-deep (or force-deep force #'identity)))
     ;; Keep the callback shape compatible with standalone pure callers that
     ;; do not accept unknown keyword arguments.
     (if (or eval eager)
         (funcall implementation args env
                  :force force :force-deep force-deep :apply apply
                  :eval eval :eager eager)
         (funcall implementation args env
                  :force force :force-deep force-deep :apply apply))))

(defun runtime-primitive-arity-error (name expected actual)
  (language-fail (format nil "~A expects ~A argument~:P, got ~D"
                         name expected actual)
                 "primitive.arity"))

(defun runtime-number (value name)
  (typecase value
    ((or value-int value-float) value)
    (t (language-fail (format nil "~A expects numbers, got ~A"
                              name (runtime-string-of-value value))
                      "primitive.type"))))

(defun runtime-int-result (n)
  (handler-case (make-vint n)
    (error () (language-fail (format nil "integer result out of range: ~D" n)
                             "primitive.range"))))

(defun runtime-float-infinity-sign (number)
  (let ((text (canonical-float-string number)))
    (cond ((string= text "inf") 1)
          ((string= text "-inf") -1)
          (t nil))))

(defun runtime-special-float (sign)
  (make-vfloat
   (decode-hex-float (if (plusp sign) "inf" "-inf"))))

(defun runtime-float-special-result (operation left right)
  "Return a canonical result for IEEE cases that SBCL may trap."
  (let* ((left-nan (canonical-float-nan-p left))
         (right-nan (canonical-float-nan-p right))
         (left-sign (and (not left-nan)
                         (runtime-float-infinity-sign left)))
         (right-sign (and (not right-nan)
                          (runtime-float-infinity-sign right))))
    (cond
      ((or left-nan right-nan)
       (values t (make-vfloat (decode-hex-float "nan"))))
      ((or left-sign right-sign)
       (case operation
         (:add
          (cond ((and left-sign right-sign)
                 (if (= left-sign right-sign)
                     (values t (runtime-special-float left-sign))
                     (values t (make-vfloat (decode-hex-float "nan")))))
                (left-sign (values t (runtime-special-float left-sign)))
                (t (values t (runtime-special-float right-sign)))))
         (:sub
          (cond ((and left-sign right-sign)
                 (if (= left-sign right-sign)
                     (values t (make-vfloat (decode-hex-float "nan")))
                     (values t (runtime-special-float left-sign))))
                (left-sign (values t (runtime-special-float left-sign)))
                (t (values t (runtime-special-float (- right-sign))))))
         (:mul
          (let ((zero (or (and left-sign (zerop right))
                          (and right-sign (zerop left)))))
            (if zero
                (values t (make-vfloat (decode-hex-float "nan")))
                (values t
                        (runtime-special-float
                         (* (or left-sign (runtime-number-sign left))
                            (or right-sign (runtime-number-sign right))))))))
         (:div
          (cond
            ((and left-sign right-sign)
             (values t (make-vfloat (decode-hex-float "nan"))))
            (left-sign
             (values t
                     (runtime-special-float
                      (* left-sign (runtime-number-sign right)))))
            (right-sign
             (values t
                     (make-vfloat
                      (if (minusp (* (runtime-number-sign left) right-sign))
                          (- 0.0d0)
                          0.0d0))))))
         (otherwise (values nil nil))))
      (t (values nil nil)))))

(defun runtime-number-sign (number)
  (if (minusp (float-sign number)) -1 1))

(defun runtime-float-overflow-sign (operation left right)
  (case operation
    (:add (and (= (runtime-number-sign left) (runtime-number-sign right))
               (runtime-number-sign left)))
    (:sub (and (/= (runtime-number-sign left) (runtime-number-sign right))
               (runtime-number-sign left)))
    (:mul (* (runtime-number-sign left) (runtime-number-sign right)))
    (:div (* (runtime-number-sign left) (runtime-number-sign right)))))

(defun runtime-float-binary (operation left right function)
  (multiple-value-bind (handled result)
      (runtime-float-special-result operation left right)
    (if handled
        result
        (handler-case
            (make-vfloat (funcall function left right))
          (arithmetic-error ()
            (let ((sign (runtime-float-overflow-sign operation left right)))
              (if sign
                  (runtime-special-float sign)
                  (make-vfloat (decode-hex-float "nan")))))))))

(defun runtime-numeric-fold (name args identity int-op float-op force operation)
  (let ((values (runtime-force-all args force)))
    (if (null values)
        (runtime-int-result identity)
        (progn
          (runtime-number (first values) name)
          (reduce
         (lambda (left right)
           (runtime-number right name)
           (typecase left
             (value-int
              (typecase right
                (value-int
                 (runtime-int-result
                  (funcall int-op (value-int-value left)
                           (value-int-value right))))
                (value-float
(runtime-float-binary
                 operation
                 (float (value-int-value left) 1.0d0)
                 (value-float-value right)
                 float-op))))
             (value-float
(runtime-float-binary
               operation
               (value-float-value left)
               (if (typep right 'value-int)
                   (float (value-int-value right) 1.0d0)
                   (value-float-value right))
               float-op))))
         (rest values)
         :initial-value (first values)
           :from-end nil)))))

(defun runtime-numeric-compare (name args int-cmp float-cmp force)
  (let ((values (runtime-force-all args force)))
    (if (or (null values) (null (rest values)))
        (make-vbool t)
        (make-vbool
         (loop for left in values
               for right in (rest values)
               always (progn
                        (runtime-number left name)
                        (runtime-number right name)
                        (if (and (typep left 'value-int)
                                 (typep right 'value-int))
                            (funcall int-cmp (value-int-value left)
                                     (value-int-value right))
                            (funcall float-cmp
                                     (if (typep left 'value-int)
                                         (float (value-int-value left) 1.0d0)
                                         (value-float-value left))
                                     (if (typep right 'value-int)
                                         (float (value-int-value right) 1.0d0)
                                         (value-float-value right))))))))))

(defun runtime-number-p (value)
  (or (typep value 'value-int) (typep value 'value-float)))

(defun runtime-digit-value (character)
  (let ((code (char-code character)))
    (cond ((<= (char-code #\0) code (char-code #\9)) (- code (char-code #\0)))
          (t nil))))

(defun runtime-parse-number-string (string)
  "Parse pp decimal numbers without host READ; exponent presence controls type."
  (check-type string string)
  (let ((lower (string-downcase string)))
    (cond
      ((string= lower "nan") (make-vfloat (decode-hex-float "nan")))
      ((string= lower "inf") (make-vfloat (decode-hex-float "inf")))
      ((string= lower "-inf") (make-vfloat (decode-hex-float "-inf")))
      (t
       (let* ((length (length string))
              (index 0)
              (negative nil))
         (when (and (< index length)
                    (member (char string index) '(#\+ #\-) :test #'char=))
           (setf negative (char= (char string index) #\-))
           (incf index))
         (let ((whole 0) (fraction 0) (fraction-digits 0)
               (saw-mantissa-digit nil) (saw-dot nil)
               (exponent 0) (exponent-negative nil) (exponent-present nil))
           (loop while (< index length)
                 for digit = (runtime-digit-value (char string index))
                 while digit
                 do (setf saw-mantissa-digit t
                          whole (+ (* whole 10) digit))
                    (incf index))
           (when (and (< index length) (char= (char string index) #\.))
             (setf saw-dot t)
             (incf index)
             (loop while (< index length)
                   for digit = (runtime-digit-value (char string index))
                   while digit
                   do (setf saw-mantissa-digit t
                            fraction (+ (* fraction 10) digit))
                      (incf fraction-digits)
                      (incf index)))
           (unless saw-mantissa-digit
             (return-from runtime-parse-number-string nil))
           (when (and (< index length)
                      (member (char string index) '(#\e #\E) :test #'char=))
             (setf exponent-present t)
             (incf index)
             (when (and (< index length)
                        (member (char string index) '(#\+ #\-) :test #'char=))
               (setf exponent-negative (char= (char string index) #\-))
               (incf index))
             (let ((exp-digits 0) (exp-count 0))
               (loop while (< index length)
                     for digit = (runtime-digit-value (char string index))
                     while digit
                     do (incf exp-count)
                        (setf exp-digits (+ (* exp-digits 10) digit))
                        (incf index))
               (unless (plusp exp-count)
                 (return-from runtime-parse-number-string nil))
               (setf exponent (if exponent-negative (- exp-digits) exp-digits))))
           (unless (= index length)
             (return-from runtime-parse-number-string nil))
           (if (or saw-dot exponent-present)
               (make-vfloat
                (* (if negative -1.0d0 1.0d0)
                   (+ (float whole 1.0d0)
                      (/ (float fraction 1.0d0)
                         (expt 10.0d0 fraction-digits)))
                   (expt 10.0d0 exponent)))
               (runtime-int-result (if negative (- whole) whole)))))))))

(defun runtime-manifest-key-name (value)
  (typecase value
    ((or value-keyword value-string)
     (if (typep value 'value-keyword)
         (value-keyword-value value)
         (value-string-value value)))
    (t nil)))

(defun runtime-manifest-fields (value force)
  "Return VALUE's keyword/string fields, rejecting malformed or duplicate keys."
  (unless (typep value 'value-map)
    (language-fail "runtime manifest expects a map" "runtime.configuration"))
  (let ((seen nil) (fields nil))
    (dolist (entry (value-map-entries value) (nreverse fields))
      (let ((name (runtime-manifest-key-name (car entry))))
        (unless name
          (language-fail
           (format nil "runtime manifest keys must be keywords or strings, got ~A"
                   (runtime-string-of-value (car entry)))
           "runtime.configuration"))
        (when (member name seen :test #'string=)
          (language-fail
           (format nil "runtime manifest has duplicate field :~A" name)
           "runtime.configuration"))
        (push name seen)
        (push (cons name (funcall force (cdr entry))) fields)))))

(defun runtime-manifest-field (fields name)
  (cdr (assoc name fields :test #'string=)))

(defun runtime-manifest-positive-int (value field)
  (unless (and (typep value 'value-int) (plusp (value-int-value value)))
    (language-fail
     (format nil "runtime manifest :~A expects a positive integer, got ~A"
             field (if value (runtime-string-of-value value) "missing"))
     "runtime.configuration"))
  (value-int-value value))

(defun runtime-manifest-function-p (value)
  (or (typep value 'value-closure) (typep value 'value-builtin)))

(defun runtime-manifest-normalize (value force deep)
  "Validate a runtime manifest and return its canonical pp map plus schedule name.

Executable values are allowed only where the runtime protocol consumes them
(schedule policies and reporters).  Build and execution policies are data-only;
authority, closures, and delayed values fail closed."
  (let* ((raw-fields (runtime-manifest-fields value force))
         (allowed '("schedule" "reporter" "build-policy" "execution-policy"))
         (normalized nil)
         (schedule-name nil))
    (dolist (field raw-fields)
      (let* ((name (car field))
             (raw (cdr field))
             (field-value
               (if (member name '("build-policy" "execution-policy")
                           :test #'string=)
                   (funcall deep raw)
                   raw)))
        (unless (member name allowed :test #'string=)
          (language-fail (format nil "runtime manifest has unknown field :~A" name)
                         "runtime.configuration"))
        (when (member name '("build-policy" "execution-policy")
                      :test #'string=)
          (unless (and (fboundp 'runtime-configuration-value-durable-p)
                       (runtime-configuration-value-durable-p field-value))
            (language-fail
             (format nil "runtime manifest :~A must be canonical data" name)
             "runtime.authority")))
        (cond
          ((string= name "reporter")
           (unless (runtime-manifest-function-p field-value)
             (language-fail
              (format nil "runtime manifest :reporter expects a function, got ~A"
                      (runtime-string-of-value field-value))
              "runtime.configuration")))
          ((string= name "schedule")
           (let* ((schedule-fields (runtime-manifest-fields field-value force))
                  (kind (runtime-manifest-field schedule-fields "kind"))
                  (schedule-allowed
                    '("kind" "width" "policy" "redundancy")))
             (dolist (schedule-field schedule-fields)
               (unless (member (car schedule-field) schedule-allowed
                               :test #'string=)
                 (language-fail
                  (format nil "runtime manifest schedule has unknown field :~A"
                          (car schedule-field))
                  "runtime.configuration")))
             (unless (or (typep kind 'value-keyword)
                         (typep kind 'value-string))
               (language-fail
                "runtime manifest :schedule :kind expects a string or keyword"
                "runtime.configuration"))
             (let ((kind (runtime-string-like kind)))
               (setf schedule-name
                     (cond
                       ((string= kind "serial") "serial")
                       ((member kind '("parallel" "race") :test #'string=)
                        (format nil "~A:~D" kind
                                (runtime-manifest-positive-int
                                 (runtime-manifest-field schedule-fields "width")
                                 "width")))
                       ((string= kind "custom")
                        (let ((policy
                                (runtime-manifest-field schedule-fields "policy")))
                          (unless (runtime-manifest-function-p policy)
                            (language-fail
                             "custom schedule :policy expects a function"
                             "runtime.configuration"))
                          (when (runtime-manifest-field
                                 schedule-fields "redundancy")
                            (runtime-manifest-positive-int
                             (runtime-manifest-field schedule-fields "redundancy")
                             "redundancy"))
                          "custom"))
                       (t
                        (language-fail
                         (format nil "runtime manifest: unknown schedule kind ~A"
                                 kind)
                         "runtime.configuration"))))))))
        (push (cons (make-vkeyword name) field-value) normalized)))
    (values (make-vmap (canonical-map-entries (nreverse normalized)))
            schedule-name)))

 (defun runtime-install-pure-primitives (&optional (catalog (make-runtime-primitive-catalog)))
   "Populate CATALOG with deterministic, effect-free builtins and finalize it.
Implementations accept (ARGS ENV &key FORCE FORCE-DEEP APPLY EVAL EAGER).  APPLY
is supplied by the evaluator for apply/map; EAGER is the evaluator's immediate
callback path for metaprogramming calls.  No host evaluator is used as a
fallback."
  (labels ((register (name function &key shape (category :other))
             (runtime-primitive-register catalog name function
                                         :shape (or shape (runtime-shape-any))
                                         :category category))
           (force* (value force) (runtime-force value force))
           (deep* (value force-deep force)
             (runtime-force-deep value force-deep force))
           (args* (args force) (runtime-force-all args force))
           (apply* (fn args env apply)
             (unless apply
               (language-fail "application callback is required by this primitive"
                              "primitive.services"))
             (funcall apply fn args env))
           (eager* (fn args env eager apply)
             (cond (eager (funcall eager fn args env))
                   (apply (funcall apply fn args env))
                   (t (language-fail
                       "an eager application callback is required by this primitive"
                       "primitive.services"))))
           (primitive-env-extend (environment name value)
             ;; Keep eval-pp's local definitions in the same canonical
             ;; environment shape as ordinary evaluator definitions.  The
             ;; evaluator helper is available after this file loads; the
             ;; fallback keeps the language layer independently probeable.
             (if (fboundp 'runtime-evaluator-env-extend)
                 (funcall (symbol-function 'runtime-evaluator-env-extend)
                          environment name value)
                 (make-env
                  (cons (cons name value) (env-bindings environment))
                  :env-id (1+ (env-env-id environment))
                  :env-hash (hash-concat
                             (list "env" (env-env-hash environment)
                                   name (hash-value value))))))
           (eval-pp* (args env force force-deep eval)
             ;; Check the primitive's own arity before forcing any argument.
             ;; Besides avoiding unnecessary work, this keeps malformed calls
             ;; from leaking an evaluator/environment error while reporting
             ;; the pp primitive contract.
             (unless (= (length args) 1)
               (runtime-primitive-arity-error "eval-pp" 1 (length args)))
             (let ((values (args* args force)))
               (unless (typep (first values) 'value-string)
                 (language-fail "eval-pp expects a source string"
                                "primitive.type"))
               (unless eval
                 (language-fail "eval-pp requires an evaluation callback"
                                "primitive.services"))
               (let* ((location (runtime-macro-location-for-env env))
                      (source (and location (source-range-source location)))
                      (text (value-string-value (first values)))
                      (expressions
                        (handler-case
                            (read-source
                             (runtime-eval-pp-source text location)
                             :source (or source "<?>"))
                          (frontend-error (condition)
                            (language-fail
                             (frontend-error-message condition)
                             "primitive.read-string"
                             (frontend-error-range condition)))))
                      ;; The evaluator owns the macro table, while the
                      ;; primitive only receives its current environment and
                      ;; callbacks.  runtime-expand-* records the state that
                      ;; was used by the current evaluator run; use that state
                      ;; here rather than creating a fresh table (which would
                      ;; make a macro visible only to the enclosing form).
                      (macro-state (runtime-macro-state-for-env env))
                      (expanded
                        (if macro-state
                            (runtime-expand-toplevel
                             (make-runtime-macro-services
                              :eval eval
                              :force-deep force-deep
                              ;; Macro bodies are evaluated in the caller's
                              ;; environment, not the evaluator's initial
                              ;; environment.
                              :initial-env (lambda () env))
                             macro-state
                             expressions)
                            expressions))
                      (local-env env)
                      (definitions nil)
                      (last-value (make-vnil)))
                 (dolist (expression expanded)
                   (let ((inner (if (typep expression 'expr-located)
                                    (expr-located-expression expression)
                                    expression)))
                     (cond
                       ((typep inner 'expr-def)
                        (let ((value (funcall eval expression local-env)))
                          (setf local-env
                                (primitive-env-extend
                                 local-env (expr-def-name inner) value))
                          (push (cons (expr-def-name inner) value) definitions)))
                       ((typep inner 'expr-defvalue)
                        (let ((value (funcall eval expression local-env)))
                          (setf local-env
                                (primitive-env-extend
                                 local-env (expr-defvalue-name inner) value))
                          (push (cons (expr-defvalue-name inner) value)
                                definitions)))
                       (t
                        (setf last-value

                              (runtime-force-deep
                               (funcall eval expression local-env)
                               force-deep force))))))
                 (if definitions
                     (make-venvmap (nreverse definitions))
                     last-value))))
    (runtime-configure* (args force force-deep)
      (unless (= (length args) 1)
        (runtime-primitive-arity-error "configure-runtime" 1 (length args)))
      (runtime-dynamic-require-script-tier
       "configure-runtime: may not be called inside a node body (scripting-tier only)")
      (let ((session (runtime-dynamic-session nil)))
        (unless session
          (language-fail "configure-runtime requires a runtime session"
                         "runtime.session"))
        (multiple-value-bind (manifest schedule-name)
            (runtime-manifest-normalize
             (force* (first args) force) force
             (or force-deep force #'identity))
          (runtime-session-set-runtime-manifest session manifest)
          (let* ((fields (runtime-manifest-fields manifest #'identity))
                 (reporter (runtime-manifest-field fields "reporter")))
            (when reporter
              (runtime-session-register-reporter session reporter)))
          ;; A command-level schedule override owns the scheduler before the
          ;; script runs.  Otherwise make the selected handler observable; the
          ;; trusted host may consume the manifest later at the node boundary.
          (when (and schedule-name
                     (not (runtime-session-schedule-locked-p session)))
            (runtime-dynamic-record-event
             (make-vmap
              (canonical-map-entries
               (list (cons (make-vkeyword "kind")
                           (make-vkeyword "runtime-schedule"))
                     (cons (make-vkeyword "handler")
                           (make-vstring schedule-name)))))))
          (make-vnil))))
    (runtime-config-value (args)
      (unless (null args)
        (runtime-primitive-arity-error "runtime-config" 0 (length args)))
      (runtime-dynamic-require-script-tier
       "runtime-config: may not be called inside a node body (scripting-tier only)")
      (let ((session (runtime-dynamic-session nil)))
        (unless session
          (language-fail "runtime-config requires a runtime session"
                         "runtime.session"))
        (or (runtime-session-runtime-manifest session)
            (make-vmap nil))))
    (runtime-register-reporter (args force)
      (unless (= (length args) 1)
        (runtime-primitive-arity-error "register-reporter" 1 (length args)))
      (runtime-dynamic-require-script-tier
       "register-reporter: may not be called inside a node body (scripting-tier only)")
      (let ((reporter (force* (first args) force))
            (session (runtime-dynamic-session nil)))
        (unless session
          (language-fail "register-reporter requires a runtime session"
                         "runtime.session"))
        (unless (runtime-manifest-function-p reporter)
          (language-fail
           (format nil "register-reporter expects a function, got ~A"
                   (runtime-string-of-value reporter))
           "runtime.configuration"))
        (runtime-session-register-reporter session reporter)
        (make-vnil)))
    (runtime-emit-event (args force)
      (unless (= (length args) 1)
        (runtime-primitive-arity-error "emit-event" 1 (length args)))
      (runtime-dynamic-require-script-tier
       "emit-event: may not be called inside a node body (scripting-tier only)")
      (runtime-dynamic-record-event (force* (first args) force))
      (make-vnil))
    (argv-values (args force)
      (declare (ignore force))
      (unless (null args)
        (runtime-primitive-arity-error "argv" 0 (length args)))
      (labels ((text (value)
                 (cond ((stringp value) value)
                       ((typep value 'value-string)
                        (value-string-value value))
                       (t (language-fail
                           "argv observation returned a non-string argument"
                           "runtime.observation"))))
               (collect (value)
                 (cond
                   ((null value) nil)
                   ((typep value 'value-nil) nil)
                   ((stringp value) (list value))
                   ((typep value 'value-vector)
                    (map 'list #'text (value-vector-values value)))
                   ((typep value 'value-pair)
                    (mapcar #'text (pair-values value)))
                   ((listp value) (mapcar #'text value))
                   (t (language-fail
                       "argv observation returned an invalid argument vector"
                       "runtime.observation")))))
        (let* ((invocation (and (fboundp 'runtime-dynamic-invocation)
                                (runtime-dynamic-invocation nil)))
               (invocation-p (and (listp invocation)
                                  (member :argv invocation)))
               (invocation-service
                 (and invocation (fboundp 'runtime-observation-service)
                      (runtime-observation-service :invocation-argv)))
               (service (and (fboundp 'runtime-observation-service)
                             (runtime-observation-service :observe-argv)))
               (available (or invocation-p invocation-service service))
               (observed
                 (cond (invocation-p (getf invocation :argv))
                       (invocation-service
                        (funcall invocation-service invocation))
                       (service (funcall service))
                       (t nil))))
          (unless available
            (language-fail
             "argv requires an invocation observation service"
             "runtime.observation"))
          (let ((strings (collect observed)))
            (when (fboundp 'runtime-observation-record)
              (runtime-observation-record
               (make-cell-argv)
               (hash-concat (cons "argv" strings))))
            (value-list (mapcar #'make-vstring strings))))))
    (stat-kind (path operation)
      (let* ((canonical (canonicalize-path path :realpath #'identity))
             (canonical-string (canonical-path-to-string canonical))
             (capabilities
               (if (fboundp 'runtime-dynamic-capabilities)
                   (runtime-dynamic-capabilities)
                   nil)))
        (unless (some (lambda (capability)
                        (capability-check-fs-read-p capability canonical))
                      capabilities)
          (language-fail
           (format nil "~A: capability error: no read access for ~A"
                   operation canonical-string)
           "runtime.authority"))
        (let ((observed
                (and (fboundp 'runtime-observation-call)
                     (runtime-observation-call :observe-stat canonical-string))))
          (unless observed
            (language-fail
             (format nil "~A: stat observation service is unavailable" operation)
             "runtime.observation"))
          (let ((kind
                  (cond
                    ((stringp observed) observed)
                    ((and (consp observed) (stringp (car observed)))
                     (car observed))
                    ((and (consp observed) (keywordp (car observed)))
                     (string-downcase (symbol-name (car observed))))
                    (t nil))))
            (unless (member kind '("absent" "file" "dir") :test #'string=)
              (language-fail
               (format nil "~A: stat observation returned an invalid kind" operation)
               "runtime.observation"))
            (when (fboundp 'runtime-observation-record)
              (runtime-observation-record
               (make-cell-stat canonical-string)
               (hash-string (concatenate 'string "stat:" kind))))
            kind))))
    (exit-value (args force)
      (unless (member (length args) '(0 1))
        (runtime-primitive-arity-error "exit" "zero or one" (length args)))
      (let ((values (args* args force)))
        (if (null values)
            0
            (if (typep (first values) 'value-int)
                (value-int-value (first values))
                (language-fail "exit expects an optional integer status"
                               "primitive.type"))))))
    ;; Arithmetic and comparisons.
    (register "+" (lambda (args env &key force &allow-other-keys)
                     (declare (ignore env))
                     (runtime-numeric-fold "+" args 0 #'+ #'+ force :add))
              :shape (runtime-shape-range 0) :category :arithmetic)
    (register "*" (lambda (args env &key force &allow-other-keys)
                     (declare (ignore env))
                     (runtime-numeric-fold "*" args 1 #'* #'* force :mul))
              :shape (runtime-shape-range 0) :category :arithmetic)
    (register "-" (lambda (args env &key force &allow-other-keys)
                     (declare (ignore env))
                     (let ((values (args* args force)))
                       (unless (= (length values) 2)
                         (runtime-primitive-arity-error "-" 2 (length values)))
                       (let ((a (first values)) (b (second values)))
                         (cond
                           ((and (typep a 'value-int) (typep b 'value-int))
                            (runtime-int-result (- (value-int-value a)
                                                   (value-int-value b))))
                           ((and (typep a 'value-float) (typep b 'value-float))
                            (runtime-float-binary
                             :sub
                             (value-float-value a)
                             (value-float-value b)
                             #'-))
                           (t (language-fail
                               "- expects two integers or two floats"
                               "primitive.type"))))))
              :shape (runtime-shape-exact 2) :category :arithmetic)
    (register "/" (lambda (args env &key force &allow-other-keys)
                     (declare (ignore env))
                     (let ((values (args* args force)))
                       (unless (= (length values) 2)
                         (runtime-primitive-arity-error "/" 2 (length values)))
                       (let ((a (first values)) (b (second values)))
                         (when (or (and (typep b 'value-int)
                                        (zerop (value-int-value b)))
                                   (and (typep b 'value-float)
                                        (zerop (value-float-value b))))
                           (language-fail "/ expects a non-zero divisor"
                                          "primitive.arithmetic"))
                         (cond
                           ((and (typep a 'value-int) (typep b 'value-int))
                            (runtime-int-result (truncate (value-int-value a)
                                                           (value-int-value b))))
                           ((and (typep a 'value-float) (typep b 'value-float))
                            (runtime-float-binary
                             :div
                             (value-float-value a)
                             (value-float-value b)
                             #'/))
                           (t (language-fail
                               "/ expects two integers or two floats"
                               "primitive.type"))))))
              :shape (runtime-shape-exact 2) :category :arithmetic)
    (register "mod" (lambda (args env &key force &allow-other-keys)
                       (declare (ignore env))
                       (let ((values (args* args force)))
                         (unless (and (= (length values) 2)
                                      (every (lambda (x) (typep x 'value-int)) values))
                           (language-fail "mod expects two integers"
                                          "primitive.type"))
                         (when (zerop (value-int-value (second values)))
                           (language-fail "mod expects a non-zero divisor"
                                          "primitive.arithmetic"))
                         (runtime-int-result
                          (rem (value-int-value (first values))
                               (value-int-value (second values))))))
                :shape (runtime-shape-exact 2) :category :arithmetic)
    (register "=" (lambda (args env &key force &allow-other-keys)
                     (declare (ignore env))
                     (let ((values (args* args force)))
                       (make-vbool (or (null values)
                                       (every (lambda (x) (equal-value (first values) x))
                                              (rest values)))))
              )
              :shape (runtime-shape-range 0) :category :arithmetic)
    (dolist (spec (list (list "<" #'< #'<) (list ">" #'> #'>)
                       (list "<=" #'<= #'<=) (list ">=" #'>= #'>=)))
      (destructuring-bind (name int-cmp float-cmp) spec
        (register name
                  (lambda (args env &key force &allow-other-keys)
                    (declare (ignore env))
                    (runtime-numeric-compare name args int-cmp float-cmp force))
                  :shape (runtime-shape-range 0) :category :arithmetic)))
    ;; Lazy list and collection operations.
    (register "cons" (lambda (args env &key &allow-other-keys)
                        (declare (ignore env))
                        (unless (= (length args) 2)
                          (runtime-primitive-arity-error "cons" 2 (length args)))
                        (make-vpair (first args) (second args)))
              :shape (runtime-shape-exact 2) :category :collections)
    (register "list" (lambda (args env &key &allow-other-keys)
                        (declare (ignore env)) (value-list args))
              :shape (runtime-shape-range 0) :category :collections)
    (register "collect"
              (lambda (args env &key force &allow-other-keys)
                (declare (ignore env))
                (unless (= (length args) 1)
                  (runtime-primitive-arity-error "collect" 1 (length args)))
                (let ((input (force* (first args) force))
                      (successes nil)
                      (errors nil))
                  (labels ((walk (value)
                             (let ((value (force* value force)))
                               (typecase value
                                 (value-nil nil)
                                 (value-pair
                                  (let* ((entry (force* (value-pair-car value) force))
                                         (parts (pair-values entry)))
                                    (unless (= (length parts) 2)
                                      (language-fail
                                       "collect expects tagged result pairs"
                                       "primitive.type"))
                                    (let ((tag (force* (first parts) force))
                                          (payload (force* (second parts) force)))
                                      (unless (typep tag 'value-keyword)
                                        (language-fail
                                         "collect expects :ok or :err tags"
                                         "primitive.type"))
                                      (cond
                                        ((string= (value-keyword-value tag) "ok")
                                         (push payload successes))
                                        ((string= (value-keyword-value tag) "err")
                                         (push payload errors))
                                        (t
                                         (language-fail
                                          "collect expects :ok or :err tags"
                                          "primitive.type"))))
                                    (walk (value-pair-cdr value))))
                                 (t
                                  (language-fail
                                   "collect expects a proper list"
                                   "primitive.type"))))))
                    (walk input))
                  (if errors
                      (value-list
                       (list (make-vkeyword "err")
                             (value-list (nreverse errors))))
                      (value-list
                       (list (make-vkeyword "ok")
                             (value-list (nreverse successes)))))))
              :shape (runtime-shape-exact 1) :category :collections)
    (register "apply" (lambda (args env &key force apply &allow-other-keys)
                        (unless (>= (length args) 2)
                          (language-fail
                           "apply expects a function and at least one list segment"
                           "primitive.arity"))
                        (let ((fn (force* (first args) force)))
                          (labels ((splice (list-value)
                                     (let ((value (force* list-value force)))
                                       (typecase value
                                         (value-nil nil)
                                         (value-pair
                                          (cons (value-pair-car value)
                                                (splice (value-pair-cdr value))))
                                         (t (language-fail
                                             "apply expects proper list segments"
                                             "primitive.type"))))))
                            (apply* fn
                                    (mapcan #'splice (rest args))
                                    env apply))))
              :shape (runtime-shape-range 2) :category :collections)
    (register "map" (lambda (args env &key force apply &allow-other-keys)
                      (unless (= (length args) 2)
                        (runtime-primitive-arity-error "map" 2 (length args)))
                      (let ((fn (force* (first args) force)))
                        (labels ((collect (list-value)
                                   (let ((value (force* list-value force)))
                                     (typecase value
                                       (value-nil nil)
                                       (value-pair
                                        (cons (value-pair-car value)
                                              (collect (value-pair-cdr value))))
                                       (t (language-fail
                                           "map expects a proper list"
                                           "primitive.type"))))))
                          (value-list
                           (mapcar (lambda (item)
                                     (apply* fn (list item) env apply))
                                   (collect (second args)))))))
              :shape (runtime-shape-exact 2) :category :collections)
    ;; Explicit metaprogramming calls share the evaluator's callbacks.  They
    ;; never invoke host READ/EVAL and return ordinary pp values.
    (register "eval-pp"
              (lambda (args env &key force force-deep eval &allow-other-keys)
                (eval-pp* args env force force-deep eval))
              :shape (runtime-shape-exact 1) :category :metaprogramming)
    (register "apply-pp"
              (lambda (args env &key force eager apply &allow-other-keys)
                ;; Check arity before forcing arguments.  A malformed
                ;; apply-pp call must report its pp primitive contract even
                ;; when one of its unevaluated arguments would otherwise
                ;; trigger an evaluator/environment failure.
                (unless (= (length args) 2)
                  (runtime-primitive-arity-error "apply-pp" 2 (length args)))
                (let ((values (args* args force)))
                  (let ((fn (force* (first values) force)))
                    (labels ((collect (value)
                               (let ((value (force* value force)))
                                 (typecase value
                                   (value-nil nil)
                                   (value-pair
                                    (cons (value-pair-car value)
                                          (collect (value-pair-cdr value))))
                                   (t (language-fail
                                       "apply-pp expects a proper list for args"
                                       "primitive.type"))))))
                      (let ((call-args (collect (second values))))
                        ;; The evaluator's ordinary closure path historically
                        ;; extended the environment before checking arity.
                        ;; Keep apply-pp's callback boundary from exposing that
                        ;; internal environment error.
                        (when (typep fn 'value-closure)
                          (let* ((closure (value-closure-closure fn))
                                 (params (closure-params closure)))
                            (unless (= (length params) (length call-args))
                              (language-fail
                               (format nil "~A expects ~D argument~:P, got ~D"
                                       (or (closure-fn-name closure) "#<fn>")
                                       (length params) (length call-args))
                               "evaluator.arity"))))
                        (eager* fn call-args env eager apply))))))
              :shape (runtime-shape-exact 2) :category :metaprogramming)
    (register "force-deep"
              (lambda (args env &key force-deep force &allow-other-keys)
                (declare (ignore env))
                (unless (= (length args) 1)
                  (runtime-primitive-arity-error "force-deep" 1 (length args)))
                (deep* (first args) force-deep force))
              :shape (runtime-shape-exact 1) :category :metaprogramming)
    (register "read-string"
              (lambda (args env &key force &allow-other-keys)
                (declare (ignore env))
                (let ((values (args* args force)))
                  (unless (and (= (length values) 1)
                               (typep (first values) 'value-string))
                    (language-fail "read-string expects a source string"
                                   "primitive.type"))
                  (handler-case
                      (let ((expressions
                              (read-source (value-string-value (first values)))))
                        (if (= (length expressions) 1)
                            (runtime-quote-to-value (first expressions))
                            (make-vvector
                             (coerce (mapcar #'runtime-quote-to-value expressions)
                                     'vector))))
                    (frontend-error (condition)
                      (language-fail
                       (frontend-error-message condition)
                       "primitive.read-string"
                       (frontend-error-range condition))))))
              :shape (runtime-shape-exact 1) :category :metaprogramming)
    (register "car" (lambda (args env &key force &allow-other-keys)
                       (declare (ignore env))
                       (unless (= (length args) 1)
                         (runtime-primitive-arity-error "car" 1 (length args)))
                       (let ((v (force* (first args) force)))
                         (typecase v
                           (value-pair (value-pair-car v))
                           (value-nil v)
                           (t (language-fail "car expects a pair" "primitive.type")))))
              :shape (runtime-shape-exact 1) :category :collections)
    (register "cdr" (lambda (args env &key force &allow-other-keys)
                       (declare (ignore env))
                       (unless (= (length args) 1)
                         (runtime-primitive-arity-error "cdr" 1 (length args)))
                       (let ((v (force* (first args) force)))
                         (typecase v
                           (value-pair (value-pair-cdr v))
                           (value-nil v)
                           (t (language-fail "cdr expects a pair" "primitive.type")))))
              :shape (runtime-shape-exact 1) :category :collections)
    (register "nil?" (lambda (args env &key force &allow-other-keys)
                         (declare (ignore env))
                         (unless (= (length args) 1)
                           (runtime-primitive-arity-error "nil?" 1 (length args)))
                         (make-vbool (typep (force* (first args) force) 'value-nil)))
              :shape (runtime-shape-exact 1) :category :collections)
    (register "vector" (lambda (args env &key &allow-other-keys)
                          (declare (ignore env))
                          (make-vvector (coerce args 'vector)))
              :shape (runtime-shape-range 0) :category :collections)
    (register "vector-get" (lambda (args env &key force &allow-other-keys)
                              (declare (ignore env))
                              (let ((values (args* args force)))
                                (unless (and (= (length values) 2)
                                             (typep (first values) 'value-vector)
                                             (typep (second values) 'value-int))
                                  (language-fail "vector-get expects a vector and an integer"
                                                 "primitive.type"))
                                (let ((index (value-int-value (second values)))
                                      (vector (value-vector-values (first values))))
                                  (if (and (>= index 0) (< index (length vector)))
                                      (aref vector index)
                                      (language-fail "vector index out of bounds"
                                                     "primitive.range")))))
              :shape (runtime-shape-exact 2) :category :collections)
    (register "vector-length" (lambda (args env &key force &allow-other-keys)
                                 (declare (ignore env))
                                 (let ((values (args* args force)))
                                   (unless (and (= (length values) 1)
                                                (typep (first values) 'value-vector))
                                     (language-fail "vector-length expects a vector"
                                                    "primitive.type"))
                                   (runtime-int-result
                                    (length (value-vector-values (first values))))))
              :shape (runtime-shape-exact 1) :category :collections)
    (register "hash-map" (lambda (args env &key force-deep force &allow-other-keys)
                            (declare (ignore env))
                            (when (oddp (length args))
                              (language-fail "hash-map expects an even number of arguments"
                                             "primitive.arity"))
                            (let ((entries nil))
                              (loop for (key value) on args by #'cddr
                                    do (push (cons (deep* key force-deep force) value) entries))
                              (make-vmap (canonical-map-entries (nreverse entries)))))
              :shape (runtime-shape-range 0) :category :collections)
    (register "hash-map-get" (lambda (args env &key force force-deep &allow-other-keys)
                                (declare (ignore env))
                                (let ((values (args* args force)))
                                  (unless (and (= (length values) 2)
                                               (typep (first values) 'value-map))
                                    (language-fail "hash-map-get expects a map and a key"
                                                   "primitive.type"))
                                  (let* ((key (deep* (second values) force-deep force))
                                         (entry (find key (value-map-entries (first values))
                                                      :test #'same-content :key #'car)))
                                    (if entry (cdr entry) (make-vnil)))))
              :shape (runtime-shape-exact 2) :category :collections)
    (register "hash-set" (lambda (args env &key &allow-other-keys)
                            (declare (ignore env)) (make-vset args))
              :shape (runtime-shape-range 0) :category :collections)
    (register "set->list" (lambda (args env &key force &allow-other-keys)
                             (declare (ignore env))
                             (unless (= (length args) 1)
                               (runtime-primitive-arity-error "set->list" 1 (length args)))
                             (let ((value (force* (first args) force)))
                               (if (typep value 'value-set)
                                   (value-list (canonical-set-elements
                                                (value-set-values value)))
                                   (language-fail "set->list expects a set"
                                                  "primitive.type"))))
              :shape (runtime-shape-exact 1) :category :collections)
    (register "pair?"
              (lambda (args env &key force &allow-other-keys)
                (declare (ignore env))
                (unless (= (length args) 1)
                  (runtime-primitive-arity-error "pair?" 1 (length args)))
                (let ((value (force* (first args) force)))
                  (make-vbool (or (typep value 'value-pair)
                                  (typep value 'value-nil)))))
              :shape (runtime-shape-exact 1) :category :collections)
    ;; Predicates.
    (dolist (spec '(("int?" value-int) ("float?" value-float)
                    ("string?" value-string) ("bool?" value-bool)
                    ("keyword?" value-keyword) ("symbol?" value-symbol)
                    ("pair?" value-pair) ("vector?" value-vector)
                    ("map?" value-map) ("set?" value-set)
                    ("fn?" value-closure)))
      (destructuring-bind (name type) spec
        (register name
                  (lambda (args env &key force &allow-other-keys)
                    (declare (ignore env))
                    (unless (= (length args) 1)
                      (runtime-primitive-arity-error name 1 (length args)))
                    (let ((v (force* (first args) force)))
                      (make-vbool
                       (if (eq type 'value-closure)
                           (or (typep v 'value-closure)
                               (typep v 'value-builtin))
                           (if (eq type 'value-pair)
                               (or (typep v 'value-pair)
                                   (typep v 'value-nil))
                               (typep v type)))))
                    )
                  :shape (runtime-shape-exact 1) :category :collections))
    )
    (register "thunk?" (lambda (args env &key &allow-other-keys)
                           (declare (ignore env))
                           (unless (= (length args) 1)
                             (runtime-primitive-arity-error "thunk?" 1 (length args)))
                           (make-vbool (typep (first args) 'value-thunk)))
              :shape (runtime-shape-exact 1) :category :collections)
    ;; String and presentation conversions.
    (register "print" (lambda (args env &key force-deep force &allow-other-keys)
                        (declare (ignore env))
                        (let ((values (args* args (or force-deep force))))
                          (unless (null values)
                            (dolist (value values)
                              (write-string (runtime-string-of-value value)))
                            (terpri)))
                        (make-vnil))
              :shape (runtime-shape-range 0) :category :observations)
    (register "error" (lambda (args env &key force &allow-other-keys)
                        (declare (ignore env))
                        (let ((values (args* args force)))
                          (unless (and (= (length values) 1)
                                       (typep (first values) 'value-string))
                            (language-fail "error expects one string"
                                           "primitive.type"))
                          (language-fail (value-string-value (first values))
                                         "primitive.error")))
              :shape (runtime-shape-exact 1) :category :other)
    (register "argv"
              (lambda (args env &key force &allow-other-keys)
                (declare (ignore env))
                (argv-values args force))
              :shape (runtime-shape-exact 0) :category :observations)
    (dolist (spec '(("file-exists?" nil) ("dir?" t)))
      (destructuring-bind (name want-directory) spec
        (register name
                  (lambda (args env &key force &allow-other-keys)
                    (declare (ignore env))
                    (let ((values (args* args force)))
                      (unless (and (= (length values) 1)
                                   (typep (first values) 'value-string))
                        (language-fail
                         (format nil "~A expects a path string" name)
                         "primitive.type"))
                      (let ((kind (stat-kind
                                   (value-string-value (first values))
                                   name)))
                        (make-vbool
                         (if want-directory
                             (string= kind "dir")
                             (not (string= kind "absent")))))))
                  :shape (runtime-shape-exact 1) :category :observations)))
    (register "exit"
              (lambda (args env &key force &allow-other-keys)
                (declare (ignore env))
                (let ((status (exit-value args force))
                      (service (and (fboundp 'runtime-observation-service)
                                    (runtime-observation-service :exit))))
                  (if service
                      (funcall service status)
                      (language-exit status))))
              :shape (runtime-shape-range 0 1) :category :other)
    (register "cap-none" (lambda (args env &key &allow-other-keys)
                           (declare (ignore env))
                           (unless (null args)
                             (runtime-primitive-arity-error "cap-none" 0 (length args)))
                           (make-vcapability (make-cap-none)))
              :shape (runtime-shape-exact 0) :category :capabilities)
    (register "cap-compose" (lambda (args env &key force &allow-other-keys)
                              (declare (ignore env))
                              (make-vcapability
                               (compose-capabilities
                                (mapcar (lambda (value)
                                          (let ((value (force* value force)))
                                            (unless (typep value 'value-capability)
                                              (language-fail
                                               "cap-compose expects capabilities"
                                               "primitive.type"))
                                            (value-capability-capability value)))
                                        args))))
              :shape (runtime-shape-range 0) :category :capabilities)
    (register "current-capabilities" (lambda (args env &key &allow-other-keys)
                                       (declare (ignore env))
                                       (unless (null args)
                                         (runtime-primitive-arity-error
                                          "current-capabilities" 0 (length args)))
                                       (runtime-dynamic-require-script-tier
                                        "current-capabilities: may not be called inside a node body (scripting-tier only)")
                                       (make-vcapability
                                        (compose-capabilities
                                         (runtime-dynamic-capabilities))))
              :shape (runtime-shape-exact 0) :category :capabilities)
    (register "configure-runtime"
              (lambda (args env &key force force-deep &allow-other-keys)
                (declare (ignore env))
                (runtime-configure* args force force-deep))
              :shape (runtime-shape-exact 1) :category :domains)
    (register "runtime-config"
              (lambda (args env &key &allow-other-keys)
                (declare (ignore env))
                (runtime-config-value args))
              :shape (runtime-shape-exact 0) :category :domains)
    (register "register-reporter"
              (lambda (args env &key force &allow-other-keys)
                (declare (ignore env))
                (runtime-register-reporter args force))
              :shape (runtime-shape-exact 1) :category :domains)
    (register "emit-event"
              (lambda (args env &key force &allow-other-keys)
                (declare (ignore env))
                (runtime-emit-event args force))
              :shape (runtime-shape-exact 1) :category :domains)
    (register "cap-restrict"
              (lambda (args env &key force &allow-other-keys)
                (declare (ignore env))
                (let ((values (args* args force)))
                  (unless (or (= (length values) 2) (= (length values) 3))
                    (runtime-primitive-arity-error "cap-restrict" "2 or 3"
                                                   (length values)))
                  (unless (and (typep (first values) 'value-capability)
                               (typep (second values) 'value-string))
                    (language-fail
                     "cap-restrict expects a capability and scope string"
                     "primitive.type"))
                  (let* ((cap (value-capability-capability (first values)))
                         (scope (canonicalize-path
                                 (value-string-value (second values))
                                 :realpath #'identity))
                         (mode
                           (when (= (length values) 3)
                             (unless (typep (third values) 'value-keyword)
                               (language-fail
                                "cap-restrict mode must be :ro, :rw, or :wo"
                                "primitive.type"))
                             (let ((name (value-keyword-value (third values))))
                               (cond ((string= name "ro") :read)
                                     ((string= name "rw") :read-write)
                                     ((string= name "wo") :write)
                                     (t (language-fail
                                         "cap-restrict mode must be :ro, :rw, or :wo"
                                         "primitive.type")))))))
                    (when mode
                      (let ((allowed
                              (case mode
                                (:read (capability-check-fs-read-p cap scope))
                                (:write (capability-check-fs-write-p cap scope))
                                (:read-write
                                 (and (capability-check-fs-read-p cap scope)
                                      (capability-check-fs-write-p cap scope))))))
                        (unless allowed
                          (language-fail
                           "cap-restrict cannot widen the underlying capability"
                           "primitive.capability")))
                    )
                    (make-vcapability
                     (restrict-capability cap scope :mode mode)))))
              :shape (runtime-shape-range 2 3) :category :capabilities)
    (register (format nil "~Cneeds-current-capabilities" #\Null)
              (lambda (args env &key &allow-other-keys)
                (declare (ignore env))
                (unless (null args)
                  (runtime-primitive-arity-error
                   "needs-current-capabilities" 0 (length args)))
                (make-vcapability
                 (compose-capabilities (runtime-dynamic-capabilities))))
              :shape (runtime-shape-exact 0) :category :capabilities)
    (register (format nil "~Cneeds-value" #\Null)
              (lambda (args env &key &allow-other-keys)
                (declare (ignore env))
                (unless (= (length args) 1)
                  (runtime-primitive-arity-error "needs-value" 1 (length args)))
                (first args))
              :shape (runtime-shape-exact 1) :category :metaprogramming)
    (register "capability?" (lambda (args env &key force &allow-other-keys)
                              (declare (ignore env))
                              (unless (= (length args) 1)
                                (runtime-primitive-arity-error "capability?" 1
                                                               (length args)))
                              (make-vbool
                               (typep (force* (first args) force)
                                      'value-capability)))
              :shape (runtime-shape-exact 1) :category :capabilities)
    (register "string-append" (lambda (args env &key force &allow-other-keys)
                                 (declare (ignore env))
                                 (make-vstring
                                  (apply #'concatenate 'string
                                         (mapcar (lambda (v)
                                                   (let ((v (force* v force)))
                                                     (if (typep v 'value-string)
                                                         (value-string-value v)
                                                         (runtime-string-of-value v))))
                                                 args))))
              :shape (runtime-shape-range 0) :category :strings)
    (register "string-length" (lambda (args env &key force &allow-other-keys)
                                 (declare (ignore env))
                                 (let ((values (args* args force)))
                                   (unless (and (= (length values) 1)
                                                (typep (first values) 'value-string))
                                     (language-fail "string-length expects a string"
                                                    "primitive.type"))
                                   (runtime-int-result
                                    (length (string-octets
                                             (value-string-value (first values)))))))
              :shape (runtime-shape-exact 1) :category :strings)
    (register "not" (lambda (args env &key force &allow-other-keys)
                       (declare (ignore env))
                       (unless (= (length args) 1)
                         (runtime-primitive-arity-error "not" 1 (length args)))
                       (let ((v (force* (first args) force)))
                         (make-vbool (or (typep v 'value-nil)
                                         (and (typep v 'value-bool)
                                              (not (value-bool-value v)))))))
              :shape (runtime-shape-exact 1) :category :strings)
    (register "->string" (lambda (args env &key force-deep force &allow-other-keys)
                            (declare (ignore env))
                            (unless (= (length args) 1)
                              (runtime-primitive-arity-error "->string" 1 (length args)))
                            (let ((v (deep* (first args) force-deep force)))
                              (make-vstring
                               (if (typep v 'value-string)
                                   (value-string-value v)
                                   (runtime-string-of-value v)))))
              :shape (runtime-shape-exact 1) :category :strings)
    (register "number->string" (lambda (args env &key force &allow-other-keys)
                                  (declare (ignore env))
                                  (let ((values (args* args force)))
                                    (unless (and (= (length values) 1)
                                                 (runtime-number-p (first values)))
                                      (language-fail "number->string expects a number"
                                                     "primitive.type"))
                                    (make-vstring
                                     (if (typep (first values) 'value-int)
                                         (canonical-integer-string
                                          (value-int-value (first values)))
                                         (runtime-float-presentation
                                          (value-float-value (first values)))))))
              :shape (runtime-shape-exact 1) :category :strings)
    (register "string->number" (lambda (args env &key force &allow-other-keys)
                                  (declare (ignore env))
                                  (let ((values (args* args force)))
                                    (unless (and (= (length values) 1)
                                                 (typep (first values) 'value-string))
                                      (language-fail "string->number expects a string"
                                                     "primitive.type"))
                                    (or (runtime-parse-number-string
                                         (value-string-value (first values)))
                                        (make-vnil))))
              :shape (runtime-shape-exact 1) :category :strings)
    (register "hash-value" (lambda (args env &key force-deep force &allow-other-keys)
                              (declare (ignore env))
                              (unless (= (length args) 1)
                                (runtime-primitive-arity-error "hash-value" 1 (length args)))
                              (make-vstring (hash-value (deep* (first args) force-deep force))))
              :shape (runtime-shape-exact 1) :category :other)
    (register "hash-string" (lambda (args env &key force &allow-other-keys)
                               (declare (ignore env))
                               (let ((values (args* args force)))
                                 (unless (and (= (length values) 1)
                                              (typep (first values) 'value-string))
                                   (language-fail "hash-string expects a string"
                                                  "primitive.type"))
                                 (make-vstring
                                  (hash-string (value-string-value (first values))))))
              :shape (runtime-shape-exact 1) :category :other)
    (register "string-index" (lambda (args env &key force &allow-other-keys)
                                (declare (ignore env))
                                (let ((values (args* args force)))
                                  (unless (and (= (length values) 2)
                                               (every (lambda (v) (typep v 'value-string)) values))
                                    (language-fail "string-index expects two strings"
                                                   "primitive.type"))
                                  (let* ((s (string-octets (value-string-value
                                                            (first values))))
                                         (sub (string-octets (value-string-value
                                                              (second values))))
                                         (index (search sub s)))
                                    (if index (runtime-int-result index) (make-vnil)))))
              :shape (runtime-shape-exact 2) :category :strings)
    (register "string-trim" (lambda (args env &key force &allow-other-keys)
                               (declare (ignore env))
                               (let ((values (args* args force)))
                                 (unless (and (= (length values) 1)
                                              (typep (first values) 'value-string))
                                   (language-fail "string-trim expects a string"
                                                  "primitive.type"))
                                 (make-vstring (string-trim '(#\Space #\Tab #\Newline #\Return)
                                                            (value-string-value (first values))))))
              :shape (runtime-shape-exact 1) :category :strings)
    (register "string-sub" (lambda (args env &key force &allow-other-keys)
                              (declare (ignore env))
                              (let ((values (args* args force)))
                                (unless (and (= (length values) 3)
                                             (typep (first values) 'value-string)
                                             (typep (second values) 'value-int)
                                             (typep (third values) 'value-int))
                                  (language-fail "string-sub expects a string, start, and length"
                                                 "primitive.type"))
                                (let* ((bytes (string-octets
                                               (value-string-value (first values))))
                                       (start (value-int-value (second values)))
                                       (length (value-int-value (third values))))
                                  (if (or (< start 0) (< length 0)
                                          (> (+ start length) (length bytes)))
                                      (language-fail "string-sub: out of bounds"
                                                     "primitive.range")
                                      (make-vstring
                                       (runtime-utf8-slice-to-string
                                        (subseq bytes start (+ start length))))))))
              :shape (runtime-shape-exact 3) :category :strings)
    (register "string-split" (lambda (args env &key force &allow-other-keys)
                               (declare (ignore env))
                               (let ((values (args* args force)))
                                 (unless (and (= (length values) 2)
                                              (typep (first values) 'value-string)
                                              (typep (second values) 'value-string)
                                              (plusp (length (value-string-value
                                                              (second values)))))
                                   (language-fail
                                    "string-split expects a string and non-empty separator"
                                    "primitive.type"))
                                 (let* ((source (string-octets
                                                 (value-string-value (first values))))
                                        (separator (string-octets
                                                    (value-string-value (second values))))
                                        (start 0) (pieces nil))
                                   (loop
                                     for index = (search separator source :start2 start)
                                     do (if index
                                            (progn
                                              (push (runtime-utf8-slice-to-string
                                                     (subseq source start index))
                                                    pieces)
                                              (setf start (+ index (length separator))))
                                            (progn
                                              (push (runtime-utf8-slice-to-string
                                                     (subseq source start))
                                                    pieces)
                                              (return))))
                                   (value-list
                                    (mapcar #'make-vstring (nreverse pieces))))))
              :shape (runtime-shape-exact 2) :category :strings)
    ;; Map utilities.
    (register "map-keys" (lambda (args env &key force &allow-other-keys)
                            (declare (ignore env))
                            (unless (= (length args) 1)
                              (runtime-primitive-arity-error "map-keys" 1 (length args)))
                            (let ((v (force* (first args) force)))
                              (if (typep v 'value-map)
                                  (value-list (mapcar #'car (value-map-entries v)))
                                  (language-fail "map-keys expects a map" "primitive.type"))))
              :shape (runtime-shape-exact 1) :category :collections)
    (register "map-vals" (lambda (args env &key force &allow-other-keys)
                            (declare (ignore env))
                            (unless (= (length args) 1)
                              (runtime-primitive-arity-error "map-vals" 1 (length args)))
                            (let ((v (force* (first args) force)))
                              (if (typep v 'value-map)
                                  (value-list (mapcar #'cdr (value-map-entries v)))
                                  (language-fail "map-vals expects a map" "primitive.type"))))
              :shape (runtime-shape-exact 1) :category :collections)
    (register "map-remove" (lambda (args env &key force force-deep &allow-other-keys)
                              (declare (ignore env))
                              (unless (= (length args) 2)
                                (runtime-primitive-arity-error "map-remove" 2 (length args)))
                              (let ((map (force* (first args) force))
                                    (key (deep* (second args) force-deep force)))
                                (if (typep map 'value-map)
                                    (make-vmap (remove key (value-map-entries map)
                                                        :test #'same-content :key #'car))
                                    (language-fail "map-remove expects a map and a key"
                                                   "primitive.type"))))
              :shape (runtime-shape-exact 2) :category :collections)
    (register "map-insert" (lambda (args env &key force force-deep &allow-other-keys)
                              (declare (ignore env))
                              (unless (= (length args) 3)
                                (runtime-primitive-arity-error "map-insert" 3 (length args)))
                              (let ((map (force* (first args) force))
                                    (key (deep* (second args) force-deep force)))
                                (if (typep map 'value-map)
                                    (make-vmap
                                     (canonical-map-entries
                                      (append (value-map-entries map)
                                              (list (cons key (third args))))))
                                    (language-fail "map-insert expects a map, key, and value"
                                                   "primitive.type"))))
              :shape (runtime-shape-exact 3) :category :collections)
    (register "map-merge" (lambda (args env &key force &allow-other-keys)
                             (declare (ignore env))
                             (unless (= (length args) 2)
                               (runtime-primitive-arity-error "map-merge" 2 (length args)))
                             (let ((left (force* (first args) force))
                                   (right (force* (second args) force)))
                               (if (and (typep left 'value-map)
                                        (typep right 'value-map))
                                   (make-vmap (canonical-map-entries
                                               (append (value-map-entries left)
                                                       (value-map-entries right))))
                                   (language-fail "map-merge expects two maps"
                                                  "primitive.type"))))
              :shape (runtime-shape-exact 2) :category :collections)
    ;; Quasiquote data walker.  The reader is deliberately not involved.
    (register "quasiquote" (lambda (args env &key force &allow-other-keys)
                              (declare (ignore env))
                              (unless (= (length args) 1)
                                (runtime-primitive-arity-error "quasiquote" 1 (length args)))
                              (labels ((append-list (left right)
                                         (cond ((typep left 'value-nil) right)
                                               ((typep left 'value-pair)
                                                (make-vpair (value-pair-car left)
                                                            (append-list (value-pair-cdr left)
                                                                         right)))
                                               (t (language-fail
                                                   "unquote-splicing expects a list"
                                                   "primitive.quote"))))
                                       (walk (v)
                                         (let ((items (and (typep v 'value-pair)
                                                           (proper-value-list v))))
                                           (cond
                                             ((and items (= (length items) 2)
                                                   (typep (first items) 'value-symbol)
                                                   (string= (value-symbol-value (first items))
                                                            "unquote"))
                                              (second items))
                                             ((and (typep v 'value-pair)
                                                   (typep (value-pair-car v) 'value-pair)
                                                   (let ((head (proper-value-list
                                                                (value-pair-car v))))
                                                     (and head (= (length head) 2)
                                                          (typep (first head) 'value-symbol)
                                                          (string= (value-symbol-value
                                                                    (first head))
                                                                   "unquote-splicing"))))
                                              (let* ((head (proper-value-list
                                                            (value-pair-car v)))
                                                     (spliced (second head)))
                                                (append-list spliced
                                                             (walk (value-pair-cdr v)))))
                                             ((typep v 'value-pair)
                                              (make-vpair (walk (value-pair-car v))
                                                          (walk (value-pair-cdr v))))
                                             ((typep v 'value-vector)
                                              (make-vvector
                                               (map 'vector #'walk
                                                    (value-vector-values v))))
                                             (t v)))))
                                (walk (force* (first args) force))))
              :shape (runtime-shape-exact 1) :category :metaprogramming)
    (register "unquote" (lambda (args env &key &allow-other-keys)
                           (declare (ignore env args))
                           (language-fail "unquote not allowed outside quasiquote"
                                          "primitive.quote"))
              :shape (runtime-shape-exact 1) :category :metaprogramming)
    (register "unquote-splicing" (lambda (args env &key &allow-other-keys)
                                    (declare (ignore env args))
                                    (language-fail
                                     "unquote-splicing not allowed outside quasiquote"
                                     "primitive.quote"))
              :shape (runtime-shape-exact 1) :category :metaprogramming)
    ;; A fresh catalog is the deterministic gensym scope.  Session code may
    ;; discard/recreate the catalog at a run boundary to reset it.
    (register "gensym" (lambda (args env &key force &allow-other-keys)
                          (declare (ignore env))
                          (runtime-dynamic-require-script-tier
                           "gensym: may not be called inside a node body (scripting-tier only)")
                          (let* ((values (args* args force))
                                 (prefix (cond ((null values) "g")
                                               ((and (= (length values) 1)
                                                     (typep (first values) 'value-string))
                                                (value-string-value (first values)))
                                               ((and (= (length values) 1)
                                                     (typep (first values) 'value-symbol))
                                                (value-symbol-value (first values)))
                                               (t (language-fail
                                                   "gensym expects an optional string prefix"
                                                   "primitive.type")))))
                            (incf (runtime-primitive-catalog-gensym-counter catalog))
                            (make-vsymbol
                             (format nil "~A~~~D" prefix
                                     (runtime-primitive-catalog-gensym-counter catalog)))))
              :shape (runtime-shape-range 0 1) :category :metaprogramming)
    ;; Internal aliases used by match lowering; NUL cannot occur in pp source.
    (dolist (name '("car" "cdr" "=" "nil?" "not" "pair?"))
      (runtime-primitive-alias catalog (format nil "~C~A" (code-char 0) name) name))
    (runtime-primitive-finalize catalog)))


;;; ---------------------------------------------------------------------------
;;; Macro expansion

(defstruct (runtime-macro-definition
            (:constructor make-runtime-macro-definition (name params body)))
  name params body)

(defstruct (runtime-macro-state (:constructor make-runtime-macro-state))
  (macros (make-hash-table :test #'equal))
  (expansion-count 0) (max-expansions 100000))

(defstruct (runtime-macro-services
            (:constructor make-runtime-macro-services
                (&key eval force-deep initial-env)))
  eval force-deep initial-env)

(defun runtime-macro-set (state name params body)
  (setf (gethash name (runtime-macro-state-macros state))
        (make-runtime-macro-definition name params body))
  state)

(defun runtime-macro-find (state name)
  (gethash name (runtime-macro-state-macros state)))

(defun runtime-relocate (location expression)
  (if (or (typep expression 'expr-located) (null location))
      expression
      (make-elocated location expression)))

(defun runtime-match-defmacro (expression)
  (when (and (typep expression 'expr-apply)
             (typep (expr-apply-function expression) 'expr-symbol)
             (string= (expr-symbol-name (expr-apply-function expression)) "defmacro"))
    (let ((args (expr-apply-arguments expression)))
      (when (null args)
        (language-fail "defmacro: expected (defmacro (name params...) body...)"
                       "macro.definition"))
      (let ((head (first args))
            (body-expressions (rest args)))
        (unless (and (typep head 'expr-apply)
                     (typep (expr-apply-function head) 'expr-symbol))
          (language-fail "defmacro: expected (name params...)"
                         "macro.definition"))
        (when (null body-expressions)
          (language-fail
           (format nil "defmacro: '~A' has no body"
                   (expr-symbol-name (expr-apply-function head)))
           "macro.definition"))
        (let ((params
                (mapcar (lambda (parameter)
                          (if (typep parameter 'expr-symbol)
                              (expr-symbol-name parameter)
                              (language-fail "defmacro parameters must be symbols"
                                             "macro.definition")))
                        (expr-apply-arguments head))))
          (values (expr-symbol-name (expr-apply-function head)) params
                  (if (= (length body-expressions) 1)
                      (first body-expressions)
                      (make-edo body-expressions))))))))

(defun runtime-macro-env-extend (environment names values)
  (make-env (append (mapcar #'cons names values) (env-bindings environment))
            :env-id (env-env-id environment)
            :env-hash (env-env-hash environment)))

(defun runtime-apply-macro (services state name params body args location)
  (incf (runtime-macro-state-expansion-count state))
  (when (> (runtime-macro-state-expansion-count state)
           (runtime-macro-state-max-expansions state))
    (language-fail (format nil "macro '~A': expansion did not terminate" name)
                   "macro.nontermination"))
  (unless (= (length params) (length args))
    (language-fail
     (format nil "macro '~A': expected ~D argument~:P, got ~D"
             name (length params) (length args))
     "macro.arity"))
  (let* ((eval (runtime-macro-services-eval services))
         (force-deep (runtime-macro-services-force-deep services))
         (initial-env (runtime-macro-services-initial-env services))
         (old-location (runtime-macro-location-for-state state)))
    (unless (and eval force-deep initial-env)
      (language-fail "macro services require eval, force-deep, and initial-env callbacks"
                     "macro.services"))
    ;; eval-pp reached while evaluating a macro body must inherit this
    ;; invocation's location.  Restore it after the nested machine run so a
    ;; later sibling macro in the same evaluator state cannot inherit it.
    (runtime-publish-macro-context services state location)
    (unwind-protect
         (handler-case
             (let* ((quoted-args (mapcar #'runtime-quote-to-value args))
                    (macro-env (runtime-macro-env-extend
                                (funcall initial-env) params quoted-args))
                    (result (funcall force-deep (funcall eval body macro-env)))
                    (expanded (runtime-value-to-expr result)))
               (runtime-relocate location expanded))
           (language-error (condition)
             (language-fail (format nil "macro '~A': ~A" name
                                    (language-error-message condition))
                            "macro.expansion"
                            (or (language-error-range condition) location)))
           (error (condition)
             (language-fail (format nil "macro '~A': ~A" name condition)
                            "macro.expansion"
                            location)))
      (let ((context (runtime-macro-context-for-state state)))
        (when context
          (setf (runtime-macro-context-location context) old-location))))))

(defun runtime-expand-expression (services state expression &optional location)
  ;; Publish the caller's outer range for metaprogramming primitives such as
  ;; eval-pp.  Keep it state-scoped; a nested evaluator cannot borrow another
  ;; state's source context.
  (let ((caller-location
          (or location
              (and (typep expression 'expr-located)
                   (expr-located-range expression)))))
    (runtime-publish-macro-context services state caller-location))
  (labels ((walk (loc e)
             (typecase e
               (expr-located
                (make-elocated (expr-located-range e)
                               (walk (expr-located-range e)
                                     (expr-located-expression e))))
               (expr-apply
                (let ((function (expr-apply-function e))
                      (args (expr-apply-arguments e)))
                  (if (and (typep function 'expr-symbol)
                           (runtime-macro-find state
                                                (expr-symbol-name function)))
                      (let* ((definition (runtime-macro-find
                                          state (expr-symbol-name function)))
                             (expanded
                               (runtime-apply-macro
                                services state (runtime-macro-definition-name definition)
                                (runtime-macro-definition-params definition)
                                (runtime-macro-definition-body definition)
                                args loc)))
                        (walk loc expanded))
                      (make-eapply (walk loc function)
                                   (mapcar (lambda (x) (walk loc x)) args)))))
               (expr-quote e)
               ((or expr-literal expr-symbol expr-load expr-loadmodule expr-island) e)
               (expr-if (make-eif (walk loc (expr-if-condition e))
                                  (walk loc (expr-if-then e))
                                  (walk loc (expr-if-else e))))
               (expr-let (make-elet
                          (mapcar (lambda (binding)
                                    (cons (car binding) (walk loc (cdr binding))))
                                  (expr-let-bindings e))
                          (walk loc (expr-let-body e))))
               (expr-letstar (make-eletstar
                              (mapcar (lambda (binding)
                                        (cons (car binding) (walk loc (cdr binding))))
                                      (expr-letstar-bindings e))
                              (walk loc (expr-letstar-body e))))
               (expr-fn (make-efn (expr-fn-params e)
                                  (walk loc (expr-fn-body e))))
               (expr-force (make-eforce (walk loc (expr-force-expression e))))
               (expr-delay (make-edelay (walk loc (expr-delay-expression e))))
               (expr-node (make-enode (walk loc (expr-node-expression e))))
               ((or expr-def expr-defnode)
                (if (typep e 'expr-def)
                    (make-edef (expr-def-name e) (expr-def-params e)
                               (walk loc (expr-def-body e)))
                    (make-edefnode (expr-defnode-name e) (expr-defnode-params e)
                                   (walk loc (expr-defnode-body e)))))
               (expr-defvalue (make-edefvalue (expr-defvalue-name e)
                                              (walk loc (expr-defvalue-expression e))))
               ((or expr-do expr-module)
                (if (typep e 'expr-do)
                    (make-edo (mapcar (lambda (x) (walk loc x))
                                      (expr-do-expressions e)))
                    (make-emodule (mapcar (lambda (x) (walk loc x))
                                          (expr-module-expressions e)))))
               (expr-with-caps (make-ewith-caps
                                (walk loc (expr-with-caps-caps e))
                                (walk loc (expr-with-caps-body e))))
               (expr-perform (make-eperform
                              (expr-perform-name e)
                              (mapcar (lambda (x) (walk loc x))
                                      (expr-perform-arguments e))))
               (expr-with-handler (make-ewith-handler
                                   (mapcar (lambda (handler)
                                             (cons (car handler)
                                                   (walk loc (cdr handler))))
                                           (expr-with-handler-handlers e))
                                   (walk loc (expr-with-handler-body e))))
               (expr-import (make-eimport (walk loc (expr-import-expression e))))
               (expr-with-config (make-ewith-config
                                  (walk loc (expr-with-config-map-expression e))
                                  (walk loc (expr-with-config-body e))))
               (expr-config (make-econfig
                             (walk loc (expr-config-key-expression e))
                             (and (expr-config-default e)
                                  (walk loc (expr-config-default e)))))
               ;; Type expressions are syntax data and remain unchanged during
               ;; macro expansion.
               (expr-typed (make-typed (walk loc (expr-typed-expression e))
                                       (expr-typed-type e)))
               (expr-match (make-ematch
                            (walk loc (expr-match-scrutinee e))
                            (mapcar (lambda (arm)
                                      (destructuring-bind (pattern guard body) arm
                                        (list pattern
                                              (and guard (walk loc guard))
                                              (walk loc body))))
                                    (expr-match-arms e))))
               (t (language-fail "unknown expression structure"
                                 "macro.expression")))))
    (walk location expression)))

(defun runtime-expand-toplevel (services state expressions)
  "Expand EXPRESSIONS sequentially, registering only direct top-level defmacro
forms.  A definition produces (quote NAME), preserving one result per form."
  (runtime-publish-macro-context services state)
  (setf (runtime-macro-state-expansion-count state) 0)
  (mapcar
   (lambda (expression)
     (let ((location (and (typep expression 'expr-located)
                          (expr-located-range expression)))
           (inner (if (typep expression 'expr-located)
                      (expr-located-expression expression)
                      expression)))
       (runtime-publish-macro-context services state location)
       (multiple-value-bind (name params body)
           (runtime-match-defmacro inner)
         (if name
             (progn
               (runtime-macro-set state name params body)
               (runtime-relocate location (make-equote (make-esymbol name))))
             (runtime-relocate
              location
              (runtime-expand-expression services state inner location))))))
   expressions))
;; Narrow names used by the evaluator/runtime owners after package integration.
(setf (symbol-function 'free-vars) #'runtime-free-variable-names)
(setf (symbol-function 'quote-to-value) #'runtime-quote-to-value)
(setf (symbol-function 'value-to-expr) #'runtime-value-to-expr)
(setf (symbol-function 'value-to-pattern) #'runtime-value-to-pattern)
(setf (symbol-function 'match-pattern) #'runtime-match-pattern)
(setf (symbol-function 'string-of-value) #'runtime-string-of-value)
(setf (symbol-function 'value-list-opt) #'proper-value-list)
(setf (symbol-function 'expand-toplevel) #'runtime-expand-toplevel)

;;; Compatibility aliases for evaluator/session owners; these are intentionally
;;; runtime-prefixed so the already-loaded kernel's pure helpers remain intact.
(setf (symbol-function 'runtime-free-vars) #'runtime-free-variable-names)
(setf (symbol-function 'runtime-quote) #'runtime-quote-to-value)
(setf (symbol-function 'runtime-reify) #'runtime-value-to-expr)
