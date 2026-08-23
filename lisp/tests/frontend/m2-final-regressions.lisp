;;;; Focused M2 frontend probes.  Load after pp/frontend.

(in-package #:pp.frontend)

(defun m2-final-regressions ()
  (labels ((ok (name thunk)
             (handler-case (progn (funcall thunk) (list name :ok))
               (error (e) (list name :failed (princ-to-string e)))))
           (read-brace (text)
             (read-source text :surface :brace)))
    (list
     (ok :lint
         (lambda ()
           (assert (find "lint.dotted-identifier"
                         (lint-source (list (pp.kernel::make-esymbol "foo.bar")))
                         :key (lambda (row) (getf row :code))
                         :test #'string=))))
     (ok :quasiquote
         (lambda () (assert (read-brace "quasiquote { 1 }"))))
     (ok :brace-quasiquote-symbol-data
         (lambda ()
           (let* ((forms (read-brace "quasiquote { x }"))
                  (printed (print-source forms :surface :brace))
                  (again (read-brace printed)))
             (assert (string= printed "quasiquote { x }"))
             (assert (= 1 (length again)))
             (assert (string= (pp.kernel:hash-expr (first forms))
                              (pp.kernel:hash-expr (first again)))))))
     (ok :with-comma-clauses
         (lambda ()
           (assert (read-brace "with { caps: c, config: m } { 1 }"))))
     (ok :brace-incomplete-range
         (lambda ()
           (handler-case (read-brace "if x {")
             (frontend-error (e)
               (assert (frontend-error-incomplete-p e))
               (assert (frontend-error-range e))))))
     (ok :sexpr-match-unprintable
         (lambda ()
           (handler-case
               (print-source (read-source "(match x ((list a) a))"
                                           :surface :sexpr)
                             :surface :sexpr)
             (frontend-error (e)
               (assert (string= (frontend-error-code e)
                                "printer.unprintable"))))))
     (ok :sexpr-annotated-roundtrip
         (lambda ()
           (let* ((forms (read-source "(def (f x : T) : U x)"
                                      :surface :sexpr))
                  (printed (print-source forms :surface :sexpr))
                  (again (read-source printed :surface :sexpr)))
             (assert (= 1 (length again)))
             (assert (string= (pp.kernel:hash-expr (first forms))
                              (pp.kernel:hash-expr (first again)))))))
     (ok :printer-purity
         (lambda ()
           (let* ((forms (read-brace "def f(x: T) : U { x }"))
                  (first (print-source forms :surface :brace))
                  (second (print-source forms :surface :brace)))
             (assert (string= first second)))))
     (ok :sexpr-quasiquote-odd-map
         (lambda ()
           (handler-case (read-source "`{a}" :surface :sexpr)
             (frontend-error (e)
               (assert (string= (frontend-error-code e)
                                "reader.syntax"))))))
     (ok :number-diagnostics
         (lambda ()
           (dolist (text '("1e" "1e400"))
             (handler-case (read-source text :surface :sexpr)
               (frontend-error (e)
                 (assert (frontend-error-range e))
                 (assert (member (frontend-error-code e)
                                 '("reader.invalid-number"
                                   "reader.float-range")
                                 :test #'string=)))))))
     (ok :sexpr-colon-symbol
         (lambda ()
           (assert (read-source "(f x:T)" :surface :sexpr))))
     (ok :sexpr-quasiquote-map
         (lambda ()
           (assert (read-source "`{a b}" :surface :sexpr))))
     (ok :annotated-function-roundtrip
         (lambda ()
           (let* ((forms (read-brace "def f(x: T) { x }"))
                  (printed (print-source forms :surface :brace)))
             (assert (read-brace printed)))))
     (ok :vec-spread
         (lambda () (assert (read-brace "vec[1, ...xs]"))))
     (ok :match-rest
         (lambda () (assert (read-brace "match x { [a, ...rest] => a }"))))
     (ok :match-tagged-roundtrip
         (lambda ()
           (let* ((forms (read-brace "match x { (:ok v) => v }"))
                  (printed (print-source forms :surface :brace)))
             (assert (read-brace printed)))))
     (ok :fstring-doubled-braces
         (lambda () (assert (read-brace "f\"{{x}}\""))))
     (ok :letstar
         (lambda ()
           (let* ((forms (read-brace "let*(x = 1) { x }"))
                  (printed (print-source forms :surface :brace)))
             (assert (read-brace printed)))))
     (ok :bare-handler
         (lambda ()
           (assert (read-brace
                    "with { handlers: { foo -> fn(x) { x } } } { 1 }"))))
     (ok :needs-private-authority
         (lambda ()
           (let* ((forms (read-brace "node n() needs fs.read(p) { 1 }"))
                  (printed (print-source forms :surface :sexpr)))
             (assert (search (string #\Null) printed)))))
     (ok :special-floats
         (lambda ()
           (dolist (text '("nan" "inf" "-inf"))
             (let* ((forms (read-brace text))
                    (printed (print-source forms :surface :brace)))
               (assert (read-brace printed)))))))))
