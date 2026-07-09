;; pp compiler — self-hosting port of compiler.ml
;; Uses bytecode compiler primitives to emit opcodes.
;; Defines compile-program and compile-expr.

;; ---- Helpers ----

(def (intern v)
  (ppc-emit-constant v))

(def (emit opcode-name . operands)
  (ppc-emit-opcode opcode-name operands))

(def (intern-name name)
  (intern name))

;; ---- Lexical environment ----
;; cenv is a list of frames; each frame is a list of names.
;; We track it as a mutable state via the ppc-push-cenv-frame/ppc-pop-cenv-frame primitives.

(def (resolve cenv name)
  ;; Walk cenv frames; return (Local depth slot) or Global
  (def (walk depth frames)
    (if (nil? frames)
        (list 'Global)
        (let ((frame (car frames)))
          (def (scan idx names)
            (if (nil? names)
                (walk (+ depth 1) (cdr frames))
                (if (= (car names) name)
                    (list 'Local depth idx)
                    (scan (+ idx 1) (cdr names)))))
          (scan 0 frame))))
  (walk 0 cenv))

;; ---- Tail-position dispatch ----
;; We thread a `tail` flag through compile-expr.

;; ---- Compile an expression ----
(def (compile-expr e tail)
  (match e
    ;; ELiteral
    ((list 'literal v)
     (emit 'PUSH (intern v)))
    
    ;; ESymbol
    ((list 'symbol name)
     (let ((res (resolve (ppc-get-cenv) name)))
       (match res
         ((list 'Global)
          (emit 'LOAD_GLOBAL (intern-name name)))
         ((list 'Local d s)
          (emit 'LOAD_LOCAL d s))))
     (emit 'FORCE))
    
    ;; EIf
    ((list 'if cond then-e else-e)
     (compile-expr cond false)
     (emit 'FORCE)
     (let ((jmp-false-idx (ppc-current-offset)))
       (emit 'JUMP_IF_FALSE 0)  ;; placeholder
       (compile-expr then-e tail)
       (let ((jmp-end-idx (ppc-current-offset)))
         (emit 'JUMP 0)  ;; placeholder
         (let ((else-start (ppc-current-offset)))
           (ppc-backpatch-jump jmp-false-idx (- else-start jmp-false-idx))
           (compile-expr else-e tail)
           (let ((end-idx (ppc-current-offset)))
             (ppc-backpatch-jump jmp-end-idx (- end-idx jmp-end-idx)))))))
    
    ;; EFn
    ((list 'fn params body)
     (let ((off (ppc-current-offset)))
       (ppc-push-cenv-frame params)
       (compile-expr body true)
       (emit 'RETURN)
       (ppc-pop-cenv-frame)
       (ppc-record-nparams off (length params))
       (ppc-record-param-names off params)
       (emit 'MAKE_CLOSURE off (length params))))
    
    ;; EApply
    ((list 'apply fn-expr . arg-exprs)
     (compile-expr fn-expr false)
     (for-each (fn (arg)
       (let ((off (ppc-current-offset)))
         (compile-expr arg true)
         (emit 'RETURN)
         (emit 'MAKE_THUNK off)))
       arg-exprs)
     (if tail
         (emit 'TAIL_CALL (length arg-exprs))
         (emit 'CALL (length arg-exprs))))
    
    ;; EQuote
    ((list 'quote e)
     (emit 'PUSH (intern (quote-to-value e))))
    
    ;; EForce
    ((list 'force e)
     (compile-expr e false)
     (emit 'FORCE))
    
    ;; EDelay
    ((list 'delay e)
     (let ((off (ppc-current-offset)))
       (compile-expr e true)
       (emit 'RETURN)
       (emit 'MAKE_THUNK off)))
    
    ;; EDo — sequencing with mutual recursion
    ((list 'do . exprs)
     (compile-do exprs tail))
    
    ;; Default: fail
    (_ (error (str "compile-expr: unknown expr: " (print e))))))

;; ---- compile-do: two-pass for mutual recursion ----
(def (compile-do exprs tail)
  ;; Pass 1: pre-scan for def/def-fexpr names
  (let ((def-names '()))
    (for-each (fn (sub)
      (match sub
        ((list 'def name . _)
         (set! def-names (cons name def-names)))
        ((list 'def-fexpr name . _)
         (set! def-names (cons name def-names))
         (ppc-mark-fexpr name))
        (_ nil)))
      exprs)
    ;; Push frame with all names
    (let ((is-top (nil? (ppc-get-cenv))))
      (if (not is-top)
          (ppc-push-cenv-frame (reverse def-names))
          nil)
      ;; Pass 2: compile each sub-expression
      (def (compile-subs xs)
        (if (nil? xs)
            nil
            (if (nil? (cdr xs))
                (compile-expr (car xs) tail)  ;; last is tail
                (let ((sub (car xs)))
                  (match sub
                    ((list 'def name params body)
                     (let ((off (ppc-current-offset)))
                       (ppc-push-cenv-frame params)
                       (compile-expr body true)
                       (emit 'RETURN)
                       (ppc-pop-cenv-frame)
                       (ppc-record-nparams off (length params))
                       (ppc-record-param-names off params)
                       (emit 'MAKE_CLOSURE off (length params))
                       (if is-top
                           (emit 'STORE_GLOBAL (intern-name name))
                           (emit 'STORE_LOCAL (ppc-get-def-slot name)))))
                    ((list 'def-fexpr name params body)
                     (let ((off (ppc-current-offset)))
                       (ppc-push-cenv-frame params)
                       (compile-expr body true)
                       (emit 'RETURN)
                       (ppc-pop-cenv-frame)
                       (ppc-record-nparams off (length params))
                       (ppc-record-param-names off params)
                       (emit 'MAKE_FEXPR off (length params))
                       (if is-top
                           (emit 'STORE_GLOBAL (intern-name name))
                           (emit 'STORE_LOCAL (ppc-get-def-slot name)))))
                    ;; Non-def: force & pop
                    (_ (do
                         (compile-expr sub false)
                         (emit 'FORCE)
                         (emit 'POP))))
                  (compile-subs (cdr xs))))))
      (compile-subs exprs)
      (if (not is-top)
          (ppc-pop-cenv-frame)
          nil))))

;; ---- compile-program ----
(def (compile-program exprs)
  (ppc-init-compiler)
  (for-each (fn (e) (compile-expr e true)) exprs)
  (emit 'HALT)
  (ppc-finish))

;; Expose for module use
;; (export compile-program compile-expr)
