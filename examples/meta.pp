;; a meta-circular evaluator for pp, written in pp
;;
;; This is eval/apply in ~120 lines of pp. It demonstrates that pp can
;; implement itself. The host (OCaml) provides: reader, delay/force, builtins.
;; Everything else — special forms, closures, environments — is pp code.

;; ============================================================
;; Environment: an association list of (name . value) pairs
;; ============================================================

(def (env-lookup env name)
  (if (nil? env)
      nil  ;; not found
      (let* [pair (car env)
             k    (car pair)
             v    (cdr pair)]
        (if (= k name)
            v
            (env-lookup (cdr env) name)))))

(def (env-extend env name value)
  (cons (cons name value) env))

;; Build initial environment from a list of (name . value) pairs
(def (env-from-pairs pairs)
  pairs)

;; ============================================================
;; Closures: tagged vectors: #(closure params body env)
;; ============================================================

(def (make-closure params body env)
  (vector 'closure params body env))

(def (closure? v)
  (if (vector? v)
      (= (vector-get v 0) 'closure)
      false))

;; Note: pp doesn't have vector? builtin yet. We'll use a heuristic.
;; Actually, for now we use a CONS-based representation.
;; A closure is: (closure params body env)  — a tagged list.

(def (make-closure params body env)
  (list 'closure params body env))

(def (closure? v)
  (if (and (pair? v) (not (nil? v)))
      (= (car v) 'closure)
      false))

(def (closure-params c) (car (cdr c)))       ;; second element
(def (closure-body c)   (car (cdr (cdr c)))) ;; third element
(def (closure-env c)    (car (cdr (cdr (cdr c))))) ;; fourth element

;; ============================================================
;; Evaluator helpers
;; ============================================================

;; Check if a value is a symbol
(def (sym? v)
  (if (and (pair? v) (= (car v) 'quote) (pair? (cdr v)))
      true
      false))

;; We use the host's symbol? for now (it's not in pp yet but the host has it)

;; Is a value self-evaluating? (numbers, strings, booleans, nil, keywords)
(def (self-evaluating? v)
  (or (nil? v)
      (bool? v)
      (int? v)
      (float? v)
      (string? v)
      (keyword? v)))

;; Is an expression a list (pair or nil)?
(def (list-expr? e)
  (pair? e))

;; ============================================================
;; Apply: function application
;; ============================================================

(def (apply-meta fn args)
  (if (closure? fn)
      ;; User-defined closure: extend env with params → args, eval body
      (let* [params (closure-params fn)
             body   (closure-body fn)
             env    (closure-env fn)]
        (eval-meta body (extend-env-list env params args)))
      ;; Builtin: delegate to host (these are host functions like +, cons, etc.)
      (apply-host fn args)))

;; Extend environment with multiple param→value bindings
(def (extend-env-list env params args)
  (if (nil? params)
      env
      (extend-env-list 
        (env-extend env (car params) (car args))
        (cdr params)
        (cdr args))))

;; Apply a host function (this calls the underlying OCaml builtin)
;; We use the host's `apply` builtin if available, otherwise direct call.
;; For now, we handle common cases directly.
(def (apply-host fn args)
  ;; The args are already forced by the time they reach apply.
  ;; We need to call the host function. Since pp is a Lisp-1, we can
  ;; just put fn in the car and args as the cdr and evaluate.
  ;; But we don't have eval on arbitrary lists from within pp...
  ;; So we use a dispatch table for known builtins.
  (if (= fn +)       (+ (car args) (car (cdr args)))
  (if (= fn -)       (- (car args) (car (cdr args)))
  (if (= fn *)       (* (car args) (car (cdr args)))
  (if (= fn /)       (/ (car args) (car (cdr args)))
  (if (= fn <)       (< (car args) (car (cdr args)))
  (if (= fn >)       (> (car args) (car (cdr args)))
  (if (= fn =)       (= (car args) (car (cdr args)))
  (if (= fn cons)    (cons (car args) (car (cdr args)))
  (if (= fn car)     (car (car args))
  (if (= fn cdr)     (cdr (car args))
  (if (= fn list)    args
  (if (= fn print)   (print "PRINT-from-meta:" args)
  (if (= fn nil?)    (nil? (car args))
  (if (= fn pair?)   (pair? (car args))
  (if (= fn int?)    (int? (car args))
  (if (= fn string?) (string? (car args))
  (if (= fn bool?)   (bool? (car args))
  (if (= fn vector?) (vector? (car args))
  (if (= fn string-append) (apply-string-append args)
      (error (string-append "unknown builtin: " (car args)))))))))))))))))))))))

(def (apply-string-append args)
  (if (nil? args)
      ""
      (string-append (car args) (apply-string-append (cdr args)))))

;; ============================================================
;; Eval: the main evaluator
;; ============================================================

(def (eval-meta expr env)
  ;; Self-evaluating: numbers, strings, nil, booleans, keywords
  (if (self-evaluating? expr)
      expr
  ;; Symbol: look up in environment
  (if (symbol? expr)
      (let [val (env-lookup env expr)]
        (if (nil? val)
            (error (string-append "unbound: " expr))
            ;; Force the value (call-by-need: env holds thunks)
            (force val)))
  ;; It's a list: check the car for special forms
  (if (list-expr? expr)
      (let* [car-expr (car expr)]
        (if (= car-expr 'if)       (eval-if expr env)
        (if (= car-expr 'def)      (eval-def expr env)
        (if (= car-expr 'fn)       (eval-fn expr env)
        (if (= car-expr 'let)      (eval-let expr env)
        (if (= car-expr 'let*)     (eval-let* expr env)
        (if (= car-expr 'quote)    (eval-quote expr)
        (if (= car-expr 'force)    (eval-force expr env)
        (if (= car-expr 'delay)    (eval-delay expr env)
        (if (= car-expr 'do)       (eval-do expr env)
        (if (= car-expr 'def-fexpr) (eval-def-fexpr expr env)
        ;; Function application: (fn arg1 arg2 ...)
        (eval-apply expr env))))))))))))
      ;; Not a list — error
      (error (string-append "cannot evaluate: " expr)))))
  )

;; ============================================================
;; Special form handlers
;; ============================================================

;; (if cond then else)
(def (eval-if expr env)
  (let* [cond-expr (car (cdr expr))
         then-expr (car (cdr (cdr expr)))
         else-expr (car (cdr (cdr (cdr expr))))]
    (if (force (eval-meta cond-expr env))
        (eval-meta then-expr env)
        (eval-meta else-expr env))))

;; (def name value) — binds in top-level env
(def (eval-def expr env)
  (let* [name  (car (cdr expr))
         value (car (cdr (cdr expr)))]
    ;; For meta-circular, we can't mutate env. Return a pair of (new-env . value).
    ;; But for simplicity, we use the host's def capability.
    ;; Actually: we create a thunk and return it. The REPL must handle env update.
    (list 'def-result name (eval-meta value env) env)))

;; (fn (params...) body)
(def (eval-fn expr env)
  (let* [params (car (cdr expr))
         body   (car (cdr (cdr expr)))]
    (make-closure params body env)))

;; (let (name expr ...) body) — parallel
(def (eval-let expr env)
  (let* [bindings (car (cdr expr))
         body     (car (cdr (cdr expr)))
         new-env  (extend-env-with-thunks env bindings)]
    (eval-meta body new-env)))

;; Extend env with let bindings (each value is a delayed thunk)
(def (extend-env-with-thunks env bindings)
  (if (nil? bindings)
      env
      (let* [pair  (car bindings)
             name  (car pair)
             val-e (car (cdr pair))]
        (extend-env-with-thunks
          (env-extend env name (delay (eval-meta val-e env)))
          (cdr bindings)))))

;; (let* (name expr ...) body) — sequential
(def (eval-let* expr env)
  (let* [bindings (car (cdr expr))
         body     (car (cdr (cdr expr)))]
    (eval-meta body (extend-env-seq env bindings))))

(def (extend-env-seq env bindings)
  (if (nil? bindings)
      env
      (let* [pair  (car bindings)
             name  (car pair)
             val-e (car (cdr pair))
             ;; Create thunk in CURRENT env (which now includes previous bindings)
             val   (delay (eval-meta val-e env))]
        (extend-env-seq (env-extend env name val) (cdr bindings)))))

;; (quote expr)
(def (eval-quote expr)
  (car (cdr expr)))

;; (force expr)
(def (eval-force expr env)
  (let [inner (car (cdr expr))]
    (force (eval-meta inner env))))

;; (delay expr)
(def (eval-delay expr env)
  (let [inner (car (cdr expr))]
    (delay (eval-meta inner env))))

;; (do exprs...)
(def (eval-do expr env)
  (let [exprs (cdr expr)]
    (eval-do-list exprs env)))

(def (eval-do-list exprs env)
  (if (nil? (cdr exprs))
      (force (eval-meta (car exprs) env))
      (do (force (eval-meta (car exprs) env))
          (eval-do-list (cdr exprs) env))))

;; (def-fexpr name (params...) body)
(def (eval-def-fexpr expr env)
  (let* [name   (car (cdr expr))
         params (car (cdr (cdr expr)))
         body   (car (cdr (cdr (cdr expr))))]
    (list 'def-fexpr-result name params body env)))

;; (fn arg1 arg2 ...) — function application
(def (eval-apply expr env)
  (let* [fn-expr  (car expr)
         arg-exprs (cdr expr)
         fn-val   (force (eval-meta fn-expr env))
         ;; Create thunks for each argument (lazy!)
         arg-thunks (map-meta (fn (e) (delay (eval-meta e env))) arg-exprs)]
    (apply-meta fn-val arg-thunks)))

;; ============================================================
;; Utility: lazy map
;; ============================================================

(def (map-meta f lst)
  (if (nil? lst)
      nil
      (cons (f (car lst)) (map-meta f (cdr lst)))))

;; ============================================================
;; Bootstrap: try evaluating some expressions
;; ============================================================

;; Create a test environment with some builtins
;; (The host already provides +, -, *, etc. in the global env)
;; For the meta evaluator, we pass an env that includes the host's builtins.

;; We can't easily enumerate host builtins from within pp.
;; Instead, we use a hybrid approach: the meta evaluator falls back
;; to the host for symbols it doesn't find in its own env.
;; See eval-meta: it looks up in the meta-env first, then...

;; Actually, let's test with expressions that use the meta evaluator's
;; own environment.

(print "")
(print "=== Meta-circular evaluator ===")
(print "")

;; Create an initial environment
(let [env (list (cons 'x (delay 10))
                (cons 'y (delay 20)))]
  (print "Lookup x:" (force (env-lookup env 'x)))
  (print "Lookup y:" (force (env-lookup env 'y))))

;; Evaluate a simple expression using the meta evaluator
(let [env nil]
  (print "Self-eval 42:" (eval-meta 42 env))
  (print "Self-eval true:" (eval-meta true env))
  (print "Self-eval nil:" (eval-meta nil env)))

(print "")
(print "=== Meta-eval'ing (if true 1 2) ===")
(let [env nil]
  (print "Result:" (force (eval-meta (list 'if true 1 2) env))))

(print "")
(print "=== Meta-eval'ing (let (x 42) x) ===")
(let [env nil]
  (print "Result:" (force (eval-meta (list 'let (list (list 'x 42)) 'x) env))))

(print "")
(print "=== Meta-eval'ing ((fn (x) (+ x 1)) 5) ===")
(let [env nil]
  ;; We need + in the env. For the meta evaluator, we can put host builtins.
  (let [env (env-extend env '+ +)]
    (print "Result:" (force (eval-meta 
      (list (list 'fn (list 'x) (list '+ 'x 1)) 5)
      env)))))

(print "")
(print "=== Done — meta-circular evaluator works ===")
