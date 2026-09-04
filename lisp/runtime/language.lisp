;;;; Pure language operations.
;;;; This file contains no source reader, host EVAL/READ/INTERN, evaluator
;;;; loop, session state, or host effects. The evaluator supplies callbacks.

(in-package #:pp.rt.lang)

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

 
;;; The evaluator's macro table is explicit state, but primitive callbacks
;;; Expansion entry points publish the active invocation's macro context through
;;; a dynamic binding and the existing macro-services state seam. Nested
;;; evaluator runs therefore cannot inherit another invocation's source.
(defstruct (runtime-macro-context
            (:constructor make-runtime-macro-context
                (root &optional location state)))
  root location state)

(defvar *runtime-macro-context* nil)

(defun runtime-macro-context-value ()
  "The dynamically current macro context, or NIL when none is published.
The exported seam other packages must use instead of referencing the
private special directly."
  *runtime-macro-context*)

(defun runtime-macro-context-bind (value thunk)
  "Run THUNK with the private macro-context special bound to VALUE,
restoring the previous value afterwards."
  (let ((*runtime-macro-context* value))
    (funcall thunk)))

(defun runtime-macro-context-for-state (state)
  (declare (ignore state))
  *runtime-macro-context*)

(defun runtime-publish-macro-context (services state &optional location)
  (let ((initial-env
          (handler-case
              (funcall (runtime-macro-services-initial-env services))
            (error () nil)))
        (owner (or (runtime-macro-services-state services) state)))
    (unless *runtime-macro-context*
      (setf *runtime-macro-context*
            (make-runtime-macro-context initial-env location owner)))
    (when location
      (setf (runtime-macro-context-location *runtime-macro-context*) location))
    owner))

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
  (and *runtime-macro-context*
       (runtime-macro-env-descends-from-p
        environment (runtime-macro-context-root *runtime-macro-context*))
       (runtime-macro-context-state *runtime-macro-context*)))

(defun runtime-macro-location-for-env (environment)
  (and (runtime-macro-state-for-env environment)
       (runtime-macro-context-location *runtime-macro-context*)))

(defun runtime-macro-location-for-state (state)
  (and *runtime-macro-context*
       (eq state (runtime-macro-context-state *runtime-macro-context*))
       (runtime-macro-context-location *runtime-macro-context*)))

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
         value-env-map value-sealed value-opaque)
     (language-fail
      (typecase value
        (value-closure "cannot convert a closure to syntax")
        (value-builtin "cannot convert a builtin to syntax")
        (value-capability "cannot convert a capability to syntax")
        (value-thunk "cannot convert an unevaluated thunk to syntax")
        (value-env-map "cannot convert a module to syntax")
        (value-sealed "cannot convert a sealed value to syntax")
        (value-opaque "cannot convert opaque bytes to syntax")
        (t "cannot convert an unsupported value to syntax"))
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
    (value-opaque "#<opaque-bytes>")
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
          (unless (durable-value-p field-value)
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
                (&key eval force-deep initial-env state)))
  eval force-deep initial-env state)

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
