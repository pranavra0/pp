;;;; Primitive registration table.
;;;; Populates the pure-primitive catalog (builtin implementations and
;;;; aliases) and exposes the resulting initial environment.  Language-level
;;;; helpers live in language.lisp; this file specializes the protocol
;;;; generics that install them.

(in-package #:pp.rt.primitives)

;;; Initial builtin environment, from the finalized CATALOG.

(defmethod runtime-primitive-initial-env (catalog)
  (make-env
   (sort (loop for name being the hash-keys of
                         (runtime-primitive-catalog-builtins catalog)
               using (hash-value value)
               collect (cons name value))
         #'string< :key #'car)))

(defmethod runtime-install-pure-primitives ()
   "Populate CATALOG with deterministic, effect-free builtins and finalize it.
Implementations accept (ARGS ENV &key FORCE FORCE-DEEP APPLY EVAL EAGER).  APPLY
is supplied by the evaluator for apply/map; EAGER is the evaluator's immediate
callback path for metaprogramming calls.  No host evaluator is used as a
fallback."
  (let ((catalog (make-runtime-primitive-catalog)))
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
                            (pp.frontend:read-source
                             (runtime-eval-pp-source text location)
                             :source (or source "<?>"))
                          (pp.frontend:frontend-error (condition)
                            (language-fail
                             (pp.frontend:frontend-error-message condition)
                             "primitive.read-string"
                             (pp.frontend:frontend-error-range condition)))))
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
            (when (fboundp 'pp.rt.observation:runtime-observation-record)
              (pp.rt.observation:runtime-observation-record
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
            (when (fboundp 'pp.rt.observation:runtime-observation-record)
              (pp.rt.observation:runtime-observation-record
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
                              (pp.frontend:read-source (value-string-value (first values)))))
                        (if (= (length expressions) 1)
                            (runtime-quote-to-value (first expressions))
                            (make-vvector
                             (coerce (mapcar #'runtime-quote-to-value expressions)
                                     'vector))))
                    (pp.frontend:frontend-error (condition)
                      (language-fail
                       (pp.frontend:frontend-error-message condition)
                       "primitive.read-string"
                       (pp.frontend:frontend-error-range condition))))))
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
                            (declare (ignore env))
                            (make-vset (canonical-set-elements args)))
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
    (runtime-primitive-finalize catalog))))
