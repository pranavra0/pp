;;;; Common Lisp frontend for pp.  This file is deliberately self contained so it
;;;; can be loaded by the saved image before the ASDF component list is migrated.
;;;; Source text is handled as characters and strings only: neither READ nor INTERN
;;;; is used on input supplied by a user.

(in-package #:pp.frontend)

;; Accessors for kernel structures that are intentionally not package exports
;; yet.  They are fixed implementation symbols, never derived from user text.
(defun expr-located-expression (x) (pp.kernel::expr-located-expression x))
(defun expr-located-range (x) (pp.kernel::expr-located-range x))
(defun expr-module-expressions (x) (pp.kernel::expr-module-expressions x))
(defun expr-import-expression (x) (pp.kernel::expr-import-expression x))
(defun expr-load-path (x) (pp.kernel::expr-load-path x))
(defun expr-loadmodule-path (x) (pp.kernel::expr-loadmodule-path x))
(defun expr-island-uri (x) (pp.kernel::expr-island-uri x))
(defun expr-island-pin (x) (pp.kernel::expr-island-pin x))
(defun expr-with-config-map-expression (x) (pp.kernel::expr-with-config-map-expression x))
(defun expr-with-config-body (x) (pp.kernel::expr-with-config-body x))
(defun expr-config-key-expression (x) (pp.kernel::expr-config-key-expression x))
(defun expr-config-default (x) (pp.kernel::expr-config-default x))
(defun expr-typed-expression (x) (pp.kernel::expr-typed-expression x))
(defun expr-typed-type (x) (pp.kernel::expr-typed-type x))
(defparameter *surface-observation-heads*
  '(("file" 1 "slurp") ("env" 1 "env-get") ("glob" 1 "tree-observe")
    ("probe" 1 "probe") ("secret" 1 "slurp") ("config" 1 "config")))
(defparameter *surface-observation-descriptors*
  '(("file" 1 1 t "slurp")
    ("env" 1 2 t "env-get")
    ("glob" 1 1 t "tree-observe")
    ("probe" 1 1 t "probe")
    ("secret" 1 1 t "slurp")
    ("config" 1 2 t "config")))
 (defparameter *frontend-sigil-expressions* (make-hash-table :test #'eq))
 (defparameter *frontend-list-literal-expressions* (make-hash-table :test #'eq))
 (defparameter *frontend-list-spread-expressions* (make-hash-table :test #'eq))
 (defparameter *frontend-map-spread-expressions* (make-hash-table :test #'eq))
 (defparameter *frontend-qq-name-expressions* (make-hash-table :test #'equal))
 (defparameter *frontend-qq-parse-depth* 0)

(defun fe-observation-descriptor (name)
  (find name *surface-observation-descriptors* :key #'first :test #'string=))
;;; ---------------------------------------------------------------------------
(declaim (ftype function fe-parse-sexpr fe-name-spread-p fe-bexpr
                         expr-list-of-body fe-print-pattern))
;;; Structured source diagnostics

(define-condition frontend-error (error)
  ((code :initarg :code :reader frontend-error-code)
   (message :initarg :message :reader frontend-error-message)
   (range :initarg :range :initform nil :reader frontend-error-range)
   (incomplete-p :initarg :incomplete-p :initform nil
                 :reader frontend-error-incomplete-p))
  (:report (lambda (c s)
             (format s "~A: ~A" (frontend-error-code c)
                     (frontend-error-message c)))))

(defun frontend-fail (message &key range (code "reader") incomplete-p)
  (error 'frontend-error :code code :message message :range range
         :incomplete-p incomplete-p))

(defstruct (frontend-token (:constructor make-ftoken
                            (kind value range line &optional glued)))
  kind value range line (glued nil))

(defun frontend-point (source offset line column)
  (source-range-point :source source :offset offset :line line :column column))

(defun frontend-range (source so sl sc eo el ec)
  (make-source-range :source source
                     :start-pos (make-position :offset so :line sl :column sc)
                     :end-pos (make-position :offset eo :line el :column ec)))

;;; ---------------------------------------------------------------------------
;;; Character scanners and literals

 (defun fe-name-char-p (c &key brace)
  ;; Sexpr names use maximal munch and therefore retain embedded colons
  ;; (for example `x:T`).  Brace names keep ':' as the annotation/keyword
  ;; boundary.
  (and (not (member c '(#\Space #\Tab #\Newline #\Return #\Comma
                        #\( #\) #\[ #\] #\{ #\} #\< #\' #\` #\" #\;
                        #\# #\~) :test #'char=))
       (or (not brace) (char/= c #\:))))

(defun fe-digit-p (c)
  (and c (<= (char-code #\0) (char-code c) (char-code #\9))))

(defun fe-numeric-start-p (s)
  (and (> (length s) 0)
       (let ((i (if (char= (char s 0) #\-) 1 0)))
         (and (< i (length s))
              (or (fe-digit-p (char s i))
                  (and (char= (char s i) #\.)
                       (< (1+ i) (length s))
                       (fe-digit-p (char s (1+ i)))))))))

(defun fe-number-token-p (s)
  ;; A leading + remains an ordinary symbol. Validate numeric syntax with the
  ;; complete parser rather than a substring test.
  (and (fe-numeric-start-p s)
       (handler-case (progn (fe-parse-number s) t)
         (frontend-error () nil))))

(defun fe-parse-number (s &key range)
  "Parse decimal integers/floats exactly, without the host reader."
  (labels ((bad (message code)
             (frontend-fail message :code code :range range)))
    (let ((n (length s)) (i 0) (negative nil)
          (whole 0) (fraction 0) (fraction-digits 0) (has-dot nil)
          (exponent 0) (has-exponent nil))
      (when (and (< i n) (char= (char s i) #\-))
        (setf negative t) (incf i))
      (let ((before 0))
        (loop while (and (< i n) (fe-digit-p (char s i))) do
          (incf before)
          (setf whole (+ (* whole 10)
                         (- (char-code (char s i)) (char-code #\0))))
          (incf i))
        (when (and (< i n) (char= (char s i) #\.))
          (setf has-dot t) (incf i)
          (loop while (and (< i n) (fe-digit-p (char s i))) do
            (incf fraction-digits)
            (setf fraction (+ (* fraction 10)
                              (- (char-code (char s i)) (char-code #\0))))
            (incf i)))
        (when (zerop (+ before fraction-digits))
          (bad (format nil "invalid number literal: ~A" s)
               "reader.invalid-number")))
      (when (and (< i n) (member (char s i) '(#\e #\E) :test #'char=))
        (setf has-exponent t) (incf i)
        (let ((es 1))
          (when (and (< i n) (member (char s i) '(#\+ #\-) :test #'char=))
            (when (char= (char s i) #\-) (setf es -1))
            (incf i))
          (when (or (= i n) (not (fe-digit-p (char s i))))
            (bad (format nil "invalid number literal: ~A" s)
                 "reader.invalid-number"))
          (loop while (and (< i n) (fe-digit-p (char s i))) do
            (setf exponent (+ (* exponent 10)
                              (- (char-code (char s i)) (char-code #\0))))
            (incf i))
          (setf exponent (* es exponent))))
      (when (< i n)
        (bad (format nil "invalid number literal: ~A" s)
             "reader.invalid-number"))
      ;; Resource bounds before any exact (expt 10 N): a source token like
      ;; 1e100000000 must not allocate an astronomically large integer just
      ;; to fail the float coercion.  |exponent| > 4095 always overflows (or
      ;; underflows to zero) in double-float, so those cases are decided
      ;; without building the bignum; a zero mantissa is zero for any
      ;; exponent.
      (when (> n 4200)
        (bad "too many digits in number literal" "reader.invalid-number"))
      (handler-case
          (if (or has-dot has-exponent)
              (cond ((and has-exponent (zerop whole) (zerop fraction))
                     (coerce 0 'double-float))
                    ((> exponent 4095)
                     (bad (format nil "floating-point literal is out of range: ~A" s)
                          "reader.float-range"))
                    ((< exponent -4095) (coerce 0 'double-float))
                    (t
                     (let* ((scale (expt 10 fraction-digits))
                            (mantissa (/ (+ (* whole scale) fraction) scale))
                            (value (* mantissa (expt 10 exponent))))
                       (coerce (if negative (- value) value) 'double-float))))
              (let ((value (if negative (- whole) whole)))
                (if (<= pp.kernel::+vint-min+ value pp.kernel::+vint-max+)
                    value
                    (bad "integer literal is out of range"
                         "reader.integer-range"))))
        (arithmetic-error ()
          (bad (format nil "floating-point literal is out of range: ~A" s)
               "reader.float-range"))))))
(defun fe-string-escape (s)
  (with-output-to-string (out)
    (write-char #\" out)
    (loop for c across s do
      (case c (#\Newline (write-string "\\n" out))
            (#\Tab (write-string "\\t" out))
            (#\\ (write-string "\\\\" out))
            (#\" (write-string "\\\"" out))
            (t (write-char c out))))
    (write-char #\" out)))

(defun fe-read-string (source text i line col)
  (let ((start i) (sl line) (sc col) (n (length text)) (buf (make-string-output-stream)))
    (incf i) (incf col)
    (loop
      (when (>= i n)
        (frontend-fail "unterminated string" :code "reader.incomplete"
                       :range (frontend-point source i line col) :incomplete-p t))
      (let ((c (char text i)))
        (cond
          ((char= c #\")
           (incf i) (incf col)
           (return (values (get-output-stream-string buf) i line col
                           (frontend-range source start sl sc i line col))))
          ((char= c #\\)
           (incf i) (incf col)
           (when (>= i n)
             (frontend-fail "unterminated escape" :code "reader.incomplete"
                            :range (frontend-point source i line col) :incomplete-p t))
           (let ((e (char text i)))
             (write-char (case e (#\n #\Newline) (#\t #\Tab) (#\\ #\\)
                                  (#\" #\") (t e)) buf)
             (incf i) (incf col)))
          (t (write-char c buf) (incf i)
             (if (char= c #\Newline) (progn (incf line) (setf col 1)) (incf col))))))))

(defun fe-tokenize-sexpr (text &key (source "<?>"))
  (let ((i 0) (line 1) (col 1) (n (length text)) (out nil))
    (labels ((add (kind val so sl sc)
               (push (make-ftoken kind val (frontend-range source so sl sc i line col)
                                   sl nil) out))
             (adv () (let ((c (char text i))) (incf i)
                       (if (char= c #\Newline) (progn (incf line) (setf col 1)) (incf col))))
             (skip-comment () (loop while (and (< i n) (char/= (char text i) #\Newline)) do (adv)))
             (symbol ()
               (let ((so i) (sl line) (sc col) (b (make-string-output-stream)))
                 (loop while (and (< i n) (fe-name-char-p (char text i))) do
                   (write-char (char text i) b) (adv))
                 (let ((s (get-output-stream-string b)))
                   (when (zerop (length s))
                     (frontend-fail "empty symbol" :code "reader.character"
                                    :range (frontend-point source i line col)))
                   (cond
                     ((fe-number-token-p s)
                      (add (if (or (find #\. s)
                                   (find #\e s :test #'char-equal))
                               :float :number)
                           (fe-parse-number
                            s :range (frontend-range source so sl sc i line col))
                           so sl sc))
                     ((fe-numeric-start-p s)
                      ;; A token beginning like a number must not silently
                      ;; become an identifier when its exponent/decimal tail
                      ;; is malformed.
                      (fe-parse-number
                       s :range (frontend-range source so sl sc i line col)))
                     (t (add :symbol s so sl sc))))))
             (number () (symbol))
             (keyword ()
               (let ((so i) (sl line) (sc col))
                 (adv)
                 (let ((start i) (b (make-string-output-stream)))
                   (loop while (and (< i n) (fe-name-char-p (char text i))) do
                     (write-char (char text i) b) (adv))
                   (if (= start i)
                       (add :colon nil so sl sc)
                       (add :keyword (get-output-stream-string b) so sl sc))))))
      (loop while (< i n) do
        (let ((c (char text i)))
          (cond
            ((member c '(#\Space #\Tab #\Newline #\Return) :test #'char=) (adv))
            ((char= c #\:) (keyword))
            ((char= c #\;) (adv) (skip-comment))
            ((char= c #\")
             (multiple-value-bind (s ni nl nc r) (fe-read-string source text i line col)
               (setf i ni line nl col nc) (push (make-ftoken :string s r (position-line (source-range-start r))) out)))
            ((char= c #\() (let ((so i) (sl line) (sc col)) (adv) (add :lparen nil so sl sc)))
            ((char= c #\)) (let ((so i) (sl line) (sc col)) (adv) (add :rparen nil so sl sc)))
            ((char= c #\[) (let ((so i) (sl line) (sc col)) (adv) (add :lbracket nil so sl sc)))
            ((char= c #\]) (let ((so i) (sl line) (sc col)) (adv) (add :rbracket nil so sl sc)))
            ((char= c #\{) (let ((so i) (sl line) (sc col)) (adv) (add :lbrace nil so sl sc)))
            ((char= c #\}) (let ((so i) (sl line) (sc col)) (adv) (add :rbrace nil so sl sc)))
            ((char= c #\') (let ((so i) (sl line) (sc col)) (adv) (add :quote nil so sl sc)))
            ((char= c #\`) (let ((so i) (sl line) (sc col)) (adv) (add :quasiquote nil so sl sc)))
            ((char= c #\,) (let ((so i) (sl line) (sc col)) (adv)
                              (if (and (< i n) (char= (char text i) #\@))
                                  (progn (adv) (add :unquote-splicing nil so sl sc))
                                  (add :unquote nil so sl sc))))
            ((char= c #\#)
             (let ((so i) (sl line) (sc col)) (adv)
               (if (and (< i n) (char= (char text i) #\{))
                   (progn (adv) (add :sharp-lbrace nil so sl sc))
                   (frontend-fail "unexpected character after #" :code "reader.character"
                                  :range (frontend-point source so sl sc)))))
            ((char= c #\<)
             (let ((so i) (sl line) (sc col)) (adv)
               (cond ((and (< i n) (char= (char text i) #\=)) (adv) (add :symbol "<=" so sl sc))
                     ((and (< i n) (or (alpha-char-p (char text i)) (fe-digit-p (char text i))))
                      (let ((b (make-string-output-stream)))
                        (loop while (and (< i n) (char/= (char text i) #\>)) do (write-char (char text i) b) (adv))
                        (when (>= i n) (frontend-fail "unterminated island literal" :code "reader.incomplete" :incomplete-p t))
                        (adv) (add :island (get-output-stream-string b) so sl sc)))
                     (t (add :symbol "<" so sl sc)))))
            (t (symbol)))))
      (let ((r (frontend-point source i line col))) (push (make-ftoken :eof nil r line) out))
      (nreverse out))))

(defun fe-require-string-literal (e what)
  (if (and (typep e 'expr-literal)
           (typep (expr-literal-value e) 'value-string))
      (value-string-value (expr-literal-value e))
      (frontend-fail (format nil "~A expects a string literal" what)
                     :code "reader.syntax")))

(defun fe-require-island-literal (e what)
  "Accept quoted URIs and the explicit reader's unquoted URI atom.

The sexpr surface permits `file:/path` as an island atom.  It is still
tokenized by our reader (never the host reader), and converting that symbol
here preserves the same source contract as the brace surface."
  (typecase e
    (expr-literal (fe-require-string-literal e what))
    (expr-symbol (expr-symbol-name e))
    (t (frontend-fail (format nil "~A expects a string literal or URI atom" what)
                      :code "reader.syntax"))))
;;; ---------------------------------------------------------------------------
;;; Shared reader-level desugars

(defun fe-expr-name (e)
  (typecase e
    (expr-def (values (expr-def-name e) nil))
    (expr-defnode (values (expr-defnode-name e) nil))
    (expr-defvalue (values (expr-defvalue-name e) t))
    (expr-located (fe-expr-name (expr-located-expression e)))
    (t (values nil nil))))

(defun fe-check-block-defs (forms)
  (let ((seen (make-hash-table :test #'equal)))
    (dolist (e forms)
      (multiple-value-bind (name valuep) (fe-expr-name e)
        (when name
          (multiple-value-bind (old present) (gethash name seen)
            (when (and present (or old valuep))
              (frontend-fail (format nil "duplicate definition in block: ~A" name)
                             :code "reader.duplicate-definition"))
            (setf (gethash name seen) (or old valuep)))))))
  forms)

(defun fe-block-body (forms) (let ((forms (fe-check-block-defs forms)))
                               (if (= (length forms) 1) (first forms)
                                   (make-edo forms))))

(defun fe-desugar-and (forms)
  (if (null forms) (make-eliteral (make-vbool t))
      (if (null (cdr forms)) (first forms)
          (make-eif (first forms) (fe-desugar-and (cdr forms)) (make-eliteral (make-vbool nil))))))
(defun fe-desugar-or (forms)
  (if (null forms) (make-eliteral (make-vbool nil))
      (if (null (cdr forms)) (first forms)
          (make-eif (first forms) (make-eliteral (make-vbool t)) (fe-desugar-or (cdr forms))))))

(defun fe-quote-value-string (e)
  (labels ((p (x)
             (typecase x
               (expr-literal (let ((v (expr-literal-value x)))
                               (typecase v
                                 (value-nil "nil") (value-bool (if (value-bool-value v) "true" "false"))
                                 (value-int (princ-to-string (value-int-value v)))
                                 (value-float (format nil "~G" (value-float-value v)))
                                 (value-string (fe-string-escape (value-string-value v)))
                                 (value-keyword (concatenate 'string ":" (value-keyword-value v)))
                                 (t "<value>"))))
               (expr-symbol (expr-symbol-name x))
               (expr-apply (format nil "(~A~{ ~A~})" (p (expr-apply-function x)) (mapcar #'p (expr-apply-arguments x))))
               (expr-if (format nil "(if ~A ~A ~A)" (p (expr-if-condition x)) (p (expr-if-then x)) (p (expr-if-else x))))
               (t "<form>")))) (p e)))
(defun fe-desugar-assert (cond msg)
  (make-eif cond (make-eliteral (make-vnil))
            (make-eapply (make-esymbol "error")
                         (list (or msg (make-eliteral (make-vstring
                                                        (concatenate 'string "assertion failed: "
                                                                     (fe-quote-value-string cond)))))))))

(defun fe-assemble-fn (params ret body location)
  (let ((names (mapcar #'car params)) (checks nil))
    (dolist (p params)
      (when (cdr p) (push (make-elocated location (make-typed (make-esymbol (car p)) (cdr p))) checks)))
    (setf checks (nreverse checks))
    (let ((b (if ret (make-elocated location (make-typed body ret))
                 (make-elocated location body))))
      (values names (if checks (make-edo (append checks (list b))) b)))))

;;; ---------------------------------------------------------------------------
;;; S-expression parser

(defstruct (fe-parser (:constructor make-fe-parser (tokens source))) tokens source (pos 0))
(defun fe-cur (p) (aref (fe-parser-tokens p) (min (fe-parser-pos p) (1- (length (fe-parser-tokens p))))))
(defun fe-kind (p) (frontend-token-kind (fe-cur p)))
(defun fe-next (p) (prog1 (fe-cur p) (incf (fe-parser-pos p))))
 (defun fe-expect (p kind msg)
  (if (eq (fe-kind p) kind) (fe-next p)
      (let ((eofp (eq (fe-kind p) :eof)))
        (frontend-fail
         (if (and eofp (eq kind :lbrace))
             "expected '{', got <eof>"
             msg)
         :code (if eofp "reader.incomplete" "reader.syntax")
         :range (frontend-token-range (fe-cur p))
         :incomplete-p eofp))))
(defun fe-loc (token) (frontend-token-range token))
(defun fe-symbol-token (p)
  (let ((tok (fe-next p)))
    (if (member (frontend-token-kind tok) '(:symbol :keyword) :test #'eq)
        (frontend-token-value tok)
        (frontend-fail "expected symbol" :code "reader.syntax"
                       :range (frontend-token-range tok)))))

(defun fe-parse-seq (p closing)
  (let ((r nil))
    (loop until (eq (fe-kind p) closing) do
      (when (eq (fe-kind p) :eof)
        (frontend-fail (format nil "unterminated ~A" closing) :code "reader.incomplete"
                       :range (frontend-token-range (fe-cur p)) :incomplete-p t))
      (push (fe-parse-sexpr p) r))
    (fe-next p) (nreverse r)))

(defun fe-parse-param-list (p kind)
  (fe-expect p kind "expected parameter list")
  (let ((r nil))
    (loop until (eq (fe-kind p) (if (eq kind :lbracket) :rbracket :rparen)) do
      (when (eq (fe-kind p) :eof)
        (frontend-fail "unterminated parameter list"
                       :code "reader.incomplete"
                       :range (frontend-token-range (fe-cur p))
                       :incomplete-p t))
      (let ((name (fe-symbol-token p)) (ty nil))
        (when (eq (fe-kind p) :colon) (fe-next p) (setf ty (fe-parse-sexpr p)))
        (push (cons name ty) r)))
    (fe-next p) (nreverse r)))

(defun fe-parse-bindings (p)
  (let ((kind (fe-kind p)) (r nil))
    (unless (member kind '(:lbracket :lparen) :test #'eq) (frontend-fail "let requires binding vector" :code "reader.syntax"))
    (fe-next p)
    (let ((close (if (eq kind :lbracket) :rbracket :rparen)))
      (loop until (eq (fe-kind p) close) do
        (let ((name (fe-symbol-token p)) (ty nil))
          (when (eq (fe-kind p) :colon) (fe-next p) (setf ty (fe-parse-sexpr p)))
          (let ((v (fe-parse-sexpr p)))
            (push (cons name (if ty (make-typed v ty) v)) r))))
      (fe-next p) (nreverse r))))

 (defun fe-parse-pattern (p)
  (case (fe-kind p)
    (:symbol (let ((s (frontend-token-value (fe-next p))))
               (cond ((string= s "_") (make-pwildcard))
                     ((string= s "nil") (make-pliteral (make-vnil)))
                     ((string= s "true") (make-pliteral (make-vbool t)))
                     ((string= s "false") (make-pliteral (make-vbool nil)))
                     (t (make-pvariable s)))))
    (:number (make-pliteral (make-vint (frontend-token-value (fe-next p)))))
    (:float (make-pliteral (make-vfloat (frontend-token-value (fe-next p)))))
    (:string (make-pliteral (make-vstring (frontend-token-value (fe-next p)))))
    (:keyword (make-pliteral (make-vkeyword (frontend-token-value (fe-next p)))))
    (:lbracket
     (fe-next p) (let ((xs nil) (rest nil))
                    (loop until (eq (fe-kind p) :rbracket) do
                      (when (eq (fe-kind p) :eof)
                        (frontend-fail "unterminated list pattern"
                                       :code "reader.incomplete"
                                       :range (frontend-token-range (fe-cur p))
                                       :incomplete-p t))
                      (if (and (eq (fe-kind p) :symbol)
                               (fe-name-spread-p (frontend-token-value (fe-cur p))))
                          (setf rest (make-pvariable (subseq (frontend-token-value (fe-next p)) 3)))
                          (push (fe-parse-pattern p) xs)))
                    (fe-next p) (make-plist (nreverse xs) rest)))
    (:lparen
     (fe-next p)
     (when (eq (fe-kind p) :eof)
       (frontend-fail "unterminated pattern list"
                      :code "reader.incomplete"
                      :range (frontend-token-range (fe-cur p))
                      :incomplete-p t))
     (let ((head (fe-symbol-token p)))
       (cond ((string= head "list")
              (let ((xs nil) (rest nil))
                (loop until (eq (fe-kind p) :rparen) do
                  (when (eq (fe-kind p) :eof)
                    (frontend-fail "unterminated list pattern"
                                   :code "reader.incomplete"
                                   :range (frontend-token-range (fe-cur p))
                                   :incomplete-p t))
                  (if (and (eq (fe-kind p) :symbol) (string= (frontend-token-value (fe-cur p)) "."))
                      (progn (fe-next p) (setf rest (fe-parse-pattern p)))
                      (push (fe-parse-pattern p) xs)))
                (fe-next p) (make-plist (nreverse xs) rest)))
             ((string= head "tagged")
              (let ((tag (fe-symbol-token p)) (xs nil))
                (loop until (eq (fe-kind p) :rparen) do
                  (when (eq (fe-kind p) :eof)
                    (frontend-fail "unterminated tagged pattern"
                                   :code "reader.incomplete"
                                   :range (frontend-token-range (fe-cur p))
                                   :incomplete-p t))
                  (push (fe-parse-pattern p) xs))
                (fe-next p) (make-ptagged tag (nreverse xs))))
             (t (frontend-fail "pattern list must be (list ...) or (tagged ...)" :code "reader.syntax")))))
    (t (frontend-fail "unexpected token in pattern" :code "reader.syntax" :range (frontend-token-range (fe-cur p))))))

(defun fe-name-spread-p (s) (and (>= (length s) 3) (string= s "..." :end1 3)))

(defun fe-parse-qq (p)
  (case (fe-kind p)
    (:unquote
     (fe-next p)
     (make-eapply (make-esymbol "list")
                  (list (make-equote (make-esymbol "unquote"))
                        (fe-parse-sexpr p))))
    (:unquote-splicing
     (fe-next p)
     (make-eapply (make-esymbol "list")
                  (list (make-equote (make-esymbol "unquote-splicing"))
                        (fe-parse-sexpr p))))
    (:quote (fe-next p) (make-equote (fe-parse-qq p)))
    (:lbrace
     (fe-next p)
     (let ((items nil))
       (loop until (eq (fe-kind p) :rbrace) do
         (when (eq (fe-kind p) :eof)
           (frontend-fail "unterminated quasiquote map"
                          :code "reader.incomplete"
                          :range (frontend-token-range (fe-cur p))
                          :incomplete-p t))
         (push (fe-parse-qq p) items))
       (when (oddp (length items))
         (frontend-fail "quasiquote map requires key/value pairs"
                        :code "reader.syntax"
                        :range (frontend-token-range (fe-cur p))))
       (fe-next p)
       (make-eapply (make-esymbol "hash-map") (nreverse items))))
    (:sharp-lbrace
     (fe-next p)
     (let ((items nil))
       (loop until (eq (fe-kind p) :rbrace) do
         (when (eq (fe-kind p) :eof)
           (frontend-fail "unterminated quasiquote set"
                          :code "reader.incomplete"
                          :range (frontend-token-range (fe-cur p))
                          :incomplete-p t))
         (push (fe-parse-qq p) items))
       (fe-next p)
       (make-eapply (make-esymbol "hash-set") (nreverse items))))
    (:quasiquote
     (fe-next p)
     (make-eapply (make-esymbol "quasiquote") (list (fe-parse-qq p))))
    (:lparen
     (fe-next p)
     (let ((items nil))
       (loop until (eq (fe-kind p) :rparen) do
         (when (eq (fe-kind p) :eof)
           (frontend-fail "unterminated quasiquote list"
                          :code "reader.incomplete"
                          :range (frontend-token-range (fe-cur p))
                          :incomplete-p t))
         (push (fe-parse-qq p) items))
       (fe-next p)
       (reduce (lambda (x acc)
                 (make-eapply (make-esymbol "cons") (list x acc)))
               (nreverse items) :from-end t
               :initial-value (make-equote (make-eliteral (make-vnil))))))
    (:lbracket
     (fe-next p)
     (let ((items nil))
       (loop until (eq (fe-kind p) :rbracket) do
         (when (eq (fe-kind p) :eof)
           (frontend-fail "unterminated quasiquote vector"
                          :code "reader.incomplete"
                          :range (frontend-token-range (fe-cur p))
                          :incomplete-p t))
         (push (fe-parse-qq p) items))
       (fe-next p)
       (make-eapply (make-esymbol "vector") (nreverse items))))
    (t (make-equote (fe-parse-sexpr p)))))

(defun fe-bbinding-name (p)
  (if (and (plusp *frontend-qq-parse-depth*)
           (eq (fe-bkind p) :name)
           (string= (frontend-token-value (fe-bcur p)) "unquote"))
      (let ((saved (fe-bparser-pos p)))
        (fe-bnext p)
        (if (eq (fe-bkind p) :lparen)
            (progn
              (fe-bnext p)
              (let* ((argument (fe-bexpr p t nil))
                     (expression
                       (progn
                         (fe-bskip-lines p)
                         (fe-bexpect p :rparen
                                     "expected ')' after unquote name")
                         (make-eapply (make-esymbol "unquote")
                                      (list argument))))
                     (name (format nil "~Cqq-name-~D"
                                   (code-char 0)
                                   (hash-table-count
                                    *frontend-qq-name-expressions*))))
                (setf (gethash name *frontend-qq-name-expressions*)
                      expression)
                name))
            (progn
              (setf (fe-bparser-pos p) saved)
              (fe-bname p))))
      (fe-bname p)))

(defun fe-parse-list (p)
  (fe-next p)
  (when (eq (fe-kind p) :rparen) (fe-next p) (return-from fe-parse-list (make-eliteral (make-vnil))))
  (when (eq (fe-kind p) :eof)
    (frontend-fail "unterminated list" :code "reader.incomplete"
                   :range (frontend-token-range (fe-cur p))
                   :incomplete-p t))
  (unless (eq (fe-kind p) :symbol)
    (let ((fn (fe-parse-sexpr p)))
      (return-from fe-parse-list
        (make-eapply fn (fe-parse-seq p :rparen)))))
  (let ((head (fe-symbol-token p)))
    (labels ((forms () (fe-parse-seq p :rparen))
             (one () (fe-parse-sexpr p))
             (body () (fe-block-body (forms))))
      (cond
        ((string= head "def")
         (let ((location (fe-loc (fe-cur p))))
           (if (eq (fe-kind p) :lparen)
               (let* ((all (fe-parse-param-list p :lparen))
                      (name (car (car all))) (params (cdr all))
                      (ret (when (eq (fe-kind p) :colon) (fe-next p) (one)))
                      (b (body)))
                 (multiple-value-bind (ns bb) (fe-assemble-fn params ret b location)
                   (make-edef name ns bb)))
               (let ((name (fe-symbol-token p)) (v (one)))
                 (forms) (make-edefvalue name (make-elocated location v))))))
        ((string= head "fn")
         (let ((location (fe-loc (fe-cur p))))
           (let* ((params (fe-parse-param-list p (fe-kind p)))
                  (ret (when (eq (fe-kind p) :colon) (fe-next p) (one)))
                  (b (body)))
             (multiple-value-bind (ns bb) (fe-assemble-fn params ret b location)
               (make-efn ns bb)))))
        ((string= head "if") (let ((a (one)) (b (one)) (c (if (eq (fe-kind p) :rparen) (make-eliteral (make-vnil)) (one)))) (forms) (make-eif a b c)))
        ((string= head "let") (make-elet (fe-parse-bindings p) (body)))
        ((string= head "let*")
         (let ((items (progn (fe-expect p :lbracket "let* requires binding vector") (fe-parse-seq p :rbracket))) (bs nil))
           (loop while items do
             (unless (cdr items) (frontend-fail "let* bindings must be pairs" :code "reader.syntax"))
             (let ((n (pop items)) (v (pop items)))
               (unless (typep n 'expr-symbol)
                 (frontend-fail "let* binding name must be symbol" :code "reader.syntax"))
               (push (cons (expr-symbol-name n) v) bs)))
           (make-eletstar (nreverse bs) (body))))
        ((string= head "and") (fe-desugar-and (forms)))
        ((string= head "or") (fe-desugar-or (forms)))
        ((string= head "quote") (let ((x (one))) (forms) (make-equote x)))
        ((string= head "force") (let ((x (one))) (forms) (make-eforce x)))
        ((string= head "delay") (let ((x (one))) (forms) (make-edelay x)))
        ((string= head "node") (let ((x (one))) (forms) (make-enode x)))
        ((string= head "defnode")
         (let ((location (fe-loc (fe-cur p))))
           (if (eq (fe-kind p) :lparen)
               (let* ((all (fe-parse-param-list p :lparen))
                      (name (car (car all))) (params (cdr all))
                      (ret (when (eq (fe-kind p) :colon) (fe-next p) (one)))
                      (b (body)))
                 (multiple-value-bind (ns bb) (fe-assemble-fn params ret b location)
                   (make-edefnode name ns bb)))
               (let ((name (fe-symbol-token p)) (v (one)))
                 (forms) (make-edefvalue name (make-elocated location (make-enode v)))))))
        ((string= head "do") (make-edo (fe-check-block-defs (forms))))
        ((string= head "perform")
         (let ((name (fe-symbol-token p)))
           (make-eperform name (forms))))
        ((string= head "with-handler")
         (let ((items (progn (fe-expect p :lbracket "with-handler requires handler vector") (fe-parse-seq p :rbracket))) (hs nil))
           (loop while items do
             (unless (cdr items) (frontend-fail "handler specs must be pairs" :code "reader.syntax"))
             (let ((n (pop items)) (v (pop items)))
               (push (cons (if (typep n 'expr-symbol)
                               (expr-symbol-name n)
                               (value-keyword-value (expr-literal-value n)))
                           v)
                     hs)))
           (make-ewith-handler (nreverse hs) (body))))
        ((string= head "module") (make-emodule (fe-check-block-defs (forms))))
        ((string= head "import") (let ((x (one))) (forms) (make-eimport x)))
        ((string= head "load")
         (let ((x (one))) (forms) (make-eload (fe-require-string-literal x "load"))))
        ((string= head "load-module")
         (let ((x (one))) (forms) (make-eloadmodule (fe-require-string-literal x "load-module"))))
        ((string= head "island")
         (let ((u (one)) (pin (unless (eq (fe-kind p) :rparen) (one))))
           (forms)
           (make-eisland (fe-require-island-literal u "island URI")
                         (and pin (fe-require-string-literal pin "island pin")))))
        ((string= head "with-config") (make-ewith-config (one) (body)))
        ((string= head "config") (let ((k (one)) (d (unless (eq (fe-kind p) :rparen) (one)))) (forms) (make-econfig k d)))
        ((string= head "assert") (let ((c (one)) (m (unless (eq (fe-kind p) :rparen) (one)))) (forms) (fe-desugar-assert c m)))
        ((string= head "match")
         (let ((s (one)) (arms nil))
           (loop until (eq (fe-kind p) :rparen) do
             (fe-expect p :lparen "match arm must be parenthesized")
             (let ((pat (fe-parse-pattern p)) (g (when (and (eq (fe-kind p) :symbol) (string= (frontend-token-value (fe-cur p)) "if")) (fe-next p) (one))) (b (one)))
               (fe-expect p :rparen "match arm must close") (push (list pat g b) arms)))
           (fe-next p) (make-ematch s (nreverse arms))))
        ((string= head "typed")
         (let ((x (one)) (ty (one))) (forms) (make-typed x ty)))
        (t (let ((args (forms))) (make-eapply (make-esymbol head) args)))))))

(defun fe-parse-sexpr (p)
  (let ((tok (fe-cur p)))
    (case (frontend-token-kind tok)
      (:quote (fe-next p) (make-equote (fe-parse-sexpr p)))
      (:quasiquote (fe-next p) (make-eapply (make-esymbol "quasiquote") (list (fe-parse-qq p))))
      (:unquote (fe-next p) (make-eapply (make-esymbol "unquote") (list (fe-parse-sexpr p))))
      (:unquote-splicing (fe-next p) (make-eapply (make-esymbol "unquote-splicing") (list (fe-parse-sexpr p))))
      (:string (fe-next p) (make-eliteral (make-vstring (frontend-token-value tok))))
      (:number (fe-next p) (make-eliteral (make-vint (frontend-token-value tok))))
      (:float (fe-next p) (make-eliteral (make-vfloat (frontend-token-value tok))))
      (:keyword (fe-next p) (make-eliteral (make-vkeyword (frontend-token-value tok))))
      (:island (fe-next p) (make-eliteral (make-vstring (frontend-token-value tok))))
      (:symbol
       (fe-next p)
       (let ((s (frontend-token-value tok)))
         (cond ((member s '("nan" "inf" "-inf") :test #'string=)
                (make-eliteral (make-vfloat (fe-special-float s))))
               ((string= s "nil") (make-eliteral (make-vnil)))
               ((string= s "true") (make-eliteral (make-vbool t)))
               ((string= s "false") (make-eliteral (make-vbool nil)))
               (t (make-esymbol s)))))
      (:lparen (fe-parse-list p))
      (:lbracket (fe-next p) (make-eapply (make-esymbol "vector") (fe-parse-seq p :rbracket)))
      (:lbrace (fe-next p) (let ((xs (fe-parse-seq p :rbrace)) (args nil)) (loop while xs do (unless (cdr xs) (frontend-fail "map requires key/value pairs" :code "reader.syntax")) (push (pop xs) args) (push (pop xs) args)) (make-eapply (make-esymbol "hash-map") (nreverse args))))
      (:sharp-lbrace (fe-next p) (make-eapply (make-esymbol "hash-set") (fe-parse-seq p :rbrace)))
      (otherwise
       (if (eq (frontend-token-kind tok) :eof)
           (frontend-fail "unexpected end of input"
                          :code "reader.incomplete"
                          :range (frontend-token-range tok)
                          :incomplete-p t)
           (frontend-fail "unexpected token" :code "reader.syntax"
                          :range (frontend-token-range tok)))))))

 (defun fe-read-sexpr (text &key (source "<?>"))
  (let* ((tokens (coerce (fe-tokenize-sexpr text :source source) 'vector))
         (p (make-fe-parser tokens source))
         (forms nil))
    (loop until (eq (fe-kind p) :eof) do
      (let ((start-pos (fe-parser-pos p))
            (tok (fe-cur p)))
        (handler-case
            (push (make-elocated (fe-loc tok) (fe-parse-sexpr p)) forms)
          (frontend-error (condition)
            ;; Incomplete input is anchored at its last significant token.
            ;; Search only inside this top-level form so a prior complete form
            ;; cannot steal the diagnostic line.
            (if (frontend-error-incomplete-p condition)
                (frontend-fail
                 (frontend-error-message condition)
                 :code (frontend-error-code condition)
                 :range
                 (or (loop for i downfrom (1- (length tokens))
                           to start-pos
                           unless (eq (frontend-token-kind (aref tokens i))
                                      :eof)
                           return (frontend-token-range (aref tokens i)))
                     (frontend-token-range tok))
                 :incomplete-p t)
                (error condition))))))
    (nreverse forms)))

;;; ---------------------------------------------------------------------------
;;; Brace lexer and Pratt parser

(defun fe-tokenize-brace (text &key (source "<?>"))
  (let ((i 0) (line 1) (col 1) (n (length text)) (out nil) (last-end -1))
    (labels ((adv () (let ((c (char text i))) (incf i) (if (char= c #\Newline) (progn (incf line) (setf col 1)) (incf col))))
             (add (kind val so sl sc glued) (let ((r (frontend-range source so sl sc i line col))) (push (make-ftoken kind val r sl glued) out) (setf last-end i)))
             (name () (let ((b (make-string-output-stream))) (loop while (and (< i n) (fe-name-char-p (char text i) :brace t)) do (write-char (char text i) b) (adv)) (get-output-stream-string b)))
             (str () (multiple-value-bind (s ni nl nc r) (fe-read-string source text i line col) (setf i ni line nl col nc) (values s r)))
             (fstr ()
               ;; Keep interpolation source raw; it is re-tokenized by the
               ;; brace reader, so no host reader or symbol interning occurs.
               (adv) (when (or (>= i n) (char/= (char text i) #\"))
                       (frontend-fail "f-string requires opening quote"
                                      :code "reader.syntax"
                                      :range (frontend-point source i line col)))
               (adv)
               (let ((parts nil) (lit (make-string-output-stream)))
                 (labels ((flush ()
                            (let ((s (get-output-stream-string lit)))
                              (when (plusp (length s))
                                (push (cons :lit s) parts)))))
                   (loop
                     (when (>= i n)
                       (frontend-fail "unterminated f-string"
                                      :code "reader.incomplete"
                                      :range (frontend-point source i line col)
                                      :incomplete-p t))
                     (let ((c (char text i)))
                       (cond
                         ((char= c #\")
                          (flush) (adv) (return (nreverse parts)))
                         ((char= c #\\)
                          (adv)
                          (when (>= i n)
                            (frontend-fail "unterminated f-string escape"
                                           :code "reader.incomplete"
                                           :incomplete-p t))
                          (let ((e (char text i)))
                            (write-char (case e (#\n #\Newline) (#\t #\Tab)
                                               (#\\ #\\) (#\" #\") (t e)) lit)
                            (adv)))
                         ((and (char= c #\{) (< (1+ i) n)
                               (char= (char text (1+ i)) #\{))
                          (write-char #\{ lit) (adv) (adv))
                         ((and (char= c #\}) (< (1+ i) n)
                               (char= (char text (1+ i)) #\}))
                          (write-char #\} lit) (adv) (adv))
                         ((char= c #\{)
                          (flush) (adv)
                          (let ((depth 0) (buf (make-string-output-stream))
                                (quoted nil) (escaped nil))
                            (loop
                              (when (>= i n)
                                (frontend-fail "unterminated f-string interpolation"
                                               :code "reader.incomplete"
                                               :range (frontend-point source i line col)
                                               :incomplete-p t))
                              (let ((d (char text i)))
                                (cond
                                  ((and quoted escaped) (setf escaped nil) (write-char d buf) (adv))
                                  ((and quoted (char= d #\\)) (setf escaped t) (write-char d buf) (adv))
                                  ((char= d #\") (setf quoted (not quoted)) (write-char d buf) (adv))
                                  ((not quoted) (cond
                                                  ((char= d #\})
                                                   (if (zerop depth)
                                                       (progn (adv) (return))
                                                       (progn
                                                         (decf depth)
                                                         (write-char d buf)
                                                         (adv))))
                                                  ((char= d #\{)
                                                   (incf depth) (write-char d buf) (adv))
                                                  (t (write-char d buf) (adv))))
                                  (t (write-char d buf) (adv)))))
                            (let ((raw (string-trim '(#\Space #\Tab #\Newline #\Return)
                                                    (get-output-stream-string buf))))
                              (when (zerop (length raw))
                                (frontend-fail "empty interpolation in f-string"
                                               :code "reader.syntax"))
                              (push (cons :hole raw) parts))))
                         ((char= c #\}) (frontend-fail "unmatched '}' in f-string"
                                                        :code "reader.syntax"))
                         (t (write-char c lit) (adv)))))))))
      (loop while (< i n) do
        (let ((so i) (sl line) (sc col) (c (char text i)) (glued (= i last-end)))
          (cond
            ((member c '(#\Space #\Tab #\Return) :test #'char=) (adv))
            ((char= c #\Newline) (adv) (add :newline nil so sl sc glued))
            ((char= c #\#) (adv) (loop while (and (< i n) (char/= (char text i) #\Newline)) do (adv)))
            ((char= c #\;) (adv) (add :semi nil so sl sc glued))
            ((char= c #\,) (adv) (add :comma nil so sl sc glued))
            ((member c '(#\( #\) #\[ #\] #\{ #\}) :test #'char=)
             (adv) (add (case c (#\( :lparen) (#\) :rparen) (#\[ :lbracket) (#\] :rbracket) (#\{ :lbrace) (#\} :rbrace)) nil so sl sc glued))
            ((char= c #\:) (adv) (if (and (< i n) (fe-name-char-p (char text i) :brace t)) (add :keyword (name) so sl sc glued) (add :colon nil so sl sc glued)))
            ((char= c #\<) (adv) (if (and (< i n) (member (char text i) '(#\= #\-) :test #'char=)) (let ((d (char text i))) (adv) (add :name (concatenate 'string (string c) (string d)) so sl sc glued)) (add :name "<" so sl sc glued)))
            ((and (char= c #\f) (< (1+ i) n) (char= (char text (1+ i)) #\"))
             (add :fstring (fstr) so sl sc glued))
            ((char= c #\")
             (multiple-value-bind (s r) (str)
               (declare (ignore r))
               ;; String CONTENT is data: a digit-leading string such as a
               ;; content hash is never a malformed number literal.
               (add :string s so sl sc glued)))
            (t
             (let ((s (name)))
               (when (zerop (length s))
                 (frontend-fail (format nil "unexpected character '~A'" c)
                                :code "reader.character"
                                :range (frontend-point source i line col)))
               (when (and (fe-numeric-start-p s) (not (fe-number-token-p s)))
                 (fe-parse-number
                  s :range (frontend-range source so sl sc i line col)))
               (add (if (fe-number-token-p s)
                        (if (or (find #\. s) (find #\e s :test #'char-equal))
                            :float :number)
                        :name)
                    (if (fe-number-token-p s)
                        (fe-parse-number
                         s :range (frontend-range source so sl sc i line col))
                        s)
                    so sl sc glued))))))
      (push (make-ftoken :eof nil (frontend-point source i line col) line nil) out)
      (nreverse out))))

(defstruct (fe-bparser (:constructor make-fe-bparser (tokens source))) tokens source (pos 0))
(defun fe-bcur (p)
  (aref (fe-bparser-tokens p)
        (min (fe-bparser-pos p) (1- (length (fe-bparser-tokens p))))))
(defun fe-bskip-nl (p)
  (loop while (member (fe-bkind p) '(:newline :semi :comma) :test #'eq)
        do (fe-bnext p)))
(defun fe-bkind (p) (frontend-token-kind (fe-bcur p)))
 (defun fe-bskip-lines (p)
  (loop while (eq (fe-bkind p) :newline)
        do (fe-bnext p)))
(defun fe-bnext (p) (prog1 (fe-bcur p) (incf (fe-bparser-pos p))))
(defun fe-bexpect (p k msg)
  (if (eq (fe-bkind p) k) (fe-bnext p)
      (let ((eofp (eq (fe-bkind p) :eof)))
        (frontend-fail
         (if (and eofp (eq k :lbrace))
             "expected '{', got <eof>"
             msg)
         :code (if eofp "reader.incomplete" "reader.syntax")
         :range (frontend-token-range (fe-bcur p))
         :incomplete-p eofp))))
(defun fe-b-infix-p (p ops)
  (and (eq (fe-bkind p) :name) (member (frontend-token-value (fe-bcur p)) ops :test #'string=)
       (not (frontend-token-glued (fe-bcur p)))
       (let ((q (aref (fe-bparser-tokens p) (min (1+ (fe-bparser-pos p)) (1- (length (fe-bparser-tokens p)))))))
         (not (frontend-token-glued q)))))
(defun fe-bname (p)
  (let ((tok (fe-bnext p)))
    (if (eq (frontend-token-kind tok) :name)
        (frontend-token-value tok)
        (frontend-fail "expected name" :code "reader.syntax"
                       :range (frontend-token-range tok)))))
(defun fe-bargs (p &key handler-p)
  "Read a call's argument list, lowering spread segments to APPLY inputs.

The first return value is the ordinary argument list when no spread occurs.
When spread occurs it is the list of list segments and spread expressions
expected by the APPLY primitive; the second return value records that case.
Keeping the distinction here lets spread-free calls retain their exact AST
shape (and therefore their hashes)."
  (fe-bskip-lines p)
  (if (eq (fe-bkind p) :rparen)
      (progn (fe-bnext p) (values nil nil))
      (let ((plain nil) (segments nil) (spreadp nil))
        (labels ((flush-plain ()
                   (when plain
                     (push (make-eapply (make-esymbol "list")
                                        (nreverse plain))
                           segments)
                     (setf plain nil)))
                 (read-spread ()
                   (let* ((token (fe-bnext p))
                          (name (frontend-token-value token))
                          (tail (subseq name 3)))
                     (if (plusp (length tail))
                         (make-esymbol tail)
                         (progn
                           (when (member (fe-bkind p) '(:comma :rparen :eof)
                                         :test #'eq)
                             (frontend-fail
                              "spread requires an expression"
                              :code (if (eq (fe-bkind p) :eof)
                                        "reader.incomplete" "reader.syntax")
                              :range (frontend-token-range (fe-bcur p))
                              :incomplete-p (eq (fe-bkind p) :eof)))
                           (fe-bexpr p t nil))))))
          (loop
            (if (and (eq (fe-bkind p) :name)
                     (fe-name-spread-p (frontend-token-value (fe-bcur p))))
                (progn
                  (flush-plain)
                  (setf spreadp t)
                  (push (read-spread) segments))
                (push (fe-bexpr p t nil) plain))
            ;; Newlines are transparent inside argument parentheses, including
            ;; before the closing delimiter.
            (fe-bskip-lines p)
            (cond
              ((eq (fe-bkind p) :comma)
               (fe-bnext p) (fe-bskip-lines p)
               (when (and handler-p (eq (fe-bkind p) :rparen))
                 (frontend-fail "handler name must be a symbol or keyword"
                                :code "reader.syntax")))
              ((eq (fe-bkind p) :rparen)
               (fe-bnext p)
               (if spreadp
                   (progn
                     (flush-plain)
                     (return (values (nreverse segments) t)))
                   (return (values (nreverse plain) nil))))
              (t
               (frontend-fail "expected ',' or ')'"
                              :code (if (eq (fe-bkind p) :eof)
                                        "reader.incomplete" "reader.syntax")
                              :range (frontend-token-range (fe-bcur p))
                              :incomplete-p (eq (fe-bkind p) :eof)))))))))

(defun fe-bargs-no-spread (p &key handler-p)
  (multiple-value-bind (args spreadp) (fe-bargs p :handler-p handler-p)
    (when spreadp
      (frontend-fail "spread is only supported in function calls"
                     :code "reader.syntax"))
    args))

(defun fe-bmap (p)
  (fe-bnext p) (fe-bskip-lines p)
  (if (eq (fe-bkind p) :rbrace) (progn (fe-bnext p) (make-eapply (make-esymbol "hash-map") nil))
      (let ((entries nil) (spread nil))
        (loop
          (if (and (eq (fe-bkind p) :name) (fe-name-spread-p (frontend-token-value (fe-bcur p))))
              (progn (setf spread t) (let ((s (subseq (fe-bname p) 3))) (push (if (plusp (length s)) (make-esymbol s) (fe-bexpr p t nil)) entries)))
              (let ((k (fe-bexpr p t nil)))
                (unless (fe-b-infix-p p '("->"))
                  (frontend-fail "expected '->' between map key and value"
                                 :code (if (eq (fe-bkind p) :eof)
                                           "reader.incomplete" "reader.syntax")
                                 :range (frontend-token-range (fe-bcur p))
                                 :incomplete-p (eq (fe-bkind p) :eof)))
                (fe-bnext p) (push (list k (fe-bexpr p t nil)) entries)))
          (fe-bskip-lines p)
          (cond ((eq (fe-bkind p) :comma) (fe-bnext p) (fe-bskip-lines p))
                ((eq (fe-bkind p) :rbrace)
                 (fe-bnext p)
                 (let* ((es (nreverse entries))
                        (result
                          (if (not spread)
                              (make-eapply
                               (make-esymbol "hash-map")
                               (mapcan (lambda (x)
                                         (if (listp x) x (list x)))
                                       es))
                              (let ((acc (if (listp (first es))
                                             (make-eapply (make-esymbol "hash-map") nil)
                                             (first es))))
                                (dolist (x (if (listp (first es))
                                               es
                                               (rest es)))
                                  (setf acc
                                        (if (listp x)
                                            (make-eapply
                                             (make-esymbol "map-insert")
                                             (list acc (first x) (second x)))
                                            (make-eapply
                                             (make-esymbol "map-merge")
                                             (list acc x)))))
                                acc))))
                   (when spread
                     (setf (gethash result *frontend-map-spread-expressions*) t))
                   (return result)))
                (t (frontend-fail "expected ',' or '}'"
                                  :code (if (eq (fe-bkind p) :eof)
                                            "reader.incomplete" "reader.syntax")
                                  :range (frontend-token-range (fe-bcur p))
                                  :incomplete-p (eq (fe-bkind p) :eof))))))))

(defun fe-blist (p)
  (fe-bnext p) (fe-bskip-lines p)
  (if (eq (fe-bkind p) :rbracket)
      (progn
        (fe-bnext p)
        (let ((r (make-eapply (make-esymbol "list") nil)))
          (setf (gethash r *frontend-list-literal-expressions*) t)
          r))
      (let ((items nil))
        (loop
          (let ((spreadp (and (eq (fe-bkind p) :name)
                              (fe-name-spread-p (frontend-token-value (fe-bcur p)))))
                (item nil))
            (if spreadp
                (progn
                  (let ((s (subseq (fe-bname p) 3)))
                    (setf item (if (plusp (length s))
                                   (make-esymbol s)
                                   (fe-bexpr p t nil))))
                  (push (cons :spread item) items))
                (push (cons :elem (fe-bexpr p t nil)) items)))
          (fe-bskip-lines p)
          (cond
            ((eq (fe-bkind p) :comma) (fe-bnext p) (fe-bskip-lines p))
            ((eq (fe-bkind p) :rbracket)
             (fe-bnext p)
             (setf items (nreverse items))
             (let ((where (cl:position :spread items :key #'car)))
               (if (null where)
                   (let ((r (make-eapply (make-esymbol "list") (mapcar #'cdr items))))
                     (setf (gethash r *frontend-list-literal-expressions*) t)
                     (return r))
                   (progn
                     (unless (= where (1- (length items)))
                       (frontend-fail "list spread must be the final element"
                                      :code "reader.syntax"))
                     (let* ((tail (cdar (last items)))
                            (result
                              (reduce (lambda (e acc)
                                        (make-eapply (make-esymbol "cons")
                                                     (list (cdr e) acc)))
                                      (subseq items 0 where)
                                      :from-end t :initial-value tail)))
                       (setf (gethash result *frontend-list-spread-expressions*) t)
                       (return result)))))
            (t (frontend-fail "expected ',' or ']'"
                              :code (if (eq (fe-bkind p) :eof)
                                        "reader.incomplete" "reader.syntax")
                              :range (frontend-token-range (fe-bcur p))
                              (incomplete-p (eq (fe-bkind p) :eof))))))))))
(defun fe-bblock (p &key return-forms)
  ;; A block opener may be separated from its head by newlines/semicolons.
  (fe-bskip-nl p)
  (fe-bexpect p :lbrace "expected '{'") (fe-bskip-nl p)
  (let ((xs nil))
    (loop until (eq (fe-bkind p) :rbrace) do
      (when (eq (fe-bkind p) :eof)
        (frontend-fail "unterminated block" :code "reader.incomplete"
                       :range (frontend-token-range (fe-bcur p))
                       :incomplete-p t))
      (push (fe-bexpr p nil nil) xs)
      (cond
        ((eq (fe-bkind p) :eof)
         ;; An expression can finish without a separator immediately before
         ;; EOF.  It is still an incomplete block: preserve the EOF token's
         ;; source point so nested bodies report a useful non-NIL range.
         (frontend-fail "unterminated block" :code "reader.incomplete"
                        :range (frontend-token-range (fe-bcur p))
                        :incomplete-p t))
        ((not (member (fe-bkind p) '(:newline :semi :rbrace) :test #'eq))
         (frontend-fail "expected newline or ';' between statements"
                        :code "reader.syntax")))
      (fe-bskip-nl p))
    (fe-bnext p)
    (let ((forms (nreverse xs)))
      (if return-forms forms (fe-block-body forms)))))

(defun fe-bpattern (p)
  (let ((tok (fe-bcur p)))
    (case (frontend-token-kind tok)
      (:name (fe-bnext p)
             (if (string= (frontend-token-value tok) "_")
                 (make-pwildcard)
                 (make-pvariable (frontend-token-value tok))))
      (:number (fe-bnext p) (make-pliteral (make-vint (frontend-token-value tok))))
      (:float (fe-bnext p) (make-pliteral (make-vfloat (frontend-token-value tok))))
      (:string (fe-bnext p) (make-pliteral (make-vstring (frontend-token-value tok))))
      (:keyword (fe-bnext p) (make-pliteral (make-vkeyword (frontend-token-value tok))))
      (:lbracket
       (fe-bnext p) (fe-bskip-lines p)
       (if (eq (fe-bkind p) :rbracket)
           (progn (fe-bnext p) (make-plist nil nil))
           (let ((patterns nil) (rest nil))
             (loop
               (when (eq (fe-bkind p) :eof)
                 (frontend-fail "unterminated list pattern"
                                :code "reader.incomplete"
                                :range (frontend-token-range (fe-bcur p))
                                :incomplete-p t))
               (if (and (eq (fe-bkind p) :name)
                        (fe-name-spread-p (frontend-token-value (fe-bcur p))))
                   (let ((s (subseq (fe-bname p) 3)))
                     (when (zerop (length s))
                       (frontend-fail "spread pattern must name a remainder"
                                      :code "reader.syntax"))
                     (setf rest (if (string= s "_") (make-pwildcard)
                                    (make-pvariable s)))
                     (fe-bskip-lines p)
                     (fe-bexpect p :rbracket "expected ']' after spread pattern")
                     (return))
                   (push (fe-bpattern p) patterns))
               (cond ((eq (fe-bkind p) :comma) (fe-bnext p) (fe-bskip-lines p))
                     ((eq (fe-bkind p) :rbracket) (fe-bnext p) (return))
                     ((eq (fe-bkind p) :eof)
                      (frontend-fail "unterminated list pattern"
                                     :code "reader.incomplete"
                                     :range (frontend-token-range (fe-bcur p))
                                     :incomplete-p t))
                     (t (frontend-fail "expected ',' or ']' in list pattern"
                                       :code "reader.syntax"))))
             (make-plist (nreverse patterns) rest))))
      (:lparen
       (fe-bnext p) (fe-bskip-lines p)
       (when (eq (fe-bkind p) :eof)
         (frontend-fail "unterminated tagged pattern"
                        :code "reader.incomplete"
                        :range (frontend-token-range (fe-bcur p))
                        :incomplete-p t))
       (if (eq (fe-bkind p) :keyword)
           (let ((tag (frontend-token-value (fe-bnext p))) (xs nil))
             (loop
               (fe-bskip-lines p)
               (when (eq (fe-bkind p) :eof)
                 (frontend-fail "unterminated tagged pattern"
                                :code "reader.incomplete"
                                :range (frontend-token-range (fe-bcur p))
                                :incomplete-p t))
               (if (eq (fe-bkind p) :rparen)
                   (return)
                   (push (fe-bpattern p) xs)))
             (fe-bnext p) (make-ptagged tag (nreverse xs)))
           (let ((x (fe-bpattern p)))
             (fe-bskip-lines p)
             (fe-bexpect p :rparen "expected ')' after parenthesized pattern")
             x)))
      (otherwise (frontend-fail "invalid match pattern"
                                :code "reader.syntax"
                                :range (frontend-token-range tok))))))
(defun fe-blower-try (stmts)
  (labels ((app (name args) (make-eapply (make-esymbol name) args))
           (build (xs)
             (if (null xs) (make-eliteral (make-vkeyword "ok"))
                 (destructuring-bind (kind . rest) (first xs)
                   (if (eq kind :expr)
                       (if (null (cdr xs)) (car rest)
                           (make-edo (list (car rest) (build (cdr xs)))))
                       (let* ((name (first rest)) (rhs (second rest))
                              (tmp (make-esymbol (format nil "__try_~D" (length xs))))
                              (ok (make-elet (list (cons name
                                                         (app "car"
                                                              (list (app "cdr" (list tmp))))))
                                             (build (cdr xs)))))
                         (make-elet (list (cons (expr-symbol-name tmp) rhs))
                                    (make-eif (app "=" (list (app "car" (list tmp))
                                                             (make-eliteral (make-vkeyword "ok"))))
                                              ok tmp))))))))
    (build stmts)))

(defun fe-btry (p)
  (fe-bexpect p :lbrace "try requires '{'")
  (let ((stmts nil))
    (loop
      (fe-bskip-nl p)
      (when (eq (fe-bkind p) :rbrace) (fe-bnext p) (return))
      (when (eq (fe-bkind p) :eof)
        (frontend-fail "unterminated try block" :code "reader.incomplete"
                       :range (frontend-token-range (fe-bcur p)) :incomplete-p t))
      (if (and (eq (fe-bkind p) :name)
               (let ((q (aref (fe-bparser-tokens p)
                              (min (1+ (fe-bparser-pos p))
                                   (1- (length (fe-bparser-tokens p)))))))
                 (and (not (frontend-token-glued (fe-bcur p)))
                      (eq (frontend-token-kind q) :name)
                      (string= (frontend-token-value q) "<-")
                      (not (frontend-token-glued q)))))
          (let ((name (fe-bname p)))
            (fe-bnext p)
            (push (cons :bind (list name (fe-bexpr p nil nil))) stmts))
          (push (cons :expr (list (fe-bexpr p nil nil))) stmts))
      (unless (member (fe-bkind p) '(:newline :semi :rbrace) :test #'eq)
        (frontend-fail "expected newline or ';' in try block"
                       :code "reader.syntax"
                       :range (frontend-token-range (fe-bcur p))))
      (fe-bskip-nl p))
    (fe-blower-try (nreverse stmts))))
(defun fe-bparams (p)
  (fe-bexpect p :lparen "expected parameter list")
  (fe-bskip-lines p)
  (let ((out nil))
    (unless (eq (fe-bkind p) :rparen)
      (loop
        (when (eq (fe-bkind p) :eof)
          (frontend-fail "unterminated parameter list" :code "reader.incomplete"
                         :range (frontend-token-range (fe-bcur p))
                         :incomplete-p t))
        (push (fe-bname p) out)
        (fe-bskip-lines p)
        (if (eq (fe-bkind p) :comma)
            (progn (fe-bnext p) (fe-bskip-lines p))
            (return))))
    (fe-bexpect p :rparen "expected ')'")
    (nreverse out)))
(defun fe-bparams-annotated (p)
  (fe-bexpect p :lparen "expected parameter list")
  (fe-bskip-lines p)
  (let ((out nil))
    (unless (eq (fe-bkind p) :rparen)
      (loop
        (when (eq (fe-bkind p) :eof)
          (frontend-fail "unterminated parameter list" :code "reader.incomplete"
                         :range (frontend-token-range (fe-bcur p))
                         :incomplete-p t))
        (let ((name (fe-bname p)) (ty nil))
          (when (eq (fe-bkind p) :colon)
            (fe-bnext p) (fe-bskip-lines p)
            (setf ty (fe-bexpr p t nil)))
          (push (cons name ty) out))
        (fe-bskip-lines p)
        (cond ((eq (fe-bkind p) :comma) (fe-bnext p) (fe-bskip-nl p))
              ((eq (fe-bkind p) :rparen) (return))
              ((eq (fe-bkind p) :eof)
               (frontend-fail "unterminated parameter list"
                              :code "reader.incomplete"
                              :range (frontend-token-range (fe-bcur p))
                              :incomplete-p t))
              (t (frontend-fail "expected ',' or ')' after parameter"
                                :code "reader.syntax")))))
    (fe-bexpect p :rparen "expected ')'")
    (nreverse out)))

(defun fe-bret-annotation (p)
  (when (eq (fe-bkind p) :colon)
    (fe-bnext p) (fe-bskip-nl p) (fe-bexpr p t nil)))

(defun fe-special-float (name)
  (cond ((string= name "nan") (pp.kernel:decode-hex-float "nan"))
        ((string= name "inf") (pp.kernel:decode-hex-float "inf"))
        ((string= name "-inf") (pp.kernel:decode-hex-float "-inf"))
        (t nil)))
(defun fe-lower-needs (items)
  (let ((private-current (format nil "~Cneeds-current-capabilities" #\Null))
        (private-value (format nil "~Cneeds-value" #\Null)))
    (labels ((lower (item)
               (cond
                 ((and (typep item 'expr-apply)
                       (typep (expr-apply-function item) 'expr-symbol)
                       (string= (expr-symbol-name (expr-apply-function item))
                                "current-capabilities")
                       (null (expr-apply-arguments item)))
                  (make-eapply (make-esymbol private-current) nil))
                 ((and (typep item 'expr-apply)
                       (typep (expr-apply-function item) 'expr-symbol)
                       (= (length (expr-apply-arguments item)) 1)
                       (member (expr-symbol-name (expr-apply-function item))
                               '("fs.read" "fs.write" "fs.rw") :test #'string=))
                  (let* ((fn (expr-symbol-name (expr-apply-function item)))
                         (mode (if (string= fn "fs.read") "ro"
                                   (if (string= fn "fs.write") "wo" "rw"))))
                    (make-eapply
                     (make-esymbol "cap-restrict")
                     (list (make-eapply (make-esymbol private-current) nil)
                           (first (expr-apply-arguments item))
                           (make-eliteral (make-vkeyword mode))))))
                 (t (make-eapply (make-esymbol private-value) (list item))))))
      (mapcar #'lower items))))
(defun fe-qq-chain (items)
  (reduce (lambda (item tail)
            (make-eapply (make-esymbol "cons") (list item tail)))
          items :from-end t
          :initial-value (make-equote (make-eliteral (make-vnil)))))


(defun fe-brace-qq-pattern (p)
  "Encode a brace pattern in the value shape consumed by quotation."
  (typecase p
    (pattern-wildcard (make-equote (make-esymbol "_")))
    (pattern-variable
     (fe-qq-chain
      (list (make-equote (make-esymbol "var"))
            (make-equote (make-eliteral
                          (make-vstring (pattern-variable-name p)))))))
    (pattern-literal
     (fe-qq-chain
      (list (make-equote (make-esymbol "lit"))
            (make-equote (make-eliteral (pattern-literal-value p))))))
    (pattern-list
     (fe-qq-chain
      (list (make-equote (make-esymbol "list"))
            (fe-qq-chain (mapcar #'fe-brace-qq-pattern
                                 (pattern-list-patterns p)))
            (if (pattern-list-rest p)
                (fe-brace-qq-pattern (pattern-list-rest p))
                (make-equote (make-eliteral (make-vnil)))))))
    (pattern-tagged
     (fe-qq-chain
      (list (make-equote (make-esymbol "tagged"))
            (make-equote (make-eliteral
                          (make-vstring (pattern-tagged-tag p))))
            (fe-qq-chain (mapcar #'fe-brace-qq-pattern
                                 (pattern-tagged-patterns p))))))
    (t (frontend-fail (format nil "pattern type ~A is not representable in quasiquote"
                              (type-of p))
                      :code "reader.surface"))))

(defun fe-qq-bool-p (e value)
  (and (typep (fe-unloc e) 'expr-literal)
       (typep (expr-literal-value (fe-unloc e)) 'value-bool)
       (eql (value-bool-value (expr-literal-value (fe-unloc e))) value)))
(defun fe-brace-qq-form (e)
  "Lower one ordinary brace form into the quoted data used by quasiquote.

The brace parser has already built ordinary AST nodes.  Keep the distinction
between a generic call (a cons chain) and collection constructors: sexpr
quasiquote uses direct VECTOR/HASH-MAP/HASH-SET applications for the latter."
  (setf e (fe-unloc e))
  (let ((spread-p (gethash e *frontend-map-spread-expressions*)))
    (when spread-p
      (frontend-fail "map spread is not supported inside quasiquote"
                     :code "reader.syntax"))
    (labels ((q (x) (fe-brace-qq-form x))
             (sym (name) (make-equote (make-esymbol name)))
             (name-data (name)
               (if (stringp name)
                   (let ((expression
                           (gethash name *frontend-qq-name-expressions*)))
                     (if expression (q expression) (sym name)))
                   (q name)))
             (args (xs) (mapcar #'q xs))
             (spread-chain (root)
               (let ((head nil) (tail root))
                 (loop while (and (typep tail 'expr-apply)
                                  (typep (expr-apply-function tail) 'expr-symbol)
                                  (string= (expr-symbol-name
                                            (expr-apply-function tail)) "cons")
                                  (= (length (expr-apply-arguments tail)) 2))
                       do (push (first (expr-apply-arguments tail) ) head)
                          (setf tail (second (expr-apply-arguments tail))))
                 (values (nreverse head) tail)))
             (spread-tail (tail)
               (if (and (typep tail 'expr-apply)
                        (typep (expr-apply-function tail) 'expr-symbol)
                        (member (expr-symbol-name (expr-apply-function tail))
                                '("unquote" "splice") :test #'string=))
                   (first (expr-apply-arguments tail))
                   tail))
             (spread-root-p (root)
               (gethash root *frontend-list-spread-expressions*))
             (call (name xs) (fe-qq-chain (cons (sym name) (args xs)))))
    (typecase e
      ((or expr-symbol expr-literal) (make-equote e))
      (expr-quote (make-equote (fe-unloc (expr-quote-expression e))))
      (expr-if
       (cond
         ;; `and`/`or` are desugared before qq lowering. Recover their
         ;; source-level data shape so brace and sexpr quasiquote hash alike.
         ((fe-qq-bool-p (expr-if-else e) nil)
          (call "and" (list (expr-if-condition e) (expr-if-then e))))
         ((fe-qq-bool-p (expr-if-then e) t)
          (call "or" (list (expr-if-condition e) (expr-if-else e))))
         (t (call "if" (list (expr-if-condition e)
                             (expr-if-then e) (expr-if-else e))))))
      (expr-apply
       (let* ((fn (fe-unloc (expr-apply-function e)))
              (name (and (typep fn 'expr-symbol) (expr-symbol-name fn)))
              (xs (expr-apply-arguments e)))
         (cond
           ((spread-root-p e)
            (multiple-value-bind (heads tail) (spread-chain e)
              (fe-qq-chain
               (append (mapcar #'q heads)
                       (list (make-eapply
                              (make-esymbol "list")
                              (list (sym "unquote-splicing")
                                    (spread-tail tail))))))))
           ((and (string= name "list")
                 (gethash e *frontend-list-literal-expressions*))
            (fe-qq-chain (args xs)))
           ((member name '("unquote" "splice") :test #'string=)
            (make-eapply
             (make-esymbol "list")
             (list (sym (if (string= name "splice")
                            "unquote-splicing" "unquote"))
                   (first xs))))
           ((string= name "quasiquote")
            (unless (= (length xs) 1)
              (frontend-fail "quasiquote expects one form" :code "reader.arity"))
            (fe-qq-chain (list (sym "quasiquote") (first xs))))
           ((member name '("vector" "hash-map" "hash-set") :test #'string=)
            (make-eapply (make-esymbol name) (args xs)))
           (t (fe-qq-chain (cons (q fn) (args xs)))))))
      (expr-fn
       (fe-qq-chain
        (list (sym "fn")
              (fe-qq-chain (mapcar (lambda (x) (sym x))
                                   (expr-fn-params e)))
              (q (expr-fn-body e)))))
      (expr-def
       (fe-qq-chain
        (list (sym "def")
              (fe-qq-chain
               (cons (name-data (expr-def-name e))
                     (mapcar (lambda (x) (sym x)) (expr-def-params e))))
              (q (expr-def-body e)))))
      (expr-defvalue
       (call "def" (list (if (stringp (expr-defvalue-name e))
                              (make-esymbol (expr-defvalue-name e))
                              (expr-defvalue-name e))
                         (expr-defvalue-expression e))))
      (expr-let
       (fe-qq-chain
        (list (sym "let")
              (make-eapply
               (make-esymbol "vector")
               (mapcan (lambda (b)
                         (list (name-data (car b)) (q (cdr b))))
                       (expr-let-bindings e)))
              (q (expr-let-body e)))))
      (expr-letstar
       (fe-qq-chain
        (list (sym "let*")
              (make-eapply
               (make-esymbol "vector")
               (mapcan (lambda (b)
                         (list (name-data (car b)) (q (cdr b))))
                       (expr-letstar-bindings e)))
              (q (expr-letstar-body e)))))
      (expr-do
       (call "do" (expr-do-expressions e)))
      (expr-with-caps (call "with-caps"
                            (list (expr-with-caps-caps e)
                                  (expr-with-caps-body e))))
      (expr-with-config
       (call "with-config"
             (list (expr-with-config-map-expression e)
                   (expr-with-config-body e))))
      (expr-with-handler
       (fe-qq-chain
        (list (sym "with-handler")
              (make-eapply
               (make-esymbol "vector")
               (mapcan (lambda (b) (list (sym (car b)) (q (cdr b))))
                       (expr-with-handler-handlers e)))
              (q (expr-with-handler-body e)))))
      (expr-perform
       (fe-qq-chain
        (cons (sym "perform")
              (cons (sym (expr-perform-name e))
                    (args (expr-perform-arguments e))))))
      (expr-match
       (fe-qq-chain
        (list (sym "match")
              (q (expr-match-scrutinee e))
              (fe-qq-chain
               (mapcar (lambda (a)
                         (let ((pat (fe-brace-qq-pattern (first a)))
                               (guard (second a))
                               (body (q (third a))))
                           (fe-qq-chain
                            (if guard
                                (list pat (q guard) body)
                                (list pat body)))))
                       (expr-match-arms e))))))
      (expr-force (call "force" (list (expr-force-expression e))))
      (expr-delay (call "delay" (list (expr-delay-expression e))))
      (expr-import (call "import" (list (expr-import-expression e))))
      (expr-node (call "node" (list (expr-node-expression e))))
      (expr-config
       (call "config"
             (list (expr-config-key-expression e)
                   (or (expr-config-default e)
                       (make-eliteral (make-vnil))))))
      (expr-typed
       (call ":" (list (expr-typed-expression e) (expr-typed-type e))))
      (expr-load (call "load" (list (make-eliteral (make-vstring (expr-load-path e))))))
      (expr-loadmodule
       (call "load-module"
             (list (make-eliteral (make-vstring (expr-loadmodule-path e))))))

      (expr-island
       (call "island"
             (list (make-eliteral (make-vstring (expr-island-uri e)))
                   (and (expr-island-pin e)
                        (make-eliteral (make-vstring (expr-island-pin e)))))))
      (t (frontend-fail (format nil "expression type ~A is not representable in quasiquote"
                                (type-of e))
                        :code "reader.surface"))))))

 (defun fe-bvec (p)
  (fe-bnext p) (fe-bskip-lines p)
  (if (eq (fe-bkind p) :rbracket)
      (progn (fe-bnext p) (make-eapply (make-esymbol "vector") nil))
      (labels ((collect (items spread)
                 (when (eq (fe-bkind p) :eof)
                   (frontend-fail "unterminated vector literal"
                                  :code "reader.incomplete"
                                  :range (frontend-token-range (fe-bcur p))
                                  :incomplete-p t))
                 (let* ((is-spread (and (eq (fe-bkind p) :name)
                                        (fe-name-spread-p
                                         (frontend-token-value (fe-bcur p)))))
                        (item
                          (progn
                            (when (and spread (not is-spread))
                              (frontend-fail "vector spread must be the final element"
                                             :code "reader.syntax"))
                            (if is-spread
                                (progn
                                  (when spread
                                    (frontend-fail "vector spread must be the final element"
                                                   :code "reader.syntax"))
                                  (let ((s (subseq (fe-bname p) 3)))
                                    (if (plusp (length s)) (make-esymbol s)
                                        (fe-bexpr p t nil))))
                                (fe-bexpr p t nil)))))
                   (fe-bskip-lines p)
                   (cond
                     ((eq (fe-bkind p) :comma)
                      (fe-bnext p) (fe-bskip-lines p)
                      (collect (cons item items) (or spread is-spread)))
                     ((eq (fe-bkind p) :rbracket)
                      (fe-bnext p)
                      (let ((all (nreverse (cons item items))))
                        (if (not (or spread is-spread))
                            (make-eapply (make-esymbol "vector") all)
                            (reduce (lambda (x acc)
                                      (make-eapply (make-esymbol "cons")
                                                   (list x acc)))
                                    (butlast all) :from-end t
                                    :initial-value (car (last all))))))
                     (t
                      (frontend-fail "expected ',' or ']' in vec literal"
                                     :code (if (eq (fe-bkind p) :eof)
                                               "reader.incomplete" "reader.syntax")
                                     :range (frontend-token-range (fe-bcur p))
                                     :incomplete-p (eq (fe-bkind p) :eof)))))))
        (collect nil nil))))
 (defun fe-bquote-block (p)
  (fe-bexpect p :lbrace "quote requires '{'")
  (fe-bskip-nl p)
  ;; Quoted brace data uses the full expression grammar: calls, vectors,
  ;; maps, and special forms are all syntax values, not just bare names.
  (let ((x (if (and (eq (fe-bkind p) :name)
                    (eq (frontend-token-kind
                         (aref (fe-bparser-tokens p)
                               (min (1+ (fe-bparser-pos p))
                                    (1- (length (fe-bparser-tokens p))))))
                         :rbrace))
               (make-esymbol (fe-bname p))
               (fe-bexpr p nil nil))))
    (fe-bskip-nl p)
    (fe-bexpect p :rbrace "expected '}' after quote")
    (make-equote x)))
(defun fe-mark-sigil-tree (e kind)
  "Mark generated observation applications so lint can distinguish them
from a user-written bare primitive, including nested lowered children."
  (setf e (fe-unloc e))
  (typecase e
    (expr-apply
     (let ((name (and (typep (fe-unloc (expr-apply-function e)) 'expr-symbol)
                      (expr-symbol-name (fe-unloc (expr-apply-function e))))))
       (when (member name '("slurp" "env-get" "tree-observe" "probe" "config")
                     :test #'string=)
         (setf (gethash e *frontend-sigil-expressions*) kind)))
     (fe-mark-sigil-tree (expr-apply-function e) kind)
     (mapc (lambda (x) (fe-mark-sigil-tree x kind))
           (expr-apply-arguments e)))
    (expr-perform
     (when (string= (expr-perform-name e) "tree-observe")
       (setf (gethash e *frontend-sigil-expressions*) kind))
     (mapc (lambda (x) (fe-mark-sigil-tree x kind))
           (expr-perform-arguments e)))
    (expr-if
     (fe-mark-sigil-tree (expr-if-condition e) kind)
     (fe-mark-sigil-tree (expr-if-then e) kind)
     (fe-mark-sigil-tree (expr-if-else e) kind)))
  e)
 (defun fe-bprimary (p cond)
  (let ((tok (fe-bcur p)))
    (when (eq (frontend-token-kind tok) :eof)
      (frontend-fail "unexpected end of input"
                     :code "reader.incomplete"
                     :range (frontend-token-range tok)
                     :incomplete-p t))
    (case (frontend-token-kind tok)
      (:number (fe-bnext p) (make-eliteral (make-vint (frontend-token-value tok))))
      (:float (fe-bnext p) (make-eliteral (make-vfloat (frontend-token-value tok))))
      (:string (fe-bnext p) (make-eliteral (make-vstring (frontend-token-value tok))))
      (:fstring (fe-bnext p) (fe-build-fstring (frontend-token-value tok) (fe-bparser-source p)))
      (:keyword (fe-bnext p) (make-eliteral (make-vkeyword (frontend-token-value tok))))
      (:lparen
       (fe-bnext p)
       ;; Parenthesized grouping is whitespace-transparent in the brace
       ;; reader.  In particular, a printer may place the first expression
       ;; on the line after the opening delimiter and the closing delimiter
       ;; on its own line.
       (fe-bskip-nl p)
       (let ((x (fe-bexpr p t nil)))
         (fe-bskip-lines p)
         (fe-bexpect p :rparen "expected ')' after expression") x))
      (:lbracket (fe-blist p))
      (:lbrace
       (if cond
           (frontend-fail "a map literal used directly as a condition must be parenthesized" :code "reader.syntax")
           (fe-bmap p)))
      (:name
       (let ((n (fe-bname p)))
         (cond
           ((fe-special-float n) (make-eliteral (make-vfloat (fe-special-float n))))
           ((string= n "nil") (make-eliteral (make-vnil)))
           ((string= n "true") (make-eliteral (make-vbool t)))
           ((string= n "false") (make-eliteral (make-vbool nil)))
           ((and (string= n "vec") (eq (fe-bkind p) :lbracket))
            (fe-bvec p))
           ((and (> (length n) 1) (char= (char n 0) #\$))
            (let* ((kind (subseq n 1))
                   (desc (fe-observation-descriptor kind)))
              (unless desc
                (frontend-fail
                 (format nil "unknown observation head $~A (known: $file, $env, $glob, $probe, $secret, $config)" kind)
                 :code "reader.surface" :range (frontend-token-range tok)))
              (fe-bexpect p :lparen "expected '(' after observation head")
              (let* ((args (fe-bargs-no-spread p))
                     (min (second desc)) (max (third desc)))
                (unless (<= min (length args) max)
                  (frontend-fail
                   (format nil "$~A expects ~D~@[ to ~D~] argument(s), got ~D"
                           kind min (unless (= min max) max) (length args))
                   :code "reader.arity" :range (frontend-token-range tok)))
                (let ((result
                        (cond
                          ((string= kind "file") (make-eapply (make-esymbol "slurp") args))
                          ((string= kind "env")
                           (if (= (length args) 1)
                               (make-eapply (make-esymbol "env-get") args)
                               (make-eif (make-eapply (make-esymbol "nil?")
                                                      (list (make-eapply (make-esymbol "env-get")
                                                                         (list (first args)))))
                                         (second args)
                                         (make-eapply (make-esymbol "env-get")
                                                      (list (first args))))))
                          ((string= kind "glob") (make-eperform "tree-observe" args))
                          ((string= kind "probe") (make-eapply (make-esymbol "probe") args))
                          ((string= kind "secret") (make-eapply (make-esymbol "slurp") args))
                          (t (make-econfig (first args) (second args))))))
                  (fe-mark-sigil-tree result kind)
                  result))))
           ((member n '("force" "delay" "import") :test #'string=)
            (if (eq (fe-bkind p) :lparen)
                (progn
                  (fe-bnext p)
                  (fe-bskip-nl p)
                  (let ((x (fe-bexpr p t nil)))
                    (fe-bskip-lines p)
                    (fe-bexpect p :rparen "expected ')'")
                    (cond ((string= n "force") (make-eforce x))
                          ((string= n "delay") (make-edelay x))
                          (t (make-eimport x)))))
                (make-esymbol n)))
           ((string= n "with-handler")
            (fe-bexpect p :lparen "with-handler requires '('")
            (let ((pairs (fe-bargs-no-spread p :handler-p t)) (handlers nil))
              (dolist (pair pairs)
                (unless (and (typep pair 'expr-apply)
                             (typep (expr-apply-function pair) 'expr-symbol)
                             (string= (expr-symbol-name (expr-apply-function pair)) "=")
                             (= (length (expr-apply-arguments pair)) 2))
                  (frontend-fail "with-handler entries require name = function"
                                 :code "reader.syntax"))
                (let ((name (first (expr-apply-arguments pair))))
                  (unless (or (and (typep name 'expr-literal)
                                   (typep (expr-literal-value name) 'value-keyword))
                              (typep name 'expr-symbol))
                    (frontend-fail "handler name must be a name or keyword"
                                   :code "reader.syntax"))
                  (push (cons (if (typep name 'expr-symbol)
                                  (expr-symbol-name name)
                                  (value-keyword-value (expr-literal-value name)))
                              (second (expr-apply-arguments pair)))
                        handlers)))
              (make-ewith-handler (nreverse handlers) (fe-bblock p))))
           ((string= n "typed")
            (fe-bexpect p :lparen "typed requires '('")
            (fe-bskip-nl p)
            (let ((x (fe-bexpr p t nil)))
              (fe-bskip-lines p)
              (fe-bexpect p :comma "typed requires comma")
              (fe-bskip-nl p)
              (let ((ty (fe-bexpr p t nil)))
                (fe-bskip-lines p)
                (fe-bexpect p :rparen "typed requires ')'")
                (make-typed x ty))))
           ((string= n "if")
            (let ((c (fe-bexpr p nil t))
                  (th (fe-bblock p))
                  (el (let ((saved (fe-bparser-pos p)))
                        (fe-bskip-lines p)
                        (if (and (eq (fe-bkind p) :name)
                                 (string= (frontend-token-value (fe-bcur p))
                                          "else"))
                            (progn
                              (fe-bnext p)
                              (if (and (eq (fe-bkind p) :name)
                                       (string= (frontend-token-value
                                                 (fe-bcur p)) "if"))
                                  (fe-bprimary p nil)
                                  (fe-bblock p)))
                            (progn
                              (setf (fe-bparser-pos p) saved)
                              (make-eliteral (make-vnil)))))))
              (make-eif c th el)))
           ((string= n "try") (fe-btry p))
           ((string= n "quasiquote")
            (let ((forms (let ((*frontend-qq-parse-depth*
                                 (1+ *frontend-qq-parse-depth*)))
                            (fe-bblock p :return-forms t))))
              (unless (= (length forms) 1)
                (frontend-fail "quasiquote { ... } must contain exactly one form"
                               :code "reader.syntax"))
              (make-eapply (make-esymbol "quasiquote")
                           (list (fe-brace-qq-form (first forms))))))
           ((string= n "match")
            (let ((scrutinee (fe-bexpr p t nil)) (arms nil))
              (fe-bexpect p :lbrace "match requires '{'")
              (loop
                (fe-bskip-nl p)
                (when (eq (fe-bkind p) :rbrace) (fe-bnext p) (return))
                (when (eq (fe-bkind p) :eof)
                  (frontend-fail "unterminated match block"
                                 :code "reader.incomplete"
                                 :range (frontend-token-range (fe-bcur p))
                                 :incomplete-p t))
                (let ((pat (fe-bpattern p)) (guard nil))
                  (when (and (eq (fe-bkind p) :name)
                             (string= (frontend-token-value (fe-bcur p)) "if"))
                    (fe-bnext p) (setf guard (fe-bexpr p t t)))
                  (unless (fe-b-infix-p p '("=>"))
                    (frontend-fail "match arm requires '=>'" :code "reader.syntax"
                                   :range (frontend-token-range (fe-bcur p))))
                  (fe-bnext p)
                  (push (list pat guard (fe-bexpr p nil nil)) arms)
                  (when (member (fe-bkind p) '(:newline :semi) :test #'eq)
                    (fe-bskip-nl p))))
              (make-ematch scrutinee (nreverse arms))))
           ((string= n "with")
            (fe-bexpect p :lbrace "with requires clause block")
            (let ((caps nil) (config nil) (handlers nil)
                  (seen-caps nil) (seen-config nil) (seen-handlers nil))
              (loop
                (fe-bskip-nl p)
                (when (eq (fe-bkind p) :rbrace) (fe-bnext p) (return))
                (when (eq (fe-bkind p) :eof)
                  (frontend-fail "unterminated with block"
                                 :code "reader.incomplete"
                                 :range (frontend-token-range (fe-bcur p))
                                 :incomplete-p t))
                (let ((clause (fe-bname p)))
                  (fe-bexpect p :colon "with clauses require ':'")
                  (cond
                    ((string= clause "caps")
                     (when seen-caps
                       (frontend-fail "duplicate with caps clause" :code "reader.syntax"))
                     (setf seen-caps t caps (fe-bexpr p t nil)))
                    ((string= clause "config")
                     (when seen-config
                       (frontend-fail "duplicate with config clause" :code "reader.syntax"))
                     (setf seen-config t config (fe-bexpr p t nil)))
                    ((string= clause "handlers")
                     (when seen-handlers
                       (frontend-fail "duplicate with handlers clause" :code "reader.syntax"))
                     (setf seen-handlers t)
                     (let ((v (fe-bexpr p t nil)))
                       (unless (typep v 'expr-apply)
                         (frontend-fail "handlers: expects a map literal"
                                        :code "reader.syntax"))
                       (dolist (pair (loop for (a b) on (expr-apply-arguments v) by #'cddr
                                            collect (cons a b)))
                         (let ((key (car pair)))
                           (unless (or (and (typep key 'expr-literal)
                                            (typep (expr-literal-value key) 'value-keyword))
                                       (typep key 'expr-symbol))
                             (frontend-fail "handler map keys must be names or keywords"
                                            :code "reader.syntax"))
                           (push (cons (if (typep key 'expr-symbol)
                                           (expr-symbol-name key)
                                           (value-keyword-value
                                            (expr-literal-value key)))
                                       (cdr pair))
                                 handlers)))))
                    (t (frontend-fail (format nil "unknown with clause ~A" clause)
                                      :code "reader.surface")))
                  (when (member (fe-bkind p) '(:comma :newline :semi) :test #'eq)
                    (fe-bskip-nl p))))
              (let ((body (fe-bblock p)))
                (when handlers (setf body (make-ewith-handler (nreverse handlers) body)))
                (when config (setf body (make-ewith-config config body)))
                (when caps (setf body (make-ewith-caps caps body)))
                body)))
           ((string= n "defmacro")
            (let ((name (fe-bname p)) (params (fe-bparams p)) (body (fe-bblock p)))
              (make-eapply (make-esymbol "defmacro")
                           (cons (make-eapply (make-esymbol name)
                                              (mapcar #'make-esymbol params))
                                 (if (typep body 'expr-do)
                                     (expr-do-expressions body) (list body))))))
           ((string= n "needs") (make-eapply (make-esymbol "needs") (fe-bargs-no-spread p)))
           ((string= n "fn")
            (let* ((location (frontend-token-range (fe-bcur p)))
                   (params (fe-bparams-annotated p))
                   (ret (fe-bret-annotation p))
                   (body (fe-bblock p)))
              (multiple-value-bind (names assembled) (fe-assemble-fn params ret body location)
                (make-efn names assembled))))
           ((string= n "def")
            (let* ((location (frontend-token-range (fe-bcur p)))
                   (name (fe-bbinding-name p))
                   (params (fe-bparams-annotated p))
                   (ret (fe-bret-annotation p))
                   (body (fe-bblock p)))
              (multiple-value-bind (names assembled) (fe-assemble-fn params ret body location)
                (make-edef name names assembled))))
           ((string= n "let*")
            (fe-bexpect p :lparen "let* requires bindings")
            (fe-bskip-lines p)
            (let ((bs nil))
              (unless (eq (fe-bkind p) :rparen)
                (loop
                  (let ((name (fe-bbinding-name p)))
                    (when (and (eq (fe-bkind p) :name)
                               (string= (frontend-token-value (fe-bcur p)) "="))
                      (fe-bnext p))
                    (push (cons name (fe-bexpr p t nil)) bs))
                  (fe-bskip-lines p)
                  (if (eq (fe-bkind p) :comma)
                      (progn (fe-bnext p) (fe-bskip-lines p))
                      (return))))
              (fe-bexpect p :rparen "expected ')'")
              (make-eletstar (nreverse bs) (fe-bblock p))))
           ((string= n "let")
            (if (eq (fe-bkind p) :name)
                (let ((name (fe-bbinding-name p)))
                  (unless (and (eq (fe-bkind p) :name)
                               (string= (frontend-token-value (fe-bcur p)) "="))
                    (frontend-fail "expected '=' after let binding" :code "reader.syntax"))
                  (fe-bnext p)
                  (let ((location (frontend-token-range (fe-bcur p)))
                        (rhs (fe-bexpr p nil nil)))
                    (make-edefvalue name (make-elocated location rhs))))
                (progn
                  (fe-bexpect p :lparen "let requires bindings")
                  (fe-bskip-lines p)
                  (let ((bs nil))
                    (unless (eq (fe-bkind p) :rparen)
                      (loop
                        (let ((name (fe-bbinding-name p))
                              (ty nil))
                          ;; Brace let bindings use the same annotation
                          ;; shape as sexpr bindings: name : type = value.
                          (when (eq (fe-bkind p) :colon)
                            (fe-bnext p)
                            (fe-bskip-lines p)
                            ;; A binding annotation is a postfix expression,
                            ;; not a full infix expression: the '=' belongs
                            ;; to this binding, not to the type.
                            (setf ty (fe-bprimary p nil)))
                          (unless (and (eq (fe-bkind p) :name)
                                       (string= (frontend-token-value (fe-bcur p)) "="))
                            (frontend-fail "expected '=' in binding"
                                           :code "reader.syntax"
                                           :range (frontend-token-range (fe-bcur p))))
                          (fe-bnext p)
                          (fe-bskip-lines p)
                          (push (cons name
                                      (let ((value (fe-bexpr p t nil)))
                                        (if ty (make-typed value ty) value)))
                                bs))

                        (fe-bskip-lines p)
                        (if (eq (fe-bkind p) :comma)
                            (progn (fe-bnext p) (fe-bskip-lines p))
                            (return))))
                    (fe-bskip-lines p)
                    (fe-bexpect p :rparen "expected ')'")
                    (make-elet (nreverse bs) (fe-bblock p))))))
           ((string= n "do") (let ((b (fe-bblock p))) (make-edo (expr-list-of-body b))))
           ((string= n "module") (let ((b (fe-bblock p))) (make-emodule (expr-list-of-body b))))
           ((string= n "node")
            (if (eq (fe-bkind p) :lbrace)
                (make-enode (fe-bblock p))
                (let ((name (fe-bbinding-name p)))
                  (if (eq (fe-bkind p) :lparen)
                      (let ((params (fe-bparams-annotated p))
                            (ret (fe-bret-annotation p))
                            (needs nil))
                        (when (and (eq (fe-bkind p) :name)
                                   (string= (frontend-token-value (fe-bcur p)) "needs"))
                          (fe-bnext p)
                          (loop until (eq (fe-bkind p) :lbrace) do
                            (push (fe-bexpr p t nil) needs)
                            (if (eq (fe-bkind p) :comma)
                                (progn (fe-bnext p) (fe-bskip-nl p))
                                (unless (eq (fe-bkind p) :lbrace)
                                  (frontend-fail "expected ',' or '{' after needs item"
                                                 :code "reader.syntax")))))
                        (let ((body (fe-bblock p)))
                          (when needs
                            (let ((caps (fe-lower-needs (nreverse needs))))
                              (setf body
                                    (make-ewith-caps
                                     (if (cdr caps)
                                         (make-eapply (make-esymbol "cap-compose") caps)
                                         (first caps))
                                     body))))
                          (multiple-value-bind (names assembled)
                              (fe-assemble-fn params ret body
                                              (frontend-token-range (fe-bcur p)))
                            (make-edefnode name names assembled))))
                      (let ((location (frontend-token-range (fe-bcur p)))
                            (body (make-enode (fe-bblock p))))
                        (make-edefvalue name (make-elocated location body)))))))
           ((member n '("with-caps" "with-config") :test #'string=)
            (fe-bexpect p :lparen "expected '('")
            (fe-bskip-nl p)
            (let ((x (fe-bexpr p t nil)))
              (fe-bskip-lines p)
              (fe-bexpect p :rparen "expected ')'")
              (if (string= n "with-caps") (make-ewith-caps x (fe-bblock p))
                  (make-ewith-config x (fe-bblock p)))))
           ((string= n "perform")
            (let ((effect (fe-bname p)))
              (fe-bexpect p :lparen "perform requires argument list")
              (make-eperform effect (fe-bargs-no-spread p))))
           ((string= n "quote")
            (if (eq (fe-bkind p) :lbrace)
                (fe-bquote-block p)
                (make-equote (fe-bexpr p t nil))))
           ((string= n "reconcile") (fe-bmap p))
           ((member n '("config" "assert" "load" "load-module" "island") :test #'string=)
            (fe-bexpect p :lparen "expected '('")
            (let ((args (fe-bargs-no-spread p)))
              (cond ((string= n "config") (make-econfig (first args) (second args)))
                    ((string= n "assert") (fe-desugar-assert (first args) (second args)))
                    ((string= n "load") (unless (= (length args) 1) (frontend-fail "load expects one argument" :code "reader.arity")) (make-eload (fe-require-string-literal (first args) "load")))
                    ((string= n "load-module") (unless (= (length args) 1) (frontend-fail "load-module expects one argument" :code "reader.arity")) (make-eloadmodule (fe-require-string-literal (first args) "load-module")))
                    (t (unless (<= 1 (length args) 2) (frontend-fail "island expects URI and optional pin" :code "reader.arity"))
                       (make-eisland (fe-require-string-literal (first args) "island URI")
                                     (and (second args) (fe-require-string-literal (second args) "island pin")))))))
           (t (make-esymbol n)))))
      (otherwise (frontend-fail "expected expression" :code "reader.syntax"
                                :range (frontend-token-range tok))))))
(defun expr-list-of-body (e) (if (typep e 'expr-do) (expr-do-expressions e) (list e)))

(defun fe-combine-infix (op left right)
  (cond ((string= op "and") (make-eif left right (make-eliteral (make-vbool nil))))
        ((string= op "or") (make-eif left (make-eliteral (make-vbool t)) right))
        ((string= op "|>")
         (if (typep right 'expr-apply)
             (make-eapply (expr-apply-function right)
                          (cons left (expr-apply-arguments right)))
             (make-eapply right (list left))))
        (t (make-eapply (make-esymbol op) (list left right)))))

(defun fe-b-infix-precedence (op)
  (cond ((string= op "|>") 1)
        ((string= op "or") 2)
        ((string= op "and") 3)
        ((member op '("<" ">" "<=" ">=" "=") :test #'string=) 4)
        ((member op '("+" "-") :test #'string=) 5)
        ((member op '("*" "/" "mod") :test #'string=) 6)
        (t nil)))

(defun fe-bexpr (p &optional nl cond)
  (labels ((postfix (left)
             ;; In free expression contexts (arguments, grouping, and
             ;; collection elements), a newline is a separator only when the
             ;; caller made it significant. Postfix parsing therefore accepts
             ;; calls split across lines, while statement contexts retain it.
             (when nl (fe-bskip-lines p))
             (cond
               ((eq (fe-bkind p) :lparen)
                (fe-bnext p)
                (multiple-value-bind (args spreadp) (fe-bargs p)
                  (postfix
                   (if spreadp
                       (make-eapply (make-esymbol "apply")
                                    (cons left args))
                       (make-eapply left args)))))
               ((eq (fe-bkind p) :lbracket)
                (fe-bnext p)
                (let ((idx (fe-bexpr p t nil)))
                  (fe-bexpect p :rbracket "expected ']'")
                  (postfix
                   (make-eapply
                    (make-esymbol
                     (if (and (typep idx 'expr-literal)
                              (typep (expr-literal-value idx) 'value-int))
                         "vector-get" "hash-map-get"))
                    (list left idx)))))
               (t left)))
         (climb (min-prec)
           (let ((left (postfix (fe-bprimary p cond))))
             (loop
               (when nl (fe-bskip-lines p))
               (unless (and (eq (fe-bkind p) :name)
                            (fe-b-infix-p p '("|>" "or" "and" "<" ">"
                                              "<=" ">=" "=" "+" "-"
                                              "*" "/" "mod")))
                 (return left))
               (let* ((op (frontend-token-value (fe-bcur p)))
                      (prec (fe-b-infix-precedence op)))
                 (when (< prec min-prec) (return left))
                 (fe-bnext p)
                 (when nl (fe-bskip-lines p))
                 (let ((right (climb (1+ prec))))
                   (setf left (fe-combine-infix op left right))))))))
    (climb 1)))

 (defun fe-parse-fstring-hole (raw source)
  (let ((forms (fe-read-brace raw :source source)))
    (unless (= (length forms) 1)
      (frontend-fail "f-string interpolation must contain one expression"
                     :code "reader.syntax"))
    (fe-unloc (first forms))))

(defun fe-build-fstring (segments source)
  (let ((parts
          (mapcar (lambda (part)
                    (if (eq (car part) :lit)
                        (make-eliteral (make-vstring (cdr part)))
                        (make-eapply (make-esymbol "->string")
                                     (list (fe-parse-fstring-hole (cdr part) source)))))
                  segments)))
    (cond ((null parts) (make-eliteral (make-vstring "")))
          ((null (cdr parts)) (first parts))
          (t (make-eapply (make-esymbol "string-append") parts)))))
(defun fe-read-brace (text &key (source "<?>"))
  (let* ((tokens (coerce (fe-tokenize-brace text :source source) 'vector))
         (p (make-fe-bparser tokens source)) (forms nil))
    (fe-bskip-nl p)
    (loop until (eq (fe-bkind p) :eof) do
      (let ((tok (fe-bcur p)))
        (push (make-elocated (frontend-token-range tok)
                             (fe-bexpr p nil nil))
              forms))
      (unless (member (fe-bkind p) '(:newline :semi :eof) :test #'eq)
        (frontend-fail "expected newline or ';' between statements"
                       :code "reader.syntax"))
      (fe-bskip-nl p))
    (nreverse forms)))

(defun file-uses-braces (text) (or (find #\{ text) (find #\; text) (find #\# text)))
(defun read-source (text &key (source "<?>") surface)
  (let ((s (or surface (if (file-uses-braces text) :brace :sexpr))))
    (ecase s (:sexpr (fe-read-sexpr text :source source)) (:brace (fe-read-brace text :source source)))))
(defun read-stdin (&key (source "<stdin>") surface) (read-source (with-output-to-string (o) (loop for line = (cl:read-line *standard-input* nil nil) while line do (write-string line o) (terpri o))) :source source :surface surface))

;;; ---------------------------------------------------------------------------
;;; Canonical printers

(defun fe-print-float (x)
  (let ((x (coerce x 'double-float)))
    (cond
      ((pp.kernel:canonical-float-nan-p x) "nan")
      ((> x most-positive-double-float) "inf")
      ((< x (- most-positive-double-float)) "-inf")
      (t
       (let ((s (string-trim '(#\Space #\Tab #\Newline #\Return)
                             (format nil "~,17G" x))))
         (with-output-to-string (o)
           (loop for c across s do
             (write-char (if (member c '(#\d #\D) :test #'char=) #\e c) o))))))))

(defun fe-print-value (v)
  (typecase v
    (value-nil "nil")
    (value-bool (if (value-bool-value v) "true" "false"))
    (value-int (princ-to-string (value-int-value v)))
    (value-float (fe-print-float (value-float-value v)))
    (value-string (fe-string-escape (value-string-value v)))
    (value-keyword (concatenate 'string ":" (value-keyword-value v)))
    (value-pair (format nil "(cons ~A ~A)"
                        (fe-print-value (value-pair-car v))
                        (fe-print-value (value-pair-cdr v))))
    (value-vector (format nil "[~{~A~^ ~}]"
                          (loop for x across (value-vector-values v)
                                collect (fe-print-value x))))
    (value-map (format nil "{~{~A~^ ~}}"
                       (mapcan (lambda (pair)
                                 (list (fe-print-value (car pair))
                                       (fe-print-value (cdr pair))))
                               (value-map-entries v))))
    (value-set (format nil "#{~{~A~^ ~}}"
                       (mapcar #'fe-print-value (value-set-values v))))
    (t (frontend-fail (format nil "value type ~A has no surface literal"
                              (type-of v))
                      :code "printer.unprintable"))))

(defun fe-unloc (e) (if (typep e 'expr-located) (expr-located-expression e) e))
(defun fe-print-sexpr-expr (e)
  (setf e (fe-unloc e))
  (typecase e
    (expr-literal (fe-print-value (expr-literal-value e)))
    (expr-symbol (expr-symbol-name e))
    (expr-if (format nil "(if ~A ~A ~A)" (fe-print-sexpr-expr (expr-if-condition e)) (fe-print-sexpr-expr (expr-if-then e)) (fe-print-sexpr-expr (expr-if-else e))))
    (expr-let (format nil "(let [~{~A~^ ~}] ~A)" (mapcan (lambda (b) (list (car b) (fe-print-sexpr-expr (cdr b)))) (expr-let-bindings e)) (fe-print-sexpr-expr (expr-let-body e))))
    (expr-apply
     (if (and (typep (expr-apply-function e) 'expr-symbol)
              (string= (expr-symbol-name (expr-apply-function e)) "vector"))
         (format nil "[~{~A~^ ~}]"
                 (mapcar #'fe-print-sexpr-expr (expr-apply-arguments e)))
         (format nil "(~A~{ ~A~})"
                 (fe-print-sexpr-expr (expr-apply-function e))
                 (mapcar #'fe-print-sexpr-expr (expr-apply-arguments e)))))
    (expr-quote (format nil "(quote ~A)" (fe-print-sexpr-expr (expr-quote-expression e))))
    (expr-fn
     (multiple-value-bind (params ret body)
         (fe-fn-surface-parts (expr-fn-params e) (expr-fn-body e)
                              :type-printer #'fe-print-sexpr-expr)
       (format nil "(fn (~{~A~^ ~})~@[ : ~A~] ~A)"
               params (and ret (fe-print-sexpr-expr ret))
               (fe-print-sexpr-expr body))))
    (expr-force (format nil "(force ~A)" (fe-print-sexpr-expr (expr-force-expression e))))
    (expr-delay (format nil "(delay ~A)" (fe-print-sexpr-expr (expr-delay-expression e))))
    (expr-node (format nil "(node ~A)" (fe-print-sexpr-expr (expr-node-expression e))))
    (expr-with-caps (format nil "(with-caps ~A ~A)" (fe-print-sexpr-expr (expr-with-caps-caps e)) (fe-print-sexpr-expr (expr-with-caps-body e))))
    (expr-with-config (format nil "(with-config ~A ~A)" (fe-print-sexpr-expr (expr-with-config-map-expression e)) (fe-print-sexpr-expr (expr-with-config-body e))))
    (expr-perform (format nil "(perform ~A~{ ~A~})" (expr-perform-name e) (mapcar #'fe-print-sexpr-expr (expr-perform-arguments e))))
    (expr-with-handler (format nil "(with-handler [~{~A~^ ~}] ~A)" (mapcan (lambda (x) (list (car x) (fe-print-sexpr-expr (cdr x)))) (expr-with-handler-handlers e)) (fe-print-sexpr-expr (expr-with-handler-body e))))
    (expr-defnode
     (multiple-value-bind (params ret body)
         (fe-fn-surface-parts (expr-defnode-params e) (expr-defnode-body e)
                              :type-printer #'fe-print-sexpr-expr)
       (format nil "(defnode (~A~{ ~A~})~@[ : ~A~] ~A)"
               (expr-defnode-name e) params (and ret (fe-print-sexpr-expr ret))
               (fe-print-sexpr-expr body))))
    (expr-do (format nil "(do~{ ~A~})" (mapcar #'fe-print-sexpr-expr (expr-do-expressions e))))
    (expr-def
     (multiple-value-bind (params ret body)
         (fe-fn-surface-parts (expr-def-params e) (expr-def-body e)
                              :type-printer #'fe-print-sexpr-expr)
       (format nil "(def (~A~{ ~A~})~@[ : ~A~] ~A)"
               (expr-def-name e) params (and ret (fe-print-sexpr-expr ret))
               (fe-print-sexpr-expr body))))
    (expr-defvalue (format nil "(def ~A ~A)" (expr-defvalue-name e) (fe-print-sexpr-expr (expr-defvalue-expression e))))
    (expr-letstar (format nil "(let* [~{~A~^ ~}] ~A)" (mapcan (lambda (b) (list (car b) (fe-print-sexpr-expr (cdr b)))) (expr-letstar-bindings e)) (fe-print-sexpr-expr (expr-letstar-body e))))
    (expr-module (format nil "(module~{ ~A~})" (mapcar #'fe-print-sexpr-expr (expr-module-expressions e))))
    (expr-import (format nil "(import ~A)" (fe-print-sexpr-expr (expr-import-expression e))))
    (expr-load (format nil "(load ~A)" (fe-string-escape (expr-load-path e))))
    (expr-loadmodule (format nil "(load-module ~A)" (fe-string-escape (expr-loadmodule-path e))))
    (expr-island (format nil "(island ~A~@[ ~A~])" (fe-string-escape (expr-island-uri e)) (and (expr-island-pin e) (fe-string-escape (expr-island-pin e)))))
    (expr-config (format nil "(config ~A~@[ ~A~])" (fe-print-sexpr-expr (expr-config-key-expression e)) (and (expr-config-default e) (fe-print-sexpr-expr (expr-config-default e)))))
    (expr-typed (format nil "(typed ~A ~A)"
                        (fe-print-sexpr-expr (expr-typed-expression e))
                        (fe-print-sexpr-expr (expr-typed-type e))))
    (expr-match
     (format nil "(match ~A~{ ~A~})"
             (fe-print-sexpr-expr (expr-match-scrutinee e))
             (mapcar (lambda (arm)
                       (destructuring-bind (pattern guard body) arm
                         (format nil "(~A~@[ if ~A~] ~A)"
                                 (fe-print-pattern pattern)
                                 (and guard (fe-print-sexpr-expr guard))
                                 (fe-print-sexpr-expr body))))
                     (expr-match-arms e))))
    (t (frontend-fail (format nil "expression type ~A is not printable as sexpr" (type-of e))
                      :code "printer.unprintable"))))

(defun fe-print-pattern (p)
  (typecase p
    (pattern-wildcard "_")
    (pattern-variable (pattern-variable-name p))
    (pattern-literal (fe-print-value (pattern-literal-value p)))
    (pattern-list (format nil "(list~{ ~A~}~@[ . ~A~])"
                          (mapcar #'fe-print-pattern (pattern-list-patterns p))
                          (and (pattern-list-rest p)
                               (fe-print-pattern (pattern-list-rest p)))))
    (pattern-tagged (format nil "(tagged ~A~{ ~A~})"
                            (pattern-tagged-tag p)
                            (mapcar #'fe-print-pattern (pattern-tagged-patterns p))))
    (t (frontend-fail (format nil "pattern type ~A is not printable"
                              (type-of p))
                      :code "printer.unprintable"))))
(defun fe-print-brace-pattern (p)
  (typecase p
    (pattern-wildcard "_")
    (pattern-variable (pattern-variable-name p))
    (pattern-literal (fe-print-value (pattern-literal-value p)))
    (pattern-list
     (format nil "[~{~A~^, ~}~@[,...~A~]]"
             (mapcar #'fe-print-brace-pattern (pattern-list-patterns p))
             (and (pattern-list-rest p)
                  (fe-print-brace-pattern (pattern-list-rest p)))))
    (pattern-tagged
     (format nil "(:~A~{ ~A~})"
             (pattern-tagged-tag p)
             (mapcar #'fe-print-brace-pattern (pattern-tagged-patterns p))))
    (t (frontend-fail (format nil "pattern type ~A is not printable as brace"
                              (type-of p))
                      :code "printer.unprintable"))))

(defun fe-fn-surface-parts (params body &key
                                   (type-printer #'fe-print-brace-expr)
                                   (error-on-typed-parameter nil))
  "Recover annotation sugar without modifying the checked body."
  (let* ((raw (fe-unloc body))
         (items (copy-list (if (typep raw 'expr-do)
                               (expr-do-expressions raw)
                               (list raw))))
         (types nil))
    (loop while (and (cdr items)
                     (typep (first items) 'expr-located)
                     (typep (expr-located-expression (first items)) 'expr-typed)
                     (typep (expr-typed-expression
                             (expr-located-expression (first items)))
                            'expr-symbol))
          do (let* ((check (pop items))
                    (typed (expr-located-expression check))
                    (name (expr-symbol-name (expr-typed-expression typed))))
               (push (cons name (expr-typed-type typed)) types)))
    (let ((last (first (last items))) (ret nil))
      (when (and (typep last 'expr-located)
                 (typep (expr-located-expression last) 'expr-typed))
        (let ((typed (expr-located-expression last)))
          (setf ret (expr-typed-type typed))
          (setf (car (last items))
                (make-elocated (expr-located-range last)
                               (expr-typed-expression typed)))))
      (values
       (mapcar (lambda (name)
                 ;; Sexpr parameter names may contain ':', but that fused
                 ;; spelling has no brace equivalent. Reject it at the brace
                 ;; boundary rather than emitting ambiguous source.
                 (when (and error-on-typed-parameter
                            (find #\: name :test #'char=))
                   (frontend-fail
                    (format nil "parameter ~A has no brace spelling" name)
                    :code "printer.unprintable"))
                 (let ((ty (cdr (assoc name types :test #'string=))))
                   (if ty
                       (format nil "~A : ~A" name
                               (funcall type-printer ty))
                       name)))
               params)
       ret
       (if (null (cdr items)) (first items) (make-edo items))))))

(defun fe-qq-list-parts (e)
  (labels ((walk (x acc)
             (if (and (typep x 'expr-apply)
                      (typep (expr-apply-function x) 'expr-symbol)
                      (string= (expr-symbol-name (expr-apply-function x)) "cons")
                      (= (length (expr-apply-arguments x)) 2))
                 (let ((tail (second (expr-apply-arguments x))))
                   (if (and (typep tail 'expr-quote)
                            (typep (expr-quote-expression tail) 'expr-literal)
                            (typep (expr-literal-value
                                    (expr-quote-expression tail)) 'value-nil))
                       (values (nreverse (cons (first (expr-apply-arguments x))
                                               acc)) nil t)
                       (walk tail (cons (first (expr-apply-arguments x)) acc))))
                 (values nil nil nil))))
    (walk e nil)))

(defun fe-print-brace-qq (e)
  "Print quoted data using brace syntax accepted by the brace reader."
  (setf e (fe-unloc e))
  (labels ((reserved-p (s)
             (member s '("if" "fn" "def" "let" "let*" "do" "match" "with"
                         "node" "module" "import" "force" "delay" "quote"
                         "quasiquote" "perform" "config" "load" "load-module"
                         "island" "with-caps" "with-config" "with-handler")
                     :test #'string=))
           (qq (x) (fe-print-brace-qq x)))
    (multiple-value-bind (items tail listp) (fe-qq-list-parts e)
      (declare (ignore tail))
      (cond
        (listp (format nil "[~{~A~^, ~}]" (mapcar #'qq items)))
        ((typep e 'expr-quote)
         (let ((x (fe-unloc (expr-quote-expression e))))
           (typecase x
             (expr-symbol
              (if (reserved-p (expr-symbol-name x))
                  (format nil "quote { ~A }" (expr-symbol-name x))
                  (expr-symbol-name x)))
             (expr-literal (fe-print-value (expr-literal-value x)))
             (expr-quote (format nil "quote { ~A }" (qq x)))
             ;; Quoted composite syntax is still ordinary brace syntax
             ;; inside the quote block; recurse so calls and collections
             ;; remain parseable rather than becoming printer failures.
             (t (format nil "quote { ~A }" (qq x))))))
        ((typep e 'expr-literal) (fe-print-value (expr-literal-value e)))
        ((typep e 'expr-symbol) (expr-symbol-name e))
        ((and (typep e 'expr-apply)
              (typep (expr-apply-function e) 'expr-symbol))
         (let* ((name (expr-symbol-name (expr-apply-function e)))
                (xs (expr-apply-arguments e)))
           (cond
             ((and (string= name "list")
                   (gethash e *frontend-list-literal-expressions*))
              (format nil "[~{~A~^, ~}]" (mapcar #'qq xs)))
             ((and (string= name "quasiquote") (= (length xs) 1))
              (format nil "quasiquote { ~A }" (qq (first xs))))
             ((and (string= name "list") (= (length xs) 2)
                   (typep (first xs) 'expr-quote)
                   (typep (fe-unloc (expr-quote-expression (first xs)))
                          'expr-symbol)
                   (string= (expr-symbol-name
                             (fe-unloc (expr-quote-expression (first xs))))
                            "unquote"))
              (format nil "unquote(~A)" (fe-print-brace-expr (second xs))))
             ((and (string= name "list") (= (length xs) 2)
                   (typep (first xs) 'expr-quote)
                   (typep (fe-unloc (expr-quote-expression (first xs)))
                          'expr-symbol)
                   (string= (expr-symbol-name
                             (fe-unloc (expr-quote-expression (first xs))))
                            "unquote-splicing"))
              (format nil "splice(~A)" (fe-print-brace-expr (second xs))))
             ((string= name "vector")
              (format nil "vec[~{~A~^, ~}]" (mapcar #'qq xs)))
             ((string= name "hash-map")
              (unless (evenp (length xs))
                (frontend-fail "odd quasiquote map" :code "printer.unprintable"))
              (format nil "{~{~A -> ~A~^, ~}}"
                      (loop for (k v) on xs by #'cddr
                            append (list (qq k) (qq v)))))
             ((string= name "hash-set")
              (format nil "#{~{~A~^, ~}}" (mapcar #'qq xs)))
             ;; A quoted expression can contain any ordinary call or
             ;; special form; ordinary brace printing is its canonical syntax.
             (t (fe-print-brace-expr e)))))
        (t (frontend-fail (format nil "quasiquote data type ~A is not printable as brace"
                                  (type-of e))
                          :code "printer.unprintable"))))))

(defun fe-print-brace-expr (e)
  (setf e (fe-unloc e))
  (typecase e
    (expr-literal (fe-print-value (expr-literal-value e)))
    (expr-symbol (expr-symbol-name e))
    (expr-if (format nil "if ~A { ~A } else { ~A }"
                     (fe-print-brace-expr (expr-if-condition e))
                     (fe-print-brace-expr (expr-if-then e))
                     (fe-print-brace-expr (expr-if-else e))))
    (expr-fn
     (multiple-value-bind (params ret body)
         (fe-fn-surface-parts (expr-fn-params e) (expr-fn-body e)
                              :error-on-typed-parameter t)
       (format nil "fn(~{~A~^, ~})~@[ : ~A~] { ~A }"
               params (and ret (fe-print-brace-expr ret))
               (fe-print-brace-expr body))))
    (expr-def
     (multiple-value-bind (params ret body)
         (fe-fn-surface-parts (expr-def-params e) (expr-def-body e)
                              :error-on-typed-parameter t)
       (format nil "def ~A(~{~A~^, ~})~@[ : ~A~] { ~A }"
               (expr-def-name e) params (and ret (fe-print-brace-expr ret))
               (fe-print-brace-expr body))))
    (expr-defnode
     (multiple-value-bind (params ret body)
         (fe-fn-surface-parts (expr-defnode-params e) (expr-defnode-body e)
                              :error-on-typed-parameter t)
       (format nil "node ~A(~{~A~^, ~})~@[ : ~A~] { ~A }"
               (expr-defnode-name e) params (and ret (fe-print-brace-expr ret))
               (fe-print-brace-expr body))))
    (expr-defvalue (format nil "let ~A = ~A"
                           (expr-defvalue-name e)
                           (fe-print-brace-expr (expr-defvalue-expression e))))
    (expr-letstar (format nil "let*(~{~A~^, ~}) { ~A }"
                          (mapcar (lambda (b)
                                    (format nil "~A = ~A" (car b)
                                            (fe-print-brace-expr (cdr b))))
                                  (expr-letstar-bindings e))
                          (fe-print-brace-expr (expr-letstar-body e))))
    (expr-node (format nil "node { ~A }" (fe-print-brace-expr (expr-node-expression e))))
    (expr-do (format nil "do {~{ ~A;~}}"
                     (mapcar #'fe-print-brace-expr (expr-do-expressions e))))
    (expr-module (format nil "module {~{ ~A;~}}"
                         (mapcar #'fe-print-brace-expr (expr-module-expressions e))))
    (expr-apply
     (let* ((function (fe-unloc (expr-apply-function e)))
            (name (and (typep function 'expr-symbol)
                       (expr-symbol-name function)))
            (xs (expr-apply-arguments e)))
       (cond
         ((string= name "defmacro")
          (let* ((signature (and xs (fe-unloc (first xs))))
                 (macro-name (and (typep signature 'expr-apply)
                                  (fe-unloc (expr-apply-function signature))))
                 (params (and (typep signature 'expr-apply)
                              (expr-apply-arguments signature))))
            (unless (and (typep signature 'expr-apply)
                         (typep macro-name 'expr-symbol)
                         (every (lambda (param)
                                  (typep (fe-unloc param) 'expr-symbol))
                                params))
              (frontend-fail "defmacro form is not printable as brace"
                             :code "printer.unprintable"))
            (format nil "defmacro ~A(~{~A~^, ~}) {~{ ~A;~}}"
                    (expr-symbol-name macro-name)
                    (mapcar (lambda (param)
                              (expr-symbol-name (fe-unloc param)))
                            params)
                    (mapcar #'fe-print-brace-expr (rest xs)))))
         ((and (string= name "quasiquote") (= (length xs) 1))
          (format nil "quasiquote { ~A }"
                  (fe-print-brace-qq (first xs))))
         ((string= name "vector")
          (format nil "vec[~{~A~^, ~}]"
                  (mapcar #'fe-print-brace-expr xs)))
         (t
          (format nil "~A(~{~A~^, ~})"
                  (fe-print-brace-expr function)
                  (mapcar #'fe-print-brace-expr xs))))))
    (expr-quote (format nil "quote { ~A }" (fe-print-brace-expr (expr-quote-expression e))))
    (expr-force (format nil "force(~A)" (fe-print-brace-expr (expr-force-expression e))))
    (expr-delay (format nil "delay(~A)" (fe-print-brace-expr (expr-delay-expression e))))
    (expr-import (format nil "import(~A)" (fe-print-brace-expr (expr-import-expression e))))
    (expr-with-caps (format nil "with-caps(~A) { ~A }"
                            (fe-print-brace-expr (expr-with-caps-caps e))
                            (fe-print-brace-expr (expr-with-caps-body e))))
    (expr-with-config (format nil "with-config(~A) { ~A }"
                              (fe-print-brace-expr (expr-with-config-map-expression e))
                              (fe-print-brace-expr (expr-with-config-body e))))
    (expr-match
     (format nil "match ~A {~{ ~A~}}"
             (fe-print-brace-expr (expr-match-scrutinee e))
             (mapcar (lambda (a)
                       (format nil "~A~@[ if ~A~] => ~A;"
                               (fe-print-brace-pattern (first a))
                               (and (second a) (fe-print-brace-expr (second a)))
                               (fe-print-brace-expr (third a))))
                     (expr-match-arms e))))
    (expr-perform (format nil "perform ~A(~{~A~^, ~})"
                          (expr-perform-name e)
                          (mapcar #'fe-print-brace-expr (expr-perform-arguments e))))
    (expr-let (format nil "let(~{~A~^, ~}) { ~A }"
                      (mapcar (lambda (b)
                                (format nil "~A = ~A" (car b)
                                        (fe-print-brace-expr (cdr b))))
                              (expr-let-bindings e))
                      (fe-print-brace-expr (expr-let-body e))))
    (expr-load (format nil "load(~A)" (fe-string-escape (expr-load-path e))))
    (expr-loadmodule (format nil "load-module(~A)" (fe-string-escape (expr-loadmodule-path e))))
    (expr-island (format nil "island(~A~@[ , ~A~])"
                         (fe-string-escape (expr-island-uri e))
                         (and (expr-island-pin e) (fe-string-escape (expr-island-pin e)))))
    (expr-config (format nil "config(~A~@[ , ~A~])"
                         (fe-print-brace-expr (expr-config-key-expression e))
                         (and (expr-config-default e)
                              (fe-print-brace-expr (expr-config-default e)))))
    (expr-with-handler
     (format nil "with-handler(~{~A~^, ~}) { ~A }"
             (mapcar (lambda (x)
                       (format nil "~A = ~A" (car x)
                               (fe-print-brace-expr (cdr x))))
                     (expr-with-handler-handlers e))
             (fe-print-brace-expr (expr-with-handler-body e))))
    (expr-typed (format nil "typed(~A, ~A)"
                        (fe-print-brace-expr (expr-typed-expression e))
                        (fe-print-brace-expr (expr-typed-type e))))
    (t (frontend-fail (format nil "expression type ~A is not printable as brace"
                              (type-of e))
                      :code "printer.unprintable"))))

(defun print-source (forms &key (surface :sexpr) (source "<?>"))
  (declare (ignore source))
  (with-output-to-string (o)
    (let ((line 1) (first t))
      (dolist (f forms)
        (let* ((range (and (typep f 'expr-located) (expr-located-range f)))
               (target (and range (position-line (source-range-start range))))
               (printed (if (eq surface :brace)
                            (fe-print-brace-expr f)
                            (fe-print-sexpr-expr f))))
          (if target
              (loop while (< line target) do (terpri o) (incf line))
              (unless first (terpri o)))
          (write-string printed o)
          (setf first nil)
          (incf line (count #\Newline printed)))))))

;;; ---------------------------------------------------------------------------
;;; Comments, surface tables, and lint

(defstruct (frontend-comment (:constructor make-frontend-comment (line text))) line text)
(defun scan-comments (text &key (surface :sexpr))
  (let ((marker (if (eq surface :brace) #\# #\;))
        (island-ok (eq surface :sexpr))
        (line 1) (i 0) (n (length text)) (out nil))
    (labels ((alnum-p (c)
               (and c (or (alpha-char-p c) (fe-digit-p c))))
             (skip-string ()
               (loop while (< i n) do
                 (let ((c (char text i)))
                   (incf i)
                   (cond ((char= c #\Newline) (incf line))
                         ((char= c #\\) (when (< i n) (incf i)))
                         ((char= c #\") (return))))))
             (skip-island ()
               (loop while (< i n) do
                 (let ((c (char text i))) (incf i)
                   (when (char= c #\Newline) (incf line))
                   (when (char= c #\>) (return)))))
             (comment ()
               (let ((comment-line line))
                 (loop while (and (< i n) (char= (char text i) marker)) do (incf i))
                 (when (and (< i n) (char= (char text i) #\Space)) (incf i))
                 (let ((start i))
                   (loop while (and (< i n) (char/= (char text i) #\Newline)) do (incf i))
                   (push (make-frontend-comment
                          comment-line (subseq text start i))
                         out)))))
      (loop while (< i n) do
        (let ((c (char text i)))
          (cond
            ((char= c #\Newline) (incf i) (incf line))
            ((char= c #\") (incf i) (skip-string))
            ((char= c marker) (incf i) (comment))
            ((and island-ok (char= c #\<)
                  (< (1+ i) n)
                  (or (char= (char text (1+ i)) #\=)
                      (alnum-p (char text (1+ i)))))
             (incf i) (skip-island))
            (t (incf i)))))
    (nreverse out))))

(defun fe-text-lines (text)
  (let ((out nil) (start 0) (n (length text)))
    (loop for end = (or (cl:position #\Newline text :start start) n) do
      (push (subseq text start end) out)
      (if (= end n)
          (return (nreverse out))
          (setf start (1+ end))))))

(defun splice-comments (comments text &key (delim #\#))
  (if (null comments) text
      (let* ((raw (fe-text-lines text))
             (lines (if (and raw (string= (car (last raw)) "")) (butlast raw) raw))
             (max-line (reduce #'max comments :key #'frontend-comment-line
                               :initial-value (length lines)))
             (arr (make-array max-line :initial-element "")))
        (loop for l in lines for i from 0 do (setf (aref arr i) l))
        (dolist (c comments)
          (let* ((idx (1- (frontend-comment-line c)))
                 (body (string-trim '(#\Space #\Tab #\Return)
                                    (frontend-comment-text c)))
                 (piece (if (zerop (length body))
                            (string delim)
                            (format nil "~C ~A" delim body))))
            (when (>= idx (length arr))
              (let ((new (make-array (1+ idx) :initial-element "")))
                (replace new arr) (setf arr new)))
            (if (string= (aref arr idx) "")
                (setf (aref arr idx) piece)
                (setf (aref arr idx)
                      (format nil "~A  ~A" (aref arr idx) piece)))))
        (with-output-to-string (o)
          (loop for i below (length arr) do
            (when (> i 0) (terpri o))
            (write-string (aref arr i) o))
          (terpri o)))))
(defparameter *surface-with-descriptors*
  '(("caps" :wrapper with-caps :colon t)
    ("config" :wrapper with-config :colon t)
    ("handlers" :wrapper with-handler :colon t)))
(defparameter *surface-grant-sugar*
  '(("fs.read" :mode "ro") ("fs.write" :mode "wo") ("fs.rw" :mode "rw")))
(defparameter *surface-observation-primitives*
  '(("slurp" . "$file/$secret") ("env-get" . "$env")
    ("probe" . "$probe") ("config" . "$config")
    ("tree-observe" . "$glob")))

(defun surface-decision (cell)
  (typecase cell
    (pp.kernel::cell-file (list :surfaced "file"))
    (pp.kernel::cell-env (list :surfaced "env"))
    (pp.kernel::cell-tree (list :surfaced "glob"))
    (pp.kernel::cell-probe (list :surfaced "probe"))
    (pp.kernel::cell-sealed (list :surfaced "secret"))
    (pp.kernel::cell-config (list :surfaced "config"))
    (pp.kernel::cell-stat (list :whitelisted "file predicates"))
    (pp.kernel::cell-runtime-file (list :runtime-recorded "loader authority"))
    (pp.kernel::cell-tool (list :runtime-recorded "resolved binary"))
    (pp.kernel::cell-argv (list :runtime-recorded "argv"))
    (pp.kernel::cell-handler (list :runtime-recorded "effect handler"))
    (pp.kernel::cell-node (list :runtime-recorded "persistent node"))
    (pp.kernel::cell-domain (list :runtime-recorded "registered domain"))
    (pp.kernel::cell-unknown (list :runtime-recorded "unknown cell"))
    (t (frontend-fail (format nil "unknown cell type ~A" (type-of cell))
                      :code "surface.cell"))))

(defun surface-tables ()
  (list :observations *surface-observation-descriptors*
        :observation-primitives *surface-observation-primitives*
        :with *surface-with-descriptors*
        :needs *surface-grant-sugar*
        :spec (list :observations *surface-observation-descriptors*
                    :with *surface-with-descriptors*
                    :needs *surface-grant-sugar*)
        :surface-decision #'surface-decision))

(defun lint-source (forms &key source)
  (let ((warnings nil)
        (file (or source "<?>")))
    (labels
        ((emit-warning (code message line)
           (push (list :code code :message message :line line :source file)
                 warnings))
         (line-of (e)
           (let ((r (and (typep e 'expr-located) (expr-located-range e))))
             (if r (position-line (source-range-start r)) 1)))
         (strip (e) (fe-unloc e))
         (boolish (e)
           (setf e (strip e))
           (or (and (typep e 'expr-literal)
                    (typep (expr-literal-value e) 'value-bool))
               (and (typep e 'expr-symbol)
                    (member (expr-symbol-name e) '("true" "false") :test #'string=))
               (and (typep e 'expr-apply)
                    (let ((f (strip (expr-apply-function e))))
                      (and (typep f 'expr-symbol)
                           (or (member (expr-symbol-name f) '("not" "=" "nil?")
                                       :test #'string=)
                               (char= (char (expr-symbol-name f)
                                            (1- (length (expr-symbol-name f))))
                                      #\?)))))
               (and (typep e 'expr-if)
                    (boolish (expr-if-then e)) (boolish (expr-if-else e)))))
         (tagged (e)
           (setf e (strip e))
           (and (typep e 'expr-apply)
                (typep (expr-apply-function e) 'expr-symbol)
                (string= (expr-symbol-name (expr-apply-function e)) "list")
                (first (expr-apply-arguments e))
                (typep (first (expr-apply-arguments e)) 'expr-literal)
                (typep (expr-literal-value (first (expr-apply-arguments e)))
                       'value-keyword)))
         (observation-exempt-p ()
           (search "stdlib/" file :test #'char-equal))
         (observation-warning (name)
           (let ((surface (cdr (assoc name *surface-observation-primitives*
                                      :test #'string=))))
             (format nil "bare `~A` reads the world; use the ~A observation surface"
                     name surface)))
         (walk (e)
           (let* ((raw e) (x (strip e)) (line (line-of raw)))
             (typecase x
               (expr-symbol
                (when (find #\. (expr-symbol-name x))
                  (emit-warning "lint.dotted-identifier"
                        (format nil "identifier `~A` contains '.'"
                                (expr-symbol-name x)) line)))
               (expr-apply
                (let ((fn (strip (expr-apply-function x)))
                      (args (expr-apply-arguments x)))
                  (when (and (typep fn 'expr-symbol)
                             (member (expr-symbol-name fn)
                                     '("slurp" "env-get" "tree-observe" "probe" "config")
                                     :test #'string=)
                             (not (observation-exempt-p))
                             (not (gethash x *frontend-sigil-expressions*)))
                    (emit-warning "lint.bare-observation"
                          (observation-warning (expr-symbol-name fn)) line))
                  (when (and (typep fn 'expr-symbol)
                             (member (expr-symbol-name fn)
                                     '("vector-get" "vector-length")
                                     :test #'string=)
                             (first args)
                             (let ((a (strip (first args))))
                               (and (typep a 'expr-apply)
                                    (typep (expr-apply-function a) 'expr-symbol)
                                    (string= (expr-symbol-name
                                              (expr-apply-function a)) "list"))))
                    (emit-warning "lint.vector-on-list"
                          (format nil "~A applied to a bracket literal"
                                  (expr-symbol-name fn))
                          line))
                  (when (and (typep fn 'expr-symbol)
                             (member (expr-symbol-name fn) '("car" "cdr" "first" "rest")
                                     :test #'string=)
                             (tagged (first args)))
                    (emit-warning "lint.car-cdr-result"
                          "destructure a result instead of car/cdr" line))
                  (walk (expr-apply-function x))
                  (mapc #'walk args)))
               (expr-if
                (let ((then-tagged (tagged (expr-if-then x)))
                      (else-tagged (tagged (expr-if-else x))))
                  (when (not (eql then-tagged else-tagged))
                    (emit-warning "lint.mixed-result-shape"
                                  "inconsistent result shape: branches mix tagged results and plain values"
                                  line)))
                (when (and (typep (strip (expr-if-condition x)) 'expr-apply)
                           (typep (strip (expr-apply-function
                                          (strip (expr-if-condition x)))) 'expr-symbol)
                           (string= (expr-symbol-name
                                     (strip (expr-apply-function
                                             (strip (expr-if-condition x)))))
                                    "nil?"))
                  (emit-warning "lint.if-not-nil" "prefer a direct defaulting form" line))
                (walk (expr-if-condition x)) (walk (expr-if-then x))
                (walk (expr-if-else x)))
               (expr-let
                (when (and (= (length (expr-let-bindings x)) 1)
                           (typep (strip (expr-let-body x)) 'expr-let))
                  (emit-warning "lint.let-ladder" "combine consecutive single-binding lets" line))
                (mapc (lambda (b) (walk (cdr b))) (expr-let-bindings x))
                (walk (expr-let-body x)))
               (expr-letstar
                (mapc (lambda (b) (walk (cdr b))) (expr-letstar-bindings x))
                (walk (expr-letstar-body x)))
               (expr-fn (walk (expr-fn-body x)))
               (expr-def
                (let ((name (expr-def-name x)))
                  (when (and (> (length name) 0)
                             (char= (char name (1- (length name))) #\?))
                    (unless (boolish (expr-def-body x))
                      (emit-warning "lint.naming" (format nil "~A? does not return bool" name) line)))
                  (when (and (> (length name) 0)
                             (char= (char name (1- (length name))) #\!))
                    (emit-warning "lint.effect-shape" (format nil "~A! should perform an effect" name) line)))
                (walk (expr-def-body x)))
               (expr-defnode (walk (expr-defnode-body x)))
               (expr-defvalue (walk (expr-defvalue-expression x)))
               (expr-node (walk (expr-node-expression x)))
               (expr-do (mapc #'walk (expr-do-expressions x)))
               (expr-module (mapc #'walk (expr-module-expressions x)))
               (expr-import (walk (expr-import-expression x)))
               (expr-with-caps (walk (expr-with-caps-caps x))
                               (walk (expr-with-caps-body x)))
               (expr-with-config (walk (expr-with-config-map-expression x))
                                 (walk (expr-with-config-body x)))
               (expr-with-handler
                (mapc (lambda (b) (walk (cdr b))) (expr-with-handler-handlers x))
                (walk (expr-with-handler-body x)))
               (expr-perform
                (when (and (string= (expr-perform-name x) "tree-observe")
                           (not (observation-exempt-p))
                           (not (gethash x *frontend-sigil-expressions*)))
                  (emit-warning "lint.bare-observation"
                                (observation-warning "tree-observe") line))
                (mapc #'walk (expr-perform-arguments x)))
               (expr-config (walk (expr-config-key-expression x))
                            (when (expr-config-default x)
                              (walk (expr-config-default x))))
               (expr-match
                (walk (expr-match-scrutinee x))
                (mapc (lambda (a)
                        (when (second a) (walk (second a)))
                        (walk (third a)))
                      (expr-match-arms x)))
               (expr-quote (walk (expr-quote-expression x)))
               (expr-force (walk (expr-force-expression x)))
               (expr-delay (walk (expr-delay-expression x)))
               (expr-typed (walk (expr-typed-expression x))
                           (walk (expr-typed-type x)))))))
      (mapc #'walk forms)
      (nreverse warnings))))

;;; Compatibility aliases used by the later app owner.  These names remain
;;; unexported until packages.lisp is intentionally migrated.
(defun read-string (&rest args) (apply #'read-source args))
(defun print-program (&rest args) (apply #'print-source args))
(defparameter *required-frontend-exports*
  '(#:read-source #:read-stdin #:print-source #:read-string #:print-program
    #:scan-comments #:splice-comments #:surface-tables #:lint-source
    #:frontend-error #:frontend-error-code #:frontend-error-message
    #:frontend-error-range #:frontend-error-incomplete-p))
(defun required-frontend-exports () (copy-list *required-frontend-exports*))
