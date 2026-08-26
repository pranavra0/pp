;;;; pp command boundary.  Source commands always select pp.frontend readers;
;;;; user text is never silently handed to CL:READ.  Input is parsed as pp
;;;; text or as explicit machine-readable command data.

(in-package #:pp.app)

(defparameter +version+ "0.2.0-dev")

(defun version-string ()
  +version+)

(defvar *command-program-arguments* nil)
(defvar *command-effect-output* nil)
;; The command boundary keeps the source currently being parsed so frontend
;; diagnostics can explain removed surface forms whose lower-level parser
;; failure has no token range.
(defvar *language-source-context* nil)

(defun %source-context-text ()
  (and *language-source-context*
       (not (string= *language-source-context* "<stdin>"))
       (handler-case
           (%read-source-file *language-source-context*)
         (error () nil))))

(defun %frontend-removed-surface-message (message &optional source-text)
  (let ((text (or source-text (%source-context-text))))
    (cond
      ((and text
            (or (search "@cache" text :test #'char-equal)
                (search "@needs" text :test #'char-equal)
                (search "@reads" text :test #'char-equal)
                (search "@deprecated" text :test #'char-equal)))
       "attributes are not part of the language")
      ((and text
            (or (search ")?" text :test #'char=)
                (search "]?" text :test #'char=)))
       "postfix '?' is not part of the language")
      ((and text (search "handler " text :test #'char-equal)
            (search ":" text :test #'char=))
       "with clauses require one of caps:, config:, handlers:")
      (t message))))

(defun %command-split-program-arguments (arguments)
  (let ((command nil)
        (program nil)
        (seen-separator nil))
    (dolist (argument arguments)
      (if (or seen-separator (string= argument "--"))
          (if (string= argument "--")
              (setf seen-separator t)
              (push argument program))
          (push argument command)))
    (values (nreverse command) (nreverse program))))


(defun %property-range ()
  (pp.kernel:make-source-range
   :source "kernel-props"
   :start-pos (pp.kernel:make-position :offset 0 :line 1 :column 1)
   :end-pos (pp.kernel:make-position :offset 1 :line 1 :column 2)))

(defun %property-expr (constructor spec)
  (let ((lit (pp.kernel:make-eliteral (pp.kernel:make-vint 1)))
        (sym (pp.kernel:make-esymbol "x")))
    (cond
      ((string= constructor "literal-int")
       (pp.kernel:make-eliteral
        (pp.kernel:make-vint (parse-integer spec :junk-allowed nil))))
      ((string= constructor "symbol") (pp.kernel:make-esymbol spec))
      ((string= constructor "if")
       (pp.kernel:make-eif sym lit lit))
      ((string= constructor "let") (pp.kernel:make-elet (list (cons "x" lit)) lit))
      ((string= constructor "fn") (pp.kernel:make-efn (list "x") lit))
      ((string= constructor "apply") (pp.kernel:make-eapply sym (list lit)))
      ((string= constructor "quote") (pp.kernel:make-equote lit))
      ((string= constructor "force") (pp.kernel:make-eforce lit))
      ((string= constructor "with-caps")
       (pp.kernel:make-ewith-caps
        (pp.kernel:make-eliteral (pp.kernel:make-vnil)) lit))
      ((string= constructor "perform") (pp.kernel:make-eperform "effect" (list lit)))
      ((string= constructor "with-handler")
       (pp.kernel:make-ewith-handler (list (cons "effect" lit)) lit))
      ((string= constructor "delay") (pp.kernel:make-edelay lit))
      ((string= constructor "node") (pp.kernel:make-enode lit))
      ((string= constructor "defnode")
       (pp.kernel:make-edefnode "n" (list "x") lit))
      ((string= constructor "do") (pp.kernel:make-edo (list lit)))
      ((string= constructor "def") (pp.kernel:make-edef "f" (list "x") lit))
      ((string= constructor "defvalue") (pp.kernel:make-edefvalue "v" lit))
      ((string= constructor "letstar")
       (pp.kernel:make-eletstar (list (cons "x" lit)) lit))
      ((string= constructor "module") (pp.kernel:make-emodule (list lit)))
      ((string= constructor "import") (pp.kernel:make-eimport lit))
      ((string= constructor "load") (pp.kernel:make-eload spec))
      ((string= constructor "loadmodule") (pp.kernel:make-eloadmodule spec))
      ((string= constructor "island") (pp.kernel:make-eisland spec))
      ((string= constructor "with-config") (pp.kernel:make-ewith-config lit lit))
      ((string= constructor "config") (pp.kernel:make-econfig lit))
      ((string= constructor "typed") (pp.kernel:make-typed lit sym))
      ((string= constructor "located")
       (pp.kernel:make-elocated (%property-range) lit))
      ((string= constructor "match")
       (pp.kernel:make-ematch
        sym (list (list (pp.kernel:make-pvariable "x") nil lit))))
      (t (error "unknown expression kind: ~A" constructor)))))
(defun %read-source-file (path)
  "Read PATH as characters without invoking the host reader."
  (unless (and (stringp path) (probe-file path))
    (error "source file is not readable: ~A" path))
  (with-open-file (stream path :direction :input)
    (with-output-to-string (output)
      (loop for character = (cl:read-char stream nil nil)
            while character
            do (write-char character output)))))

(defun %write-source-file (path text)
  "Write TEXT to PATH through a same-directory temporary and rename."
  (let* ((target (pathname path))
         (nonce (format nil "~D-~D" (get-universal-time)
                        (random 1000000000)))
         (temp (make-pathname
                :name (format nil ".~A.pp-fmt-~A"
                              (or (pathname-name target) "source") nonce)
                :type "tmp"
                :defaults target))
         (committed nil))
    (unwind-protect
         (progn
           (with-open-file (stream temp :direction :output
                                   :if-exists :error
                                   :if-does-not-exist :create)
             (write-string text stream)
             (finish-output stream))
           (rename-file temp target)
           (setf committed t)
           path)
      (unless committed
        (when (probe-file temp)
          (ignore-errors (delete-file temp)))))))

(defun %suffix-p (path suffix)
  (let ((name path)
        (suffix-length (length suffix)))
    (and (>= (length name) suffix-length)
         (string= name suffix
                  :start1 (- (length name) suffix-length)
                  :end1 (length name)))))
(defun %brace-source-path-p (path)
  (or (%suffix-p path ".pp")
      (%suffix-p path ".ppb")))
(defun %frontend-token-text (range)
  (handler-case
      (let* ((source (source-range-source range))
             (text (%read-source-file source))
             (offset (position-offset (source-range-start range)))
             (length (length text)))
        (when (and (<= 0 offset) (< offset length))
          (let ((cursor offset))
            (labels ((separator-p (character)
                       (member character
                               '(#\Space #\Tab #\Newline #\Return #\,
                                 #\( #\) #\[ #\] #\{ #\} #\;)
                               :test #'char=)))
              (if (separator-p (char text cursor))
                  (string (char text cursor))
                  (progn
                    (loop while (and (< cursor length)
                                     (not (separator-p (char text cursor))))
                          do (incf cursor))
                    (subseq text offset cursor)))))))
    (error () nil)))

(defun %frontend-error-message (condition)
  (let* ((range (frontend-error-range condition))
         (source-text
           (and range
                (handler-case
                    (%read-source-file (source-range-source range))
                  (error () nil))))
         (message (%frontend-removed-surface-message
                   (frontend-error-message condition)
                   source-text)))
    (if (and range (string= message "expected ',' or ')'"))
        (let ((token (%frontend-token-text range)))
          (if token
              (format nil "~A, got ~A" message token)
              message))
        message)))

(defun %frontend-error-text (condition &key full-range)
  (let ((range (frontend-error-range condition)))
    (if range
        (format nil "~A at ~A"
                (%frontend-error-message condition)
                (if full-range
                    (source-range-format range)
                    (format nil "~A:~D"
                            (source-range-source range)
                            (position-line (source-range-start range)))))
        (%frontend-error-message condition))))

(defun %emit-frontend-text (text output)
  ;; The frontend returns text without stream policy; the app owns the final
  ;; delimiter.
  (write-string text output)
  (when (and (> (length text) 0)
             (char/= (char text (1- (length text))) #\Newline))
    (terpri output))
  (finish-output output))
 
(defun %read-stream-text (stream)
  "Read STREAM as characters without invoking the host reader."
  (with-output-to-string (output)
    (loop for character = (cl:read-char stream nil nil)
          while character
          do (write-char character output))))

(defun %language-source-path-p (path)
  (let ((name (string-downcase path)))
    (or (%suffix-p name ".pp")
        (%suffix-p name ".ppb")
        (%suffix-p name ".ppl"))))

(defun %validate-command-modes (arguments)
  ;; Port of cli.ml validate_modes: at most one command mode may be active,
  ;; and flag combinations with their own contracts are rejected up front so
  ;; the diagnostics do not depend on which runtime services are installed.
  (let ((modes nil)
        (first-subcommand
          (and arguments
               (find-if (lambda (candidate)
                          (member candidate arguments :test #'string=))
                        '("fmt" "lint" "graph" "gc" "island-pins" "cluster-init")))))
    (flet ((flag-mode (flag name)
             (when (member flag arguments :test #'string=) (push name modes))))
      (dolist (pair '(("--help" "--help") ("--version" "--version")
                      ("--dump-surface-tables" "--dump-surface-tables")
                      ("--dump-builtins" "--dump-builtins")
                      ("--check-kernel-props" "--check-kernel-props")
                      ("--mint-token" "--mint-token")
                      ("--transport-push" "--transport-push")
                      ("--transport-pull" "--transport-pull")
                      ("--serve-hit" "--serve-hit")
                      ("--recv-hit" "--recv-hit")
                      ("cluster-init" "cluster-init")
                      ("--emit-braces" "--emit-braces")
                      ("--roundtrip-braces" "--roundtrip-braces")
                      ("--compare-hash" "--compare-hash")
                      ("--list-comments" "--list-comments")
                      ("gc" "gc") ("graph" "graph") ("lint" "lint")))
        (flag-mode (first pair) (second pair)))
      (when first-subcommand (push first-subcommand modes))
      ;; The evaluation mode: a program source, `run`, `-e`, or one of the
      ;; runtime flags.  Source operands owned by a frontend subcommand do
      ;; not count as program sources.
      (unless (or first-subcommand
                  (member "--emit-braces" arguments :test #'string=)
                  (member "--roundtrip-braces" arguments :test #'string=)
                  (member "--compare-hash" arguments :test #'string=)
                  (member "--list-comments" arguments :test #'string=))
        (when (or (and arguments (string= (first arguments) "run"))
                  (member "-e" arguments :test #'string=)
                  (member "--watch" arguments :test #'string=)
                  (member "--supervise" arguments :test #'string=)
                  (member "--desired-object" arguments :test #'string=)
                  (member "--publish-object" arguments :test #'string=)
                  (member "--remote-node" arguments :test #'string=)
                  (some #'%language-source-path-p arguments))
          (push "evaluation" modes)))
      (let ((modes (remove-duplicates (nreverse modes) :test #'string=)))
        (when (> (length modes) 1)
          (error "conflicting command modes: ~{~A~^, ~}" modes))))
    ;; Pairwise contracts, in cli.ml's order.
    (flet ((has-flag (flag) (member flag arguments :test #'string=))
           (has-source ()
             (and (not first-subcommand)
                  (some #'%language-source-path-p arguments))))
      (when (and (has-flag "--desired-object")
                 (or (has-flag "-e") (has-source)))
        (error "--desired-object cannot be combined with a program"))
      (when (and (has-flag "--desired-object")
                 (not (or (has-flag "--reconcile") (has-flag "--supervise"))))
        (error "--desired-object requires --reconcile or --supervise"))
      (when (and (has-flag "--once") (has-flag "--watch"))
        (error "--once cannot be combined with --watch"))
      (when (and (has-flag "--once") (not (has-source)))
        (error "--once requires a source file"))
      (when (and (has-flag "--stabilize") (not (has-flag "--watch")))
        (error "--stabilize requires --watch"))
      (when (and (has-flag "--watch") (not (has-source)))
        (error "--watch requires a source file"))
      (when (and (has-flag "--supervise") (not (has-source))
                 (not (has-flag "--desired-object")))
        (error "--supervise requires a source file"))
      (when (and (has-flag "--publish-object") (not (has-source)))
        (error "--publish-object requires a source file"))
      (when (and (has-flag "--remote-node")
                 (has-flag "cluster-init"))
        (error "conflicting command modes: cluster-init, remote-node"))
      (when (and (has-flag "--remote-node") (not (has-source)))
        (error "--remote-node requires a source file")))))

(defun %source-surface (path)
  (let ((name (string-downcase path)))
    (cond ((or (%suffix-p name ".pp") (%suffix-p name ".ppb")) :brace)
          ((%suffix-p name ".ppl") :sexpr)
          (t (error "source file must end in .pp, .ppb, or .ppl: ~A" path)))))

(defun %language-form-inner (form)
  (if (typep form 'expr-located)
      (%language-form-inner (expr-located-expression form))
      form))

(defun %language-binding-form-p (form)
  (let ((inner (%language-form-inner form)))
    (or (typep inner 'expr-def)
        (typep inner 'expr-defnode)
        (typep inner 'expr-defvalue)
        (typep inner 'expr-module)
        ;; DEFMACRO is intentionally recognized structurally, rather than by
        ;; interning user text; the runtime expands it before evaluation.
        (and (typep inner 'expr-apply)
             (typep (expr-apply-function inner) 'expr-symbol)
             (string= (expr-symbol-name (expr-apply-function inner))
                      "defmacro")))))

(defun %language-print-value (state value output)
  (let ((value (runtime-evaluator-force-deep state value)))
    (format output "~A~%" (runtime-string-of-value value))
    (finish-output output)))

(defun %decimal-end (text start)
  (let ((cursor start))
    (loop while (and (< cursor (length text))
                     (digit-char-p (char text cursor)))
          do (incf cursor))
    (and (> cursor start) cursor)))

(defun %language-source-line-text (range)
  (handler-case
      (let ((text (%read-source-file (source-range-source range)))
            (wanted (position-line (source-range-start range))))
        (with-input-from-string (input text)
          (loop for line-number from 1
                for line = (cl:read-line input nil nil)
                while line
                when (= line-number wanted)
                  return line)))
    (error () nil)))

(defun %language-normalize-error-message (message range)
  (let ((expects (search " expects " message :test #'char=))
        (argument (search " argument" message :test #'char=))
        (got (search ", got " message :test #'char=)))
    (cond
      ;; Preserve the language-level arity contract independently of the
      ;; evaluator's internal wording.
      ((and expects argument got
            (< expects argument got))
       (let* ((name (subseq message 0 expects))
              (expected-text (subseq message (+ expects 9) argument))
              (got-text (subseq message (+ got 6))))
         (handler-case
             (format nil "arity mismatch calling ~A: expected ~D args, got ~D"
                     name
                     (parse-integer expected-text :junk-allowed nil)
                     (parse-integer got-text :junk-allowed nil))
           (error () message))))
      ;; The command's read-file effect has a stable operation-facing
      ;; diagnostic even though its implementation is named slurp.
      ((and range
            (search "slurp: permission denied for " message :test #'char=)
            (search "read-file" (or (%language-source-line-text range) "")
                    :test #'char-equal))
       (format nil "read-file: capability error: no read access for ~A"
               (subseq message
                       (+ (search " for " message :test #'char=) 5))))
      (t message))))

(defun %language-location-prefix (message source)
  "Split a generated SOURCE:LINE:COLUMN diagnostic prefix from MESSAGE.

The evaluator may retain a call-site range while a nested thunk has already
included its own range in the message.  Keep this parser deliberately narrow:
SOURCE must be the source attached to the condition and the coordinates must
be decimal, so ordinary user messages are not rewritten accidentally."
  (when (and source
             (>= (length message) (length source))
             (string= source message :end2 (length source)))
    (let ((cursor (length source)))
      (when (and (< cursor (length message))
                 (char= (char message cursor) #\:))
        (incf cursor)
        (let ((line-end (%decimal-end message cursor)))
          (when line-end
            (let ((line (parse-integer message :start cursor :end line-end)))
              (setf cursor line-end)
              (when (and (< cursor (length message))
                         (char= (char message cursor) #\:))
                (incf cursor)
                (let ((column-end (%decimal-end message cursor)))
                  (when column-end
                    (setf cursor column-end)
                    ;; A range can be a point or a span. Validate either form
                    ;; before consuming the prefix.
                    (when (and (< cursor (length message))
                               (char= (char message cursor) #\-))
                      (incf cursor)
                      (let ((end-line (%decimal-end message cursor)))
                        (when end-line
                          (setf cursor end-line)
                          (when (and (< cursor (length message))
                                     (char= (char message cursor) #\:))
                            (incf cursor)
                            (let ((end-column (%decimal-end message cursor)))
                              (when end-column
                                (setf cursor end-column)))))))
                    (when (and (< (1+ cursor) (length message))
                               (char= (char message cursor) #\:)
                               (char= (char message (1+ cursor)) #\Space))
                      (values (subseq message (+ cursor 2)) source line))))))))))))
(defun %language-error-text (condition)
  (cond
    ((typep condition 'language-error)
     (let* ((raw-message (language-error-message condition))
            (range (pp.runtime::language-error-range condition))
            (source (and range (source-range-source range)))
            (message raw-message)
            (location-source nil)
            (location-line nil)
            (clean message))
       ;; Strip every nested generated location, retaining the innermost one.
       ;; This handles both a single evaluator prefix and the
       ;; call-site/thunk-location double prefix without changing the
       ;; frontend condition path.
       (loop
         (multiple-value-bind (rest nested-source nested-line)
             (%language-location-prefix clean source)
           (if rest
               (setf clean rest
                     location-source nested-source
                     location-line nested-line)
               (return))))
       (setf clean (%language-normalize-error-message clean range))
       (let ((display-source (or location-source source)))
         (if display-source
             (format nil "~A at ~A:~D"
                     clean display-source
                     (or location-line
                         (position-line (source-range-start range))))
             clean))))
    ((typep condition 'type-error)
     ;; A typed delayed RHS can currently leak SBCL's SEQUENCE type error
     ;; while the evaluator is forcing the wrapper.  Do not expose host
     ;; structure dumps at the command boundary: this is a language type
     ;; failure even though the lower layer did not normalize it.
     (let ((text (princ-to-string condition)))
       (if (and (search "SEQUENCE" text :test #'char-equal)
                (search "PP.KERNEL:EXPR-" text :test #'char-equal))
           "type mismatch while forcing typed value"
           text)))
    ((typep condition 'frontend-error)
     (%frontend-error-text condition))
    (t (princ-to-string condition))))

(defun %language-binding-name (form)
  (let ((inner (%language-form-inner form)))
    (cond ((typep inner 'expr-def) (expr-def-name inner))
          ((typep inner 'expr-defnode) (expr-defnode-name inner))
          ((typep inner 'expr-defvalue) (expr-defvalue-name inner))
          (t nil))))

(defun %language-defmacro-form-p (form)
  (let ((inner (%language-form-inner form)))
    (and (typep inner 'expr-apply)
         (typep (expr-apply-function inner) 'expr-symbol)
         (string= (expr-symbol-name (expr-apply-function inner))
                  "defmacro"))))

(defun %language-persistent-form-p (form)
  "Return true for top-level assignment-like bindings only.

Grouped LET is an ordinary expression: its bindings are scoped to its body
and its value is the body's value.  The brace reader represents both grouped
LET and the statement form `let name = rhs` with expression objects, but the
latter is normalized to EDefValue and is already covered by
%LANGUAGE-BINDING-FORM-P.  Do not turn grouped LET into an exported module."
  (%language-binding-form-p form))

(defun %language-persistent-module (form)
  "Wrap one assignment-like/module form as an exported module.

Grouped LET is intentionally not handled here: it is an ordinary expression
and is evaluated directly by the REPL path."
  (make-emodule (list form)))

(defun %language-direct-binding-p (form)
  (let ((inner (%language-form-inner form)))
    (or (typep inner 'expr-def)
        (typep inner 'expr-defnode)
        (typep inner 'expr-defvalue))))

(defun %language-extend-environment (environment bindings)
  "Extend ENVIRONMENT with module BINDINGS using the kernel env hash rule."
  (reduce
   (lambda (current entry)
     (make-env
      (cons entry (env-bindings current))
      :env-id (1+ (env-env-id current))
      :env-hash
      (hash-concat
       (list "env" (env-env-hash current) (car entry)
             (hash-value (cdr entry))))))
   bindings :initial-value environment))

(defun %language-merge-module-value (environment value)
  (if (typep value 'value-env-map)
      (%language-extend-environment
       environment (value-env-map-bindings value))
      environment))

(defun %language-fallback-range (forms source)
  "Return the first source range available for a source-level fallback.

Evaluator failures normally carry their own range. This is only used for
runtime failures that escape without one, so the command boundary can still
render a source:line suffix."
  (when source
    (or (loop for form in forms
              when (typep form 'expr-located)
                return (expr-located-range form))
        (make-source-range
         :source source
         :start-pos (make-position :offset 0 :line 1 :column 1)
         :end-pos (make-position :offset 0 :line 1 :column 1)))))

(defun %language-reraise-with-source (condition forms source)
  "Attach SOURCE only when an evaluator condition has no range."
  (if (and source
           (typep condition 'language-error)
           (null (pp.runtime::language-error-range condition)))
      (error 'language-error
             :code (language-error-code condition)
             :message (language-error-message condition)
             :range (%language-fallback-range forms source))
      (error condition)))

(defun %command-home ()
  (let ((home (and (fboundp 'sb-ext:posix-getenv)
                   (sb-ext:posix-getenv "HOME"))))
    (unless (and home (plusp (length home)))
      (error "HOME is not set"))
    (pp.runtime:store-canonical-path home)))

(defun %command-store-root ()
  (namestring
   (merge-pathnames ".pp/store/"
                    (pathname (%command-home)))))

(defun %command-capabilities (specs)
  (mapcar (lambda (spec)
            (pp.kernel:mint-capability
             spec :realpath #'pp.runtime:store-canonical-path))
          (reverse specs)))

(defun %command-current-capabilities ()
  "Return the flat capability view at the command boundary.

Evaluator capability callbacks and the dynamic scope both expose this state.
Flatten only capability containers; no user value is accepted as authority."
  (labels ((flatten (value)
             (cond
               ((typep value 'pp.kernel:capability) (list value))
               ((consp value) (mapcan #'flatten value))
               (t nil))))
    (ignore-errors
      (flatten (pp.runtime:runtime-dynamic-capabilities)))))

(defun %command-capability-allows-file-p (capabilities path sealed &optional (want :read))
  (declare (ignore capabilities))
  (let* ((target (pp.kernel:canonicalize-path
                  path :realpath #'pp.runtime:store-canonical-path))
         (capabilities (%command-current-capabilities)))
    (some (lambda (capability)
            (if sealed
                (pp.kernel:capability-check-secret-p capability target)
                (if (eq want :write)
                    (pp.kernel:capability-check-fs-write-p capability target)
                    (pp.kernel:capability-check-fs-read-p capability target))))
          capabilities)))

 (defun %command-file-sealed-p (path)
  "Select the least-authority read mode for PATH."
  (if (and (pp.runtime:runtime-dynamic-in-node-p)
           (pp.runtime:runtime-sandbox-relative-p path)
           (ignore-errors (pp.runtime:runtime-sandbox-resolve path)))
      nil
      (let* ((canonical (pp.runtime:store-canonical-path path))
             (target (pp.kernel:canonicalize-path
                      canonical :realpath #'pp.runtime:store-canonical-path))
             (capabilities (%command-current-capabilities)))
        (cond
          ((some (lambda (capability)
                   (pp.kernel:capability-check-fs-read-p capability target))
                 capabilities)
           nil)
          ((some (lambda (capability)
                   (pp.kernel:capability-check-secret-p capability target))
                 capabilities)
           t)
          (t
           (pp.runtime:language-fail
            (format nil "slurp: permission denied for ~A" canonical)
            "runtime.authority"))))))

(defun %command-unseal-value (value)
  (if (typep value 'pp.kernel:value-sealed)
      (pp.kernel:make-vstring (pp.kernel:value-sealed-bytes value))
      (pp.runtime:language-fail
       "unseal expects a sealed value"
       "primitive.type")))

(defun %command-runtime-file-known-p (path)
  (let* ((session (ignore-errors (runtime-dynamic-session nil)))
         (service (and session
                       (runtime-session-find-service session :store-traces)))
         (traces (and service (funcall service)))
         (canonical (pp.runtime:store-canonical-path path)))
    (and (%command-loader-path-authorized-p canonical)
         traces
         (some
          (lambda (key)
            (some
             (lambda (trace)
               (some
                (lambda (read)
                  (let* ((raw (store-trace-read-cell read))
                         (cell (if (typep raw 'pp.kernel:cell)
                                   raw
                                   (pp.kernel:cell-parse
                                    (pp.runtime:store-identity-string raw)))))
                    (and (typep cell 'pp.kernel:cell-runtime-file)
                         (string=
                          canonical
                          (pp.runtime:store-canonical-path
                           (pp.kernel:cell-runtime-file-value cell))))))
                (store-trace-reads trace)))
             (trace-repository-load traces :key key)))
          (trace-repository-keys traces)))))

(defun %command-observe-file (path &optional sealed)
  (let* ((canonical (pp.runtime:store-canonical-path path))
         (capabilities (pp.runtime:runtime-dynamic-capabilities)))
    (unless (or (and (not sealed) (%command-runtime-file-known-p canonical))
                (%command-capability-allows-file-p capabilities canonical sealed))
      (pp.runtime:language-fail
       (format nil "permission denied: ~A" canonical)
       "runtime.authority"))
    (let ((bytes (or (pp.runtime:store-read-octets canonical)
                     (pp.runtime:language-fail
                      (format nil "cannot read file: ~A" canonical)
                      "runtime.observation"))))
      (if sealed bytes (pp.runtime:store-hash-content bytes)))))
(defun %command-observe-stat (path)
  (let* ((canonical (pp.runtime:store-canonical-path path))
         (target (pp.kernel:canonicalize-path
                  canonical :realpath #'pp.runtime:store-canonical-path))
         (target-string (pp.kernel:canonical-path-to-string target)))
    (unless (%command-capability-allows-file-p nil target-string nil :read)
      (pp.runtime:language-fail
       (format nil "file-exists?: capability error: no read access for ~A"
               target-string)
       "runtime.authority"))
    #+sbcl
    (handler-case
        (let ((mode (sb-posix:stat-mode (sb-posix:lstat target-string))))
          (cond ((= (logand mode sb-posix:s-ifmt) sb-posix:s-ifdir) "dir")
                ((= (logand mode sb-posix:s-ifmt) sb-posix:s-ifreg) "file")
                (t "absent")))
      (error () "absent"))
    #-sbcl
    (if (probe-file target-string) "file" "absent")))

 (defun %command-file-bytes-value (bytes sealed)
  (if sealed
      (pp.kernel:make-vsealed (pp.runtime::store-codec-octets-string bytes))
      (handler-case
          (pp.kernel:make-vstring (pp.runtime:store-octets-string bytes))
        ;; `slurp` is normally a text operation, but it is also the
        ;; construction path used by `blob` for opaque tools. Preserve
        ;; malformed UTF-8 byte-for-byte and let blob consume the sealed
        ;; representation below.
        (error ()
          (pp.kernel:make-vsealed
           (pp.runtime::store-codec-octets-string bytes))))))

 (defun %command-read-file-value (path &optional sealed)
  "Read an observed file, preferring the current node's scratch tree."
  (let* ((scratch
           (and (pp.runtime:runtime-sandbox-relative-p path)
                (ignore-errors (pp.runtime:runtime-sandbox-resolve path))))
         (scratch-bytes (and scratch (pp.runtime:store-read-octets scratch))))
    (if scratch-bytes
        (%command-file-bytes-value scratch-bytes sealed)
        (let* ((canonical (pp.runtime:store-canonical-path path))
               (capabilities (pp.runtime:runtime-dynamic-capabilities)))
          (unless (%command-capability-allows-file-p capabilities canonical sealed)
            (pp.runtime:language-fail
             (format nil "slurp: permission denied for ~A" canonical)
             "runtime.authority"))
          (let* ((session (pp.runtime:runtime-observation-session))
                 (cells (pp.runtime:runtime-observation-repository :store-cells))
                 (cell (if sealed
                           (pp.kernel:make-cell-sealed canonical)
                           (pp.kernel:make-cell-file canonical)))
                 (record
                   (lambda (cell-id hash)
                     (pp.runtime:runtime-observation-record
                      (pp.kernel:cell-parse cell-id) hash))))
            (if cells
                (let ((bytes
                        (if sealed
                            (pp.runtime:cell-repository-read-sealed
                             cells canonical
                             :pin-lookup
                             (and session
                                  (lambda (cell-id)
                                    (pp.runtime:runtime-session-find-sealed-pin
                                     session cell-id)))
                             :pin-store
                             (and session
                                  (lambda (cell-id value)
                                    (pp.runtime:runtime-session-set-sealed-pin
                                     session cell-id value)))
                             :record record)
                            (pp.runtime:cell-repository-read-file
                             cells canonical
                             :pin-lookup
                             (and session
                                  (lambda (cell-id)
                                    (pp.runtime:runtime-session-find-run-pin
                                     session cell-id)))
                             :pin-store
                             (and session
                                  (lambda (cell-id value)
                                    (pp.runtime:runtime-session-set-run-pin
                                     session cell-id value)))
                             :record record))))
                  (%command-file-bytes-value bytes sealed))
                (let* ((bytes
                         (or (pp.runtime:store-read-octets canonical)
                             (pp.runtime:language-fail
                              (format nil "cannot read file: ~A" canonical)
                              "runtime.observation")))
                       (hash (if sealed
                                 (pp.runtime:store-hash-octets bytes)
                                 (pp.runtime:store-hash-content bytes))))
                  (pp.runtime:runtime-observation-record cell hash)
                  (%command-file-bytes-value bytes sealed))))))))
 
(defun %command-value-text (value name)
  (cond ((typep value 'pp.kernel:value-string)
         (pp.kernel:value-string-value value))
        ((typep value 'pp.kernel:value-symbol)
         (pp.kernel:value-symbol-value value))
        ((typep value 'pp.kernel:value-keyword)
         (pp.kernel:value-keyword-value value))
        (t (pp.runtime:language-fail
            (format nil "~A expects a string" name)
            "primitive.type"))))

(defun %command-strict-text (value name)
  (if (typep value 'pp.kernel:value-string)
      (pp.kernel:value-string-value value)
      (pp.runtime:language-fail
       (format nil "~A expects a string" name)
       "primitive.type")))

(defun %command-force-argument (value force)
  (funcall (or force #'identity) value))
(defun %command-record-event (kind fields)
  (pp.runtime:runtime-effects-record-event
   (pp.kernel:make-vmap
    (cons (cons (pp.kernel:make-vkeyword "kind")
                (pp.kernel:make-vkeyword kind))
          fields))))

(defun %command-executable-p (path)
  #+sbcl
  (handler-case
      (let ((stat (sb-posix:stat path)))
        (and (= (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt)
                sb-posix:s-ifreg)
             (not (zerop (logand (sb-posix:stat-mode stat) #o111)))))
    (error () nil))
  #-sbcl
  (and (probe-file path) t))

(defun %command-resolve-tool (command)
  (let ((candidate
          (if (find #\/ command)
              command
              (loop for directory in
                    (%split-colons
                     (or (and (fboundp 'sb-ext:posix-getenv)
                              (sb-ext:posix-getenv "PATH"))
                         ""))
                    for path = (merge-pathnames command
                                                (pathname
                                                 (format nil "~A/" directory)))
                    when (and (plusp (length directory))
                               (%command-executable-p path))
                      do (return (namestring path))))))
    (unless (and candidate (%command-executable-p candidate))
      (pp.runtime:language-fail
       (format nil "run: command not found: ~A" command)
       "runtime.process"))
    (pp.runtime:store-canonical-path candidate)))

(defun %split-colons (text)
  (let ((fields '()) (start 0))
    (loop for i from 0 below (length text)
          when (char= (char text i) #\:)
            do (push (subseq text start i) fields)
               (setf start (1+ i)))
    (nreverse (cons (subseq text start) fields))))

(defun %command-tool-observed-hash (path)
  (pp.runtime:store-hash-octets
   (or (pp.runtime:store-read-octets path)
       (pp.runtime:language-fail
        (format nil "run: cannot read executable: ~A" path)
        "runtime.observation"))))

(defun %command-run-effect (arguments)
  (when (pp.runtime:runtime-dynamic-in-node-p)
    (pp.runtime:language-fail
     "run: may not be called inside a node body (scripting-tier only)"
     "runtime.tier"))
  (%command-process-required)
  (let ((journal (merge-pathnames
                  "journal/log"
                  (pp.runtime:store-directory-pathname
                   (%command-store-root)))))
    (when (probe-file journal)
      #+sbcl
      (unless (= (logand (sb-posix:stat-mode (sb-posix:lstat journal))
                         sb-posix:s-ifmt)
                 sb-posix:s-ifreg)
        (pp.runtime:language-fail
         "run: invalid journal log path"
         "runtime.process"))
      #-sbcl
      (when (probe-file (merge-pathnames "journal/log/" 
                                         (pp.runtime:store-directory-pathname
                                          (%command-store-root))))
        (pp.runtime:language-fail
         "run: invalid journal log path"
         "runtime.process"))))
  (unless (plusp (length arguments))
    (pp.runtime:language-fail "run expects a command" "primitive.arity"))
  (let ((argv
          (mapcar
           (lambda (value)
             (let ((text (%command-strict-text value "run")))
               (when (or (cl:position #\Return text)
                         (cl:position #\Newline text))
                 (pp.runtime:language-fail
                  "run: invalid argument contains a newline"
                  "runtime.process"))
               text))
           arguments)))
    (let* ((tool (%command-resolve-tool (first argv)))
           (stdout (make-string-output-stream))
           (stderr (make-string-output-stream))
           (process
             (handler-case
                 (sb-ext:run-program
                  tool (rest argv) :search nil :input nil
                  :output stdout :error stderr :wait t)
               (error (condition)
                 (pp.runtime:language-fail
                  (format nil "run: ~A" condition)
                  "runtime.process"))))
           (exit (or (sb-ext:process-exit-code process) 1))
           (out (get-output-stream-string stdout))
           (err (get-output-stream-string stderr)))
      (pp.runtime:runtime-observation-record
       (pp.kernel:make-cell-tool tool)
       (%command-tool-observed-hash tool))
      (%command-record-event
       "run"
       (list
        (cons (pp.kernel:make-vkeyword "tool")
              (pp.kernel:make-vstring tool))
        (cons (pp.kernel:make-vkeyword "args")
              (pp.kernel:make-vvector-from-list
               (mapcar #'pp.kernel:make-vstring argv)))
        (cons (pp.kernel:make-vkeyword "exit")
              (pp.kernel:make-vint exit))))
      (pp.kernel:make-vmap
       (list (cons (pp.kernel:make-vstring "exit")
                   (pp.kernel:make-vint exit))
             (cons (pp.kernel:make-vstring "out")
                   (pp.kernel:make-vstring out))
             (cons (pp.kernel:make-vstring "err")
                   (pp.kernel:make-vstring err)))))))

(defun %command-symlink-p (path)
  #+sbcl
  (handler-case
      (= (logand (sb-posix:stat-mode (sb-posix:lstat path))
                 sb-posix:s-ifmt)
         sb-posix:s-iflnk)
    (error () nil))
  #-sbcl
  nil)

 (defun %command-invalidate-file-pins (session canonical)
  (when session
    (pp.runtime:runtime-session-iter-run-pins
     session
     (lambda (cell-id ignored-hash)
       (declare (ignore ignored-hash))
       (handler-case
           (let ((cell (pp.kernel:cell-parse cell-id)))
             (when (and (typep cell 'pp.kernel:cell-file)
                        (string= (pp.kernel:cell-file-value cell) canonical))
               (pp.runtime:runtime-session-remove-run-pin session cell-id)))
         (error () nil))))))

(defun %command-path-prefix-p (root path)
  (let ((root (string-right-trim "/" root)))
    (or (string= root path)
        (and (> (length path) (length root))
             (string= root path :end2 (length root))
             (char= (char path (length root)) #\/)))))

(defun %command-file-write-root (path)
  (let ((roots
          (mapcan
           (lambda (capability)
             (mapcar
              (lambda (entry)
                (cons (pp.kernel:canonical-path-to-string (car entry))
                      (cdr entry)))
              (pp.kernel:capability-list-fs-paths capability)))
           (%command-current-capabilities))))
    (car (sort
          (remove-if-not
           (lambda (entry)
             (and (member (cdr entry) '(:write :read-write))
                  (%command-path-prefix-p (car entry) path)))
           roots)
          #'> :key (lambda (entry) (length (car entry)))))))

#+sbcl
(defun %command-prune-empty-file-parents (path)
  (let ((root (and (%command-file-write-root path)
                   (car (%command-file-write-root path))))
        (parent (directory-namestring (pathname path))))
    (when root
      (loop while (and (not (string= parent root))
                       (%command-path-prefix-p root parent)
                       (pp.runtime::store-secure-directory-p parent))
            do (let ((entries
                       (remove-duplicates
                        (append (directory (merge-pathnames "*" parent))
                                (directory (merge-pathnames "*.*" parent)))
                        :test #'equal :key #'namestring)))
                 (when entries (return))
                 (sb-posix:rmdir parent)
                 (setf parent
                       (namestring
                        (make-pathname
                         :directory
                         (butlast (pathname-directory (pathname parent)))
                         :name nil :type nil))))))))

#-sbcl
(defun %command-prune-empty-file-parents (path)
  (declare (ignore path)))

(defun %command-remove-file-effect (arguments)
  (unless (= (length arguments) 1)
    (pp.runtime:language-fail
     "remove-file expects a path string" "primitive.arity"))
  (let* ((path (%command-strict-text (first arguments) "remove-file"))
         (absolute (pp.runtime:store-absolute-path path)))
    (when (%command-symlink-p absolute)
      (pp.runtime:language-fail
       (format nil "remove-file: refusing symlink path (capability denied): ~A"
               absolute)
       "runtime.authority"))
    (let ((canonical (pp.runtime:store-canonical-path absolute)))
      (unless (some
               (lambda (capability)
                 (pp.kernel:capability-check-fs-write-p
                  capability
                  (pp.kernel:canonicalize-path
                   canonical :realpath #'pp.runtime:store-canonical-path)))
               (%command-current-capabilities))
        (pp.runtime:language-fail
         (format nil "remove-file: capability error: no write access for ~A"
                 canonical)
         "runtime.authority"))
      #+sbcl
      (when (probe-file canonical)
        (unless (pp.runtime::store-secure-directory-p
                 (directory-namestring (pathname canonical)))
          (pp.runtime:language-fail
           (format nil "remove-file: unsafe parent: ~A" canonical)
           "runtime.authority"))
        (sb-posix:unlink canonical))
      #-sbcl (ignore-errors (delete-file canonical))
      (%command-prune-empty-file-parents canonical)
      (%command-invalidate-file-pins
       (pp.runtime:runtime-observation-session) canonical)
      (%command-record-event "remove-file" nil)
      (pp.kernel:make-vnil))))

 (defun %command-write-file-effect (arguments)
  (unless (= (length arguments) 2)
    (pp.runtime:language-fail
     "write-file expects path and content strings"
     "primitive.arity"))
  (let* ((path (%command-strict-text (first arguments) "write-file"))
         (content (%command-strict-text (second arguments) "write-file"))
         (in-node (pp.runtime:runtime-dynamic-in-node-p))
         (scratch
           (and in-node
                (pp.runtime:runtime-sandbox-relative-p path)
                (ignore-errors
                  (pp.runtime:runtime-sandbox-resolve path :create t))))
         (absolute (and (not in-node)
                        (pp.runtime:store-absolute-path path))))
    (cond
      (in-node
       (unless scratch
         (pp.runtime:language-fail
          (format nil "write-file: node writes are sandbox-scratch only (LAW 18): ~A"
                  path)
          "runtime.tier"))
       (handler-case
           (pp.runtime:store-atomic-replace scratch content)
         (error (condition)
           (pp.runtime:language-fail
            (format nil "write-file: ~A" condition)
            "runtime.effect")))
       (pp.kernel:make-vnil))
      ((%command-symlink-p absolute)
       (pp.runtime:language-fail
        (format nil "write-file: refusing symlink path (capability denied): ~A"
                absolute)
        "runtime.authority"))
      (t
       (let ((canonical (pp.runtime:store-canonical-path absolute)))
         (unless (some (lambda (capability)
                         (pp.kernel:capability-check-fs-write-p
                          capability
                          (pp.kernel:canonicalize-path
                           canonical :realpath #'pp.runtime:store-canonical-path)))
                       (%command-current-capabilities))
           (pp.runtime:language-fail
            (format nil "write-file: capability error: no write access for ~A"
                    canonical)
            "runtime.authority"))
         ;; Materialization may introduce nested paths beneath an authorized
         ;; root; create only after the canonical capability check.
         (pp.runtime:store-ensure-directory
          (directory-namestring (pathname canonical)))
         (handler-case
             (pp.runtime:store-atomic-replace canonical content)
           (error (condition)
             (pp.runtime:language-fail
              (format nil "write-file: ~A" condition)
              "runtime.effect")))
         (%command-invalidate-file-pins
          (pp.runtime:runtime-observation-session) canonical)
         (%command-record-event
          "write-file"
          (list (cons (pp.kernel:make-vkeyword "path")
                      (pp.kernel:make-vstring canonical))
                (cons (pp.kernel:make-vkeyword "hash")
                      (pp.kernel:make-vstring
                       (pp.runtime:store-hash-content content)))))
         (pp.kernel:make-vnil))))))

(defun %command-process-required ()
  (unless (some #'pp.kernel:capability-check-process-p
                (%command-current-capabilities))
    (pp.runtime:language-fail
     "capability error: no process authority"
     "runtime.authority"))
  t)

 (defun %command-closed-map-field (value name required)
  (let ((field (%command-map-field value name)))
    (when (and required (null field))
      (pp.runtime:language-fail
       (format nil "run-closed!: requires :~A" name)
       "runtime.closed"))
    field))

(defun %command-closed-vector-text (value name)
  (let ((items
          (cond
            ((typep value 'pp.kernel:value-vector)
             (coerce (pp.kernel:value-vector-values value) 'list))
            ((pp.runtime:proper-value-list-p value)
             (pp.runtime:proper-value-list value))
            (t
             (pp.runtime:language-fail
              (format nil "run-closed!: :~A must be a vector or list" name)
              "runtime.closed")))))
    (mapcar
     (lambda (item)
       (%command-strict-text item (format nil "run-closed!: :~A" name)))
     items)))

(defun %command-closed-environment (value)
  (unless (typep value 'pp.kernel:value-map)
    (pp.runtime:language-fail
     "run-closed!: :env must be a map" "runtime.closed"))
  (mapcar
   (lambda (entry)
     (let ((name (car entry))
           (value (cdr entry)))
       (unless (typep name 'pp.kernel:value-string)
         (pp.runtime:language-fail
          "run-closed!: invalid environment name" "runtime.closed"))
       (let ((name (pp.kernel:value-string-value name)))
         (unless (and (plusp (length name))
                      (not (find #\Null name))
                      (not (find #\Newline name))
                      (not (find #\Return name))
                      (not (find #\= name)))
           (pp.runtime:language-fail
            "run-closed!: invalid environment name" "runtime.closed"))
         (cons name
               (%command-strict-text value "run-closed!: environment")))))
   (pp.kernel:value-map-entries value)))

 (defun %command-closed-tree (value label &optional allow-implicit-parents)
  (handler-case
      (pp.runtime:runtime-artifact-tree-from-value
       value :require-parents (not allow-implicit-parents))
    (error (condition)
      (pp.runtime:language-fail
       (format nil "run-closed!: ~A: ~A" label condition)
       "runtime.closed"))))

 (defun %command-closed-request (value)
  (%command-process-required)
  (unless (typep value 'pp.kernel:value-map)
    (pp.runtime:language-fail
     "run-closed!: expects a request map" "runtime.closed"))
  (let* ((tool (%command-closed-map-field value "tool" t))
         (tool-path (%command-strict-text
                     (%command-closed-map-field value "tool-path" t)
                     "run-closed!: :tool-path"))
         (arguments (%command-closed-vector-text
                     (%command-closed-map-field value "args" t) "args"))
         (inputs (%command-closed-map-field value "inputs" t))
         (environment (%command-closed-environment
                       (%command-closed-map-field value "env" t)))
         (platform (%command-closed-map-field value "platform" t))
         (policy (%command-map-field value "policy"))
         (outputs (%command-closed-vector-text
                   (%command-closed-map-field value "outputs" t) "outputs"))
         (seen-outputs (make-hash-table :test #'equal)))
    (unless (and (plusp (length tool-path))
                 (not (find #\Null tool-path))
                 (not (find #\Newline tool-path))
                 (not (find #\Return tool-path)))
      (pp.runtime:language-fail
       "run-closed!: invalid tool path" "runtime.closed"))
    (dolist (argument arguments)
      (when (or (find #\Null argument)
                (find #\Newline argument)
                (find #\Return argument))
        (pp.runtime:language-fail
         "run-closed!: invalid argument" "runtime.closed")))
    (%command-closed-tree tool "tool tree" t)
    (%command-closed-tree inputs "input tree")
    (dolist (path outputs)
      (unless (pp.runtime:runtime-artifact-valid-path-p path)
        (pp.runtime:language-fail
         (format nil "run-closed!: rejects non-canonical output path: ~A" path)
         "runtime.closed"))
      (when (gethash path seen-outputs)
        (pp.runtime:language-fail
         (format nil "run-closed!: duplicate output path: ~A" path)
         "runtime.closed"))
      (setf (gethash path seen-outputs) t))
    (unless (pp.runtime:runtime-executor-request-data-p platform)
      (pp.runtime:language-fail
       "run-closed!: :platform must be canonical data" "runtime.closed"))
    (let ((platform-os
            (%command-strict-text
             (%command-closed-map-field platform "os" t)
             "run-closed!: :platform")))
      (unless (string= platform-os "linux")
        (pp.runtime:language-fail
         "run-closed!: requires :platform linux" "runtime.closed")))
    (when (and policy
               (not (pp.runtime:runtime-executor-request-data-p policy)))
      (pp.runtime:language-fail
       "run-closed!: expects :policy to be canonical data" "runtime.closed"))
    (pp.runtime:make-runtime-executor-request
     :tool tool :tool-path tool-path :arguments arguments :inputs inputs
     :environment environment :platform platform :policy policy :outputs outputs)))

 (defun %command-closed-result-value (result)
  (pp.kernel:make-vmap
   (list (cons (pp.kernel:make-vstring "exit")
               (pp.kernel:make-vint
                (pp.runtime:runtime-executor-result-exit-status result)))
         (cons (pp.kernel:make-vstring "stdout")
               (pp.kernel:make-vstring
                (pp.runtime:runtime-executor-result-stdout result)))
         (cons (pp.kernel:make-vstring "stderr")
               (pp.kernel:make-vstring
                (pp.runtime:runtime-executor-result-stderr result)))
         (cons (pp.kernel:make-vstring "outputs")
               (pp.runtime:runtime-artifact-tree-to-value
                (pp.runtime:runtime-executor-result-outputs result)))
         (cons (pp.kernel:make-vstring "evidence")
               (pp.kernel:make-vmap
                (mapcar (lambda (pair)
                          (cons (pp.kernel:make-vstring (car pair))
                                (pp.kernel:make-vstring (cdr pair))))
                        (pp.runtime:runtime-executor-result-evidence result))))
         (cons (pp.kernel:make-vstring "resources")
               (pp.kernel:make-vmap
                (mapcar (lambda (pair)
                          (cons (pp.kernel:make-vstring (car pair))
                                (pp.kernel:make-vstring (cdr pair))))
                        (pp.runtime:runtime-executor-result-resources result)))))))

 (defun %command-closed-executor ()
  ;; The host provider deliberately reports its ambient clock/randomness and
  ;; resource semantics as scripting-only.  A trusted Linux provider may be
  ;; installed by an embedding application; the command image fails closed.
  (pp.runtime:make-runtime-executor
   :classify (lambda (request)
               (declare (ignore request))
               (pp.runtime:make-runtime-executor-scripting-only
                "executor classifies this request as scripting-only"))
   :execute (lambda (request)
              (declare (ignore request))
              (error "closed Linux runner unavailable"))))
(defun %command-record-handler-observation (name)
  (let ((observed (pp.runtime:runtime-dynamic-observe-handler name)))
    (pp.runtime:runtime-observation-record
     (pp.kernel:make-cell-handler name)
     (if (pp.runtime:store-digest-p observed)
         observed
         (pp.kernel:hash-string observed)))))


(defun %command-install-primitive (state name function)
  (setf (pp.runtime:runtime-evaluator-state-initial-env state)
        (pp.runtime::runtime-evaluator-env-extend
         (pp.runtime:runtime-evaluator-state-initial-env state)
         name (make-vbuiltin name function))))

(defun %command-map-field (value name)
  (and (typep value 'pp.kernel:value-map)
       (let ((entry (find-if
                     (lambda (item)
                       (let ((key (car item)))
                         (and (or (typep key 'pp.kernel:value-string)
                                  (typep key 'pp.kernel:value-keyword))
                              (string= name
                                       (if (typep key 'pp.kernel:value-string)
                                           (pp.kernel:value-string-value key)
                                           (pp.kernel:value-keyword-value key))))))
                     (pp.kernel:value-map-entries value))))
         (and entry (cdr entry)))))

(defun %command-register-domain (session value force)
  (let* ((value (funcall force value))
         (name (%command-value-text (%command-map-field value "name")
                                    "register-domain name"))
         (namespace-value (funcall force
                                   (%command-map-field value "namespace")))
         (namespace
           (cond
             ((typep namespace-value 'pp.kernel:value-vector)
              (map 'list (lambda (item)
                           (%command-value-text (funcall force item)
                                                "register-domain namespace"))
                   (pp.kernel:value-vector-values namespace-value)))
             ((typep namespace-value 'pp.kernel:value-pair)
              (labels ((collect (item)
                         (let ((item (funcall force item)))
                           (cond
                             ((typep item 'pp.kernel:value-nil) nil)
                             ((typep item 'pp.kernel:value-pair)
                              (cons (%command-value-text
                                     (funcall force (pp.kernel:value-pair-car item))
                                     "register-domain namespace")
                                    (collect (pp.kernel:value-pair-cdr item))))
                             (t (error "register-domain namespace must be a list"))))))
                (collect namespace-value)))
             (t (error "register-domain namespace must be a vector or list"))))
         (observe (funcall force (%command-map-field value "observe")))
         (diff (funcall force (%command-map-field value "diff")))
         (apply-fn (funcall force (%command-map-field value "apply")))
         (cap (let ((entry (%command-map-field value "write-cap")))
                ;; Unwrap the pp value: the domain scope must push a kernel
                ;; capability, or capability checks cannot see it.
                (and entry (let ((forced (funcall force entry)))
                             (if (typep forced 'pp.kernel:value-capability)
                                 (pp.kernel:value-capability-capability forced)
                                 forced))))))
    (unless (and observe diff apply-fn)
      (error "register-domain requires observe, diff, and apply"))
    (runtime-session-register-domain
     session name
     (make-runtime-domain-entry
      :namespace namespace :observe observe :diff diff :apply apply-fn :cap cap))
    (pp.kernel:make-vnil)))
(defun %command-http-prefix-p (prefix url)
  (and (>= (length url) (length prefix))
       (string= prefix url :end2 (length prefix))))

(defun %command-http-target (url)
  (unless (or (%command-http-prefix-p "http://" url)
              (%command-http-prefix-p "https://" url))
    (error "http URL must use http:// or https://"))
  (let* ((authority-start (if (%command-http-prefix-p "https://" url) 8 7))
         (authority-end (or (cl:position #\/ url :start authority-start)
                            (length url)))
         (authority (subseq url authority-start authority-end))
         (colon (cl:position #\: authority :from-end t))
         (host (if colon (subseq authority 0 colon) authority))
         (port (if colon
                   (parse-integer authority :start (1+ colon))
                   (if (%command-http-prefix-p "https://" url) 443 80))))
    (unless (plusp (length host))
      (error "http URL has no host"))
    (values host port)))

(defun %command-http-effect (name arguments)
  (let* ((url (%command-strict-text (first arguments) name))
         (body (and (string= name "http-post")
                    (%command-strict-text (second arguments) name))))
    (multiple-value-bind (host port) (%command-http-target url)
      (unless (some (lambda (capability)
                      (pp.kernel:capability-check-network-p
                       capability host port))
                    (%command-current-capabilities))
        (pp.runtime:language-fail
         (format nil "~A: capability error for ~A:~D" name host port)
         "runtime.authority"))
      (let ((argv (append (list "curl" "-sS" "-w" "\\n%{http_code}")
                          (if body (list "-X" "POST" "-d" body) nil)
                          (list url))))
        (let ((result
                (ignore-errors
                  (multiple-value-list
                   (pp.runtime::runtime-process-exec argv)))))
          (if (null result)
              (pp.runtime:language-fail
               "curl not found" "runtime.network")
              (destructuring-bind (exit output stderr) result
                (declare (ignore stderr))
                (unless (zerop exit)
                  (pp.runtime:language-fail
                   (format nil "~A: curl exited ~D" name exit)
                   "runtime.network"))
                (let* ((split (cl:position #\Newline output :from-end t))
                       (text (if split (subseq output 0 split) output))
                       (status (if split
                                   (parse-integer output :start (1+ split))
                                   0)))
                  (pp.kernel:make-vmap
                   (list (cons (pp.kernel:make-vstring "status")
                               (pp.kernel:make-vint status))
                         (cons (pp.kernel:make-vstring "body")
                               (pp.kernel:make-vstring text)))))))))

)
))
(defun %command-install-observation-primitives (session error-output)
  "Install command-tier observations without changing the pure catalog."
  (let ((state (pp.runtime:runtime-session-evaluator session)))
    (labels ((extend (name function)
               (setf (pp.runtime:runtime-evaluator-state-initial-env state)
                     (pp.runtime::runtime-evaluator-env-extend
                      (pp.runtime:runtime-evaluator-state-initial-env state)
                      name (pp.kernel:make-vbuiltin name function))))
             (one-text (args force name)
               (unless (= (length args) 1)
                 (pp.runtime:language-fail
                  (format nil "~A expects one argument" name)
                  "primitive.arity"))
               (%command-value-text
                (%command-force-argument (first args) force) name)))
      (extend
       "slurp"
       (lambda (args environment &key force &allow-other-keys)
         (declare (ignore environment))
         (let* ((path (one-text args force "slurp"))
                (sealed (%command-file-sealed-p path)))
           (%command-read-file-value path sealed))))
      (extend
       "blob"
       (lambda (args environment &key force &allow-other-keys)
         (declare (ignore environment))
         (unless (= (length args) 1)
           (pp.runtime:language-fail "blob expects one argument" "primitive.arity"))
         (let ((value (%command-force-argument (first args) force)))
           (cond
             ((typep value 'pp.kernel:value-string)
              (pp.kernel:make-vstring
               (pp.runtime::runtime-artifact-blob-put
                (pp.kernel:value-string-value value))))
             ;; A malformed-UTF-8 `slurp` is represented as sealed raw bytes
             ;; so opaque tool blobs retain their executable bytes.
             ((typep value 'pp.kernel:value-sealed)
              (pp.kernel:make-vstring
               (pp.runtime::runtime-artifact-blob-put
                (pp.runtime::store-codec-string-octets
                 (pp.kernel:value-sealed-bytes value)))))
             (t
              (pp.runtime:language-fail "blob expects a string"
                                        "primitive.type"))))))
      (extend
       "blob-get"
       (lambda (args environment &key force &allow-other-keys)
         (declare (ignore environment))
         (unless (= (length args) 1)
           (pp.runtime:language-fail "blob-get expects one argument"
                                     "primitive.arity"))
         (let ((hash (one-text args force "blob-get")))
           (pp.kernel:make-vstring
            (pp.runtime:store-octets-string
             (pp.runtime:runtime-artifact-blob-get hash))))))
      (extend
       "unseal"
       (lambda (args environment &key force &allow-other-keys)
         (declare (ignore environment))
         (unless (= (length args) 1)
           (pp.runtime:language-fail
            "unseal expects one argument"
            "primitive.arity"))
         (%command-unseal-value
          (%command-force-argument (first args) force))))
      (extend
       "env-get"
       (lambda (args environment &key force &allow-other-keys)
         (declare (ignore environment))
         (let* ((name (one-text args force "env-get"))
                (value (and (fboundp 'sb-ext:posix-getenv)
                            (sb-ext:posix-getenv name))))
           (pp.runtime:runtime-observation-record
            (pp.kernel:make-cell-env name)
            (or (and value (pp.kernel:hash-string value))
                "env-cell:absent"))
           (if value (pp.kernel:make-vstring value)
               (pp.kernel:make-vnil)))))
      (extend
       "probe"
       (lambda (args environment &key force &allow-other-keys)
         (declare (ignore environment))
         (let ((name (one-text args force "probe")))
           (or (pp.runtime:runtime-observation-probe name)
               (pp.kernel:make-vnil)))))
      (extend
       "config"
       (lambda (args environment &key force &allow-other-keys)
         (declare (ignore environment))
         (unless (member (length args) '(1 2))
           (pp.runtime:language-fail "config expects one or two arguments"
                                     "primitive.arity"))
         (let ((key (one-text (list (first args)) force "config")))
           (multiple-value-bind (value present)
               (pp.runtime:runtime-configuration-read key)
             (pp.runtime:runtime-observation-record
              (pp.kernel:make-cell-config key)
              (if present (pp.kernel:hash-value value) "config-cell:absent"))
             (if present value
                 (if (= (length args) 2)
                     (%command-force-argument (second args) force)
                     (pp.kernel:make-vnil)))))))

    (%command-install-primitive
     state "fenced"
     (lambda (args environment &key force &allow-other-keys)
       (declare (ignore environment))
       (unless (= (length args) 2)
         (pp.runtime:language-fail "fenced expects kind and spec"
                                   "primitive.arity"))
       (let ((kind (%command-strict-text
                    (funcall force (first args)) "fenced kind"))
             (spec (funcall force (second args))))
         (runtime-lifecycle-fenced session kind spec)
         (pp.kernel:make-vnil))))
    (%command-install-primitive
     state "register-domain"
     (lambda (args environment &key force &allow-other-keys)
       (declare (ignore environment))
       (unless (= (length args) 1)
         (pp.runtime:language-fail "register-domain expects one argument"
                                   "primitive.arity"))
       (%command-register-domain session (first args) (or force #'identity))))
(defun %command-log-text (value)
  ;; log is a presentation observation: non-text values render through the
  ;; canonical value printer instead of failing (tests/002, tests/070).
  (if (typep value '(or pp.kernel:value-string pp.kernel:value-symbol
                        pp.kernel:value-keyword))
      (%command-value-text value "log")
      (pp.runtime:runtime-string-of-value value)))

    (%command-install-primitive
     state "register-probe"
     (lambda (args environment &key force &allow-other-keys)
       (pp.runtime:runtime-dynamic-require-script-tier
        "register-probe: may not be called inside a node body (scripting-tier only)")
       (unless (= (length args) 3)
         (pp.runtime:language-fail "register-probe expects name, observe, cap"
                                   "primitive.arity"))
       (let ((name (%command-strict-text
                    (funcall force (first args)) "register-probe name"))
             (observe (funcall force (second args)))
             (cap-value (funcall force (third args))))
         (let ((cap (if (typep cap-value 'pp.kernel:value-capability)
                        (pp.kernel:value-capability-capability cap-value)
                        cap-value)))
           (unless (pp.runtime:runtime-session-find-probe session name)
             (pp.runtime:runtime-session-set-probe session name nil))
           (runtime-session-register-probe
            session name
            (make-runtime-domain-entry :observe observe :cap cap))
           (pp.kernel:make-vnil)))))

      (pp.runtime:runtime-session-register-callback
       session :perform
       (lambda (ignored-state name arguments environment)
         (declare (ignore ignored-state environment))
         (%command-record-handler-observation name)

         (cond
          ((string= name "run-closed!")
           (unless (= (length arguments) 1)
             (pp.runtime:language-fail
              "run-closed! expects one request" "primitive.arity"))
           (%command-closed-result-value
            (pp.runtime:runtime-executor-run-in-session
             session
             (%command-closed-request (first arguments)))))
          ((string= name "log")
           (unless (member (length arguments) '(1 2))
             (pp.runtime:language-fail "log expects one or two arguments"
                                       "primitive.arity"))
           (let* ((state (pp.runtime:runtime-session-evaluator session))
                  (values (mapcar
                           (lambda (argument)
                             (pp.runtime:runtime-evaluator-force
                              state argument))
                           arguments)))
             (let ((stream (or *command-effect-output* error-output)))
               (format stream "[~A] ~A~%"
                       (if (= (length values) 2)
                           (%command-log-text (first values))
                           "info")
                       (%command-log-text (car (last values))))
               (finish-output stream))
             (pp.kernel:make-vnil)))
          ((string= name "read-file")
           (unless (= (length arguments) 1)
             (pp.runtime:language-fail "read-file expects one argument"
                                       "primitive.arity"))
           (let* ((path (%command-value-text (first arguments) "read-file"))
                  (sealed (%command-file-sealed-p path)))
             (%command-read-file-value path sealed)))
          ((string= name "http-get")
           (unless (= (length arguments) 1)
             (pp.runtime:language-fail
              "http-get expects one URL" "primitive.arity"))
           (pp.runtime:runtime-dynamic-require-script-tier
            "http-get: may not appear inside node bodies")
           (%command-http-effect name arguments))
          ((string= name "http-post")
           (unless (= (length arguments) 2)
             (pp.runtime:language-fail
              "http-post expects URL and body" "primitive.arity"))
           (pp.runtime:runtime-dynamic-require-script-tier
            "http-post: may not appear inside node bodies")
           (%command-http-effect name arguments))
          ((string= name "tree-observe")
           (unless (= (length arguments) 1)
             (pp.runtime:language-fail "tree-observe expects one argument"
                                       "primitive.arity"))
           (let* ((path (%command-value-text (first arguments) "tree-observe"))
                  (tree (or (pp.runtime::runtime-artifact-observe-value path)
                            (pp.runtime:language-fail
                             (format nil "tree-observe: cannot read ~A" path)
                             "runtime.observation")))
                  (hash (pp.kernel:hash-value tree)))
             (pp.runtime:runtime-observation-record
              (pp.kernel:make-cell-tree path) hash)
             tree))
          ((string= name "materialize-file")
           (unless (= (length arguments) 2)
             (pp.runtime:language-fail
              "materialize-file expects path and content" "primitive.arity"))
           (%command-write-file-effect arguments))
          ((string= name "remove-file")
           (unless (= (length arguments) 1)
             (pp.runtime:language-fail "remove-file expects one argument"
                                       "primitive.arity"))
           (%command-remove-file-effect arguments))
          ((string= name "domain-state-get")
           (unless (member (length arguments) '(1 2))
             (pp.runtime:language-fail
              "domain-state-get expects key or domain and key"
              "primitive.arity"))
           (let* ((domain (if (= (length arguments) 1)
                              (pp.runtime:runtime-dynamic-current-domain)
                              (%command-strict-text
                               (first arguments)
                               "domain-state-get domain")))
                  (key (if (= (length arguments) 1)
                           (%command-strict-text
                            (first arguments)
                            "domain-state-get key")
                           (%command-strict-text
                            (second arguments)
                            "domain-state-get key"))))
             (or (pp.runtime::runtime-domain-state-get session domain key)
                 (pp.kernel:make-vnil))))
          ((string= name "domain-state-put")
           (unless (member (length arguments) '(2 3))
             (pp.runtime:language-fail
              "domain-state-put expects key, value, or domain, key, value"
              "primitive.arity"))
           (let* ((domain (if (= (length arguments) 2)
                              (pp.runtime:runtime-dynamic-current-domain)
                              (%command-strict-text
                               (first arguments)
                               "domain-state-put domain")))
                  (key (if (= (length arguments) 2)
                           (%command-strict-text
                            (first arguments)
                            "domain-state-put key")
                           (%command-strict-text
                            (second arguments)
                            "domain-state-put key")))
                  (value (if (= (length arguments) 2)
                             (second arguments)
                             (third arguments))))
             (pp.runtime::runtime-domain-state-put session domain key value)
             (pp.kernel:make-vnil)))
          ((string= name "run")
           (%command-run-effect arguments))
          ((string= name "write-file")
           (%command-write-file-effect arguments))
          ((string= name "proc-spawn")
           (unless (= (length arguments) 1)
             (pp.runtime:language-fail "proc-spawn expects a spec"
                                       "primitive.arity"))
           (%command-process-required)
           (let* ((spec (first arguments))
                  (service-name
                    (%command-value-text
                     (or (%command-process-spec-field spec "name")
                         (pp.kernel:make-vstring "service"))
                     "proc-spawn name"))
                  (record (pp.runtime:runtime-process-start-service
                           session service-name spec)))
             (pp.kernel:make-vint
              (pp.runtime:runtime-process-record-pid record))))
          ((string= name "proc-alive?")
           (unless (= (length arguments) 1)
             (pp.runtime:language-fail "proc-alive? expects a pid"
                                       "primitive.arity"))
           (pp.kernel:make-vbool
            (pp.runtime:runtime-process-alive-p
             (pp.kernel:value-int-value (first arguments)))))
          ((string= name "proc-stop")
           (unless (= (length arguments) 2)
             (pp.runtime:language-fail "proc-stop expects name and pid"
                                       "primitive.arity"))
           (%command-process-required)
           (let* ((service-name (%command-value-text
                                 (first arguments) "proc-stop name"))
                  (record (pp.runtime::runtime-process-record
                           session service-name)))
             (when record
               (pp.runtime:runtime-process-stop-service
                session service-name record))
             (pp.kernel:make-vnil)))
          ((string= name "proc-reap")
           (unless (null arguments)
             (pp.runtime:language-fail "proc-reap takes no arguments"
                                       "primitive.arity"))
           (%command-process-required)
           (%command-record-event "proc-reap" nil)
           (pp.kernel:make-vnil))
          (t (pp.runtime:language-fail
              (format nil "unhandled effect: ~A" name)
              "runtime.effect")))))
      session)))


(defun %command-parse-policy (text)
  (handler-case
      (make-distribution-policy :kind text)
    (error (condition)
      (error "schedule: ~A" condition))))

(defun %command-runtime-policy (text)
  (let ((policy (if (typep text 'distribution-policy)
                    text
                    (%command-parse-policy text))))
    policy))

(defun %command-runtime-manifest-schedule (session fallback override)
  "Return the active host policy and optional pp custom callback.

The manifest is deliberately inspected at the node boundary: configuration
usually precedes the first force in a source block, while the scheduler must
already exist so that such a force has a callback installed.  CLI policy is
an explicit authority override and therefore bypasses the manifest."
  (if override
      (values fallback nil)
      (let* ((manifest (runtime-session-runtime-manifest session))
             (schedule (and manifest
                            (%command-map-field manifest "schedule"))))
        (if (null schedule)
            (values fallback nil)
            (let* ((kind-value (%command-map-field schedule "kind"))
                   (kind (%command-value-text kind-value "runtime schedule kind")))
              (cond
                ((string= kind "serial")
                 (values (%command-runtime-policy "serial") nil))
                ((member kind '("parallel" "race") :test #'string=)
                 (let ((width-value (%command-map-field schedule "width")))
                   (unless (typep width-value 'value-int)
                     (error "runtime schedule :width must be a positive integer"))
                   (values
                    (%command-runtime-policy
                     (format nil "~A:~D" kind (value-int-value width-value)))
                    nil)))
                ((string= kind "custom")
                 (let ((callback (%command-map-field schedule "policy")))
                   (unless (pp.runtime::runtime-manifest-function-p callback)
                     (error "runtime schedule :policy must be a function"))
                   (values (%command-runtime-policy "serial") callback)))
                (t (error "runtime schedule has unknown kind: ~A" kind))))))))

(defun %command-custom-schedule-policy (session callback jobs)
  "Validate CALLBACK's data-only partition and return a host policy."
  (let* ((state (runtime-session-evaluator session))
         (descriptors
           (make-vvector-from-list
            (mapcar (lambda (job) (distribution-job-descriptor job)) jobs)))
         (raw (runtime-session-call
               session callback (list descriptors)
               (runtime-session-global-env session)))
         (result (runtime-evaluator-force-deep state raw))
         (mode-value (%command-map-field result "mode"))
         (batches-value (%command-map-field result "batches"))
         (mode (%command-value-text mode-value "custom scheduler mode"))
         (width-value (%command-map-field result "width"))
         (width (if width-value
                    (progn
                      (unless (and (typep width-value 'value-int)
                                   (plusp (value-int-value width-value)))
                        (error "custom scheduler width must be a positive integer"))
                      (value-int-value width-value))
                    1))
         (seen (make-array (length jobs) :initial-element nil)))
    (unless (typep result 'value-map)
      (error "custom scheduler must return a map"))
    (unless (member mode '("serial" "parallel" "race") :test #'string=)
      (error "custom scheduler returned an unknown mode: ~A" mode))
    (unless (typep batches-value 'value-vector)
      (error "custom scheduler must return vector batches"))
    (loop for batch across (value-vector-values batches-value) do
      (unless (typep batch 'value-vector)
        (error "custom scheduler batches must be vectors"))
      (loop for index-value across (value-vector-values batch) do
        (unless (and (typep index-value 'value-int)
                     (<= 0 (value-int-value index-value))
                     (< (value-int-value index-value) (length jobs)))
          (error "custom scheduler indexes must be in range"))
        (let ((index (value-int-value index-value)))
          (when (aref seen index)
            (error "custom scheduler must schedule every job exactly once"))
          (setf (aref seen index) t))))
    (unless (every #'identity seen)
      (error "custom scheduler must schedule every job exactly once"))
    (%command-runtime-policy
     (if (string= mode "serial")
         "serial"
         (format nil "~A:~D" mode width)))))

(defun %command-schedule-node-force (session policy &key override)
  "Install the distribution scheduler at the persistent-node boundary."
  (let* (
         ;; One injection path: the scheduler replaces the session's
         ;; :node-force service in front of the pinned pristine backend, so
         ;; re-installation never wraps a previous scheduler wrapper.
         (base (or (let ((pinned (runtime-session-find-service session :node-force-base)))
                     (and pinned (funcall pinned)))
                   (let ((current (runtime-session-find-service session :node-force)))
                     (and current (lambda (state thunk key run observer)
                                    (funcall current state thunk key run observer))))))
         (jobs (make-hash-table :test #'equal))
         (scheduler nil))
    (unless (functionp base)
      (error "schedule: persistent node backend is unavailable"))
    (runtime-session-register-service session :node-force-base (lambda () base))
    (setf scheduler
          (make-distribution-scheduler
           :policy policy
           :runner
           (lambda (job)
             (let* ((key (distribution-job-key job))
                    (entry (gethash key jobs)))
               (unless entry
                 (distribution-fail "schedule" "worker job is not registered"))
               (destructuring-bind (run-state thunk node-key run) entry
                 (let ((old (runtime-session-schedule-locked-p session)))
                   (setf (runtime-session-schedule-locked-p session) t)
                   (unwind-protect
                        (funcall base
                                 run-state thunk node-key
                                 (lambda ()
                                   (runtime-sandbox-with-node
                                    node-key run :persistent t))
                                 nil)
                     (setf (runtime-session-schedule-locked-p session) old))))))))
    (runtime-session-register-service session :scheduler (lambda () scheduler))
    (runtime-session-register-callback
     session :node-force
     (lambda (run-state thunk node-key run observer)
       (if (or (runtime-session-schedule-locked-p session)
               ;; Observed forces (domain plan diffs) run inline: the
               ;; disposition must be reported to the caller, which the
               ;; job round-trip cannot carry.
               observer)
           (funcall base
                    run-state thunk node-key
                    (lambda ()
                      (runtime-sandbox-with-node
                       node-key run :persistent t))
                    observer)
           (let* ((key (pp.runtime::runtime-session-key node-key))
                  (closed (and (fboundp 'pp.runtime::runtime-node-data-closed-p)
                               (pp.runtime::runtime-node-data-closed-p run-state thunk)))
                  (job (make-distribution-job
                        :key key :width (distribution-policy-width policy)
                        :data-closed-p closed
                        :descriptor
                        (make-vmap
                         (canonical-map-entries
                          (list
                           (cons (make-vkeyword "key") (make-vstring key))
                           (cons (make-vkeyword "width")
                                 (make-vint (distribution-policy-width policy)))
                           (cons (make-vkeyword "data-closed")
                                 (make-vbool closed)))))))
                  (result nil)
                  (active-policy nil)
                  (custom nil))
             (multiple-value-setq (active-policy custom)
               (%command-runtime-manifest-schedule session policy override))
             (when custom
               (setf active-policy
                     (%command-custom-schedule-policy session custom (list job))))
             (setf (distribution-scheduler-policy scheduler) active-policy)
             (setf (gethash key jobs)
                   (list run-state thunk node-key run))
             (unwind-protect
                  (progn
                    (setf (runtime-session-schedule-locked-p session) t)
                    (setf result (first (distribution-run scheduler (list job)))))
               (setf (runtime-session-schedule-locked-p session) nil)
               (remhash key jobs))
             (unless (eq (distribution-result-status result) :ok)
               (if (fboundp 'language-fail)
                   (language-fail
                    (or (distribution-result-error result)
                        "scheduled node failed")
                    "runtime.node")
                   (error "scheduled node failed")))
             (distribution-result-payload result)))))
    scheduler))

(defun %command-runtime-schedule-event-p (event)
  (and (typep event 'value-map)
       (let ((kind (%command-map-field event "kind")))
         (and (typep kind 'value-keyword)
              (string= (value-keyword-value kind) "runtime-schedule")))))

(defun %command-report-runtime-events (session output &key suppress-schedule)
  "Invoke session reporters once with one deeply forced canonical vector."
  (let ((reporters (runtime-session-reporters session)))
    (when reporters
      (let* ((override-service (runtime-session-find-service
                                session :schedule-override))
             (suppress-schedule
               (or suppress-schedule
                   (and override-service (funcall override-service))))
             (events (runtime-session-events session))
             (events (if suppress-schedule
                         (remove-if #'%command-runtime-schedule-event-p events)
                         events))
             (state (runtime-session-evaluator session))
             (vector (runtime-evaluator-force-deep
                      state (make-vvector-from-list events))))
        (let ((*standard-output* output))
          (%command-dynamic-top-level
           session
           (lambda ()
             (dolist (reporter reporters)
               (runtime-evaluator-force-deep
                state
                (runtime-session-call
                 session reporter (list vector)
                 (runtime-session-global-env session)))))))))))

(defun %command-fenced-policy (text)
  (cond ((string= text "retry") :retry)
        ((string= text "abort") :abort)
        ((string= text "ask")
         (error "fenced: ask policy requires an interactive recovery command"))
        (t (error "--fenced-policy expects retry|abort|ask"))))
 (defun %command-runtime-options (arguments)
  "Extract lifecycle options while preserving ordinary command operands."
  (let ((rest nil) (watch nil) (once nil) (stabilize nil) (supervise nil)
        (interval 1.0) (policy "serial") (policy-explicit nil)
        (fenced :abort) (member-name nil) (pin-file nil) (dump-pins nil)
        (publish-root nil) (desired-object nil) (desired-shared-root nil))
    (loop while arguments do
      (let ((argument (pop arguments)))
        (cond
          ((string= argument "--watch") (setf watch t))
          ((string= argument "--once") (setf once t))
          ((string= argument "--stabilize") (setf stabilize t))
          ((string= argument "--supervise") (setf supervise t))
          ((string= argument "--watch-interval")
           (unless arguments (error "--watch-interval requires a number"))
           (setf interval (%parse-decimal (pop arguments)))
           (when (< interval 0) (error "--watch-interval must be nonnegative")))
          ((string= argument "--schedule")
           (unless arguments (error "--schedule requires a policy"))
           (setf policy (pop arguments)
                 policy-explicit t))
          ((string= argument "--fenced-policy")
           (unless arguments (error "--fenced-policy requires retry|abort|ask"))
           (setf fenced (%command-fenced-policy (pop arguments))))
          ((string= argument "--member-name")
           (unless arguments (error "--member-name requires a name"))
           (setf member-name (pop arguments)))
          ((string= argument "--pin-file")
           (unless arguments (error "--pin-file requires a path"))
           (setf pin-file (pop arguments)))
          ((string= argument "--dump-pins")
           (unless arguments (error "--dump-pins requires a path"))
           (setf dump-pins (pop arguments)))
          ((string= argument "--publish-object")
           (unless arguments (error "--publish-object requires a shared root"))
           (setf publish-root (pop arguments)))
          ((string= argument "--desired-object")
           (unless (>= (length arguments) 2)
             (error "--desired-object requires a hash and shared root"))
           (setf desired-object (pop arguments)
                 desired-shared-root (pop arguments)))
          (t (push argument rest)))))
    (when (and watch once)
      (error "--once cannot be combined with --watch"))
    (when (and stabilize (not watch))
      (error "--stabilize requires --watch"))
    (values (nreverse rest)
            (list :watch watch :once once :stabilize stabilize
                  :supervise supervise :interval interval
                  :policy policy :policy-explicit policy-explicit
                  :fenced fenced :member-name member-name
                  :pin-file pin-file :dump-pins dump-pins
                  :publish-root publish-root
                  :desired-object desired-object
                  :desired-shared-root desired-shared-root))))

(defun %command-recover-fenced (session policy error-output)
  (let ((count (runtime-fenced-recover-unknown session policy)))
    (when (plusp count)
      (format error-output "[fenced] ~D unknown-status action~:P in journal; applying policy=~(~A~)~%"
              count policy)
      (finish-output error-output))
    count))

(defun %command-install-process-services (session)
  (pp.runtime::runtime-process-records session)
  (runtime-session-register-domain
   session "proc" (pp.runtime::runtime-process-domain-entry session))
  session)

(defun %command-process-spec-field (spec name)
  (let ((entry (and (typep spec 'pp.kernel:value-map)
                    (find-if
                     (lambda (item)
                       (let ((key (car item)))
                         (and (typep key 'pp.kernel:value-string)
                              (string= name (pp.kernel:value-string-value key)))))
                     (pp.kernel:value-map-entries spec)))))
    (and entry (cdr entry))))


(defun %command-watch-trace-snapshot (session &optional source-paths)
  (%command-dynamic-top-level
   session
   (lambda ()
     (let ((result nil))
       (let ((pinned nil))
       (runtime-session-iter-run-pins
        session
        (lambda (cell ignored)
          (declare (ignore ignored))
          (push cell pinned)))
       (dolist (cell pinned)
         (runtime-session-remove-run-pin session cell)))
     (let ((service (runtime-session-find-service session :store-traces)))
       (when service
         (let ((traces (funcall service)))
           (dolist (key (trace-repository-keys traces))
             (dolist (trace (trace-repository-load traces :key key))
               (dolist (read (store-trace-reads trace))
                 (let* ((cell-id (store-identity-string
                                  (store-trace-read-cell read)))
                        (current (ignore-errors
                                   (runtime-observe-id cell-id))))
                   (when current
                     (push (cons cell-id (store-identity-string current))
                           result))))))))
       (dolist (observation (runtime-session-observations session))
         (let* ((cell-id (store-identity-string (car observation)))
                (current (ignore-errors (runtime-observe-id cell-id))))
           (when current
             (push (cons cell-id (store-identity-string current))
                   result))))
       (let ((records (pp.runtime::runtime-process-records session)))
           (maphash
            (lambda (name record)
              (runtime-process-reap record)
              (push (cons (format nil "proc:~A" name)
                          (if (runtime-process-alive-p
                               (runtime-process-record-pid record))
                              "alive"
                              "dead"))
                    result))
            records)))
       (dolist (path source-paths)
         (let ((text (ignore-errors (%read-source-file path))))
           (when text
             (push (cons (format nil "source:~A" path)
                         (pp.runtime:store-hash-content text))
                   result))))
       (remove-duplicates result :test #'equal)))))
 (defun %run-watch-files
    (operands output error-output grants why no-cache check options)
  (unless operands (error "--watch requires a source file"))
  (let* ((session (%make-command-session
                   grants :why why :no-cache no-cache :source-roots operands
                   :check check :error-output error-output))
         (policy (%command-runtime-policy (getf options :policy)))
         (once (or (getf options :once) (not (getf options :watch))))
         (stabilize (getf options :stabilize))
         (force-rerun nil)
         (pass
           (lambda (&optional (pass-output output)
                             (pass-error-output error-output))
             (if (getf options :supervise)
                 (progn
                   (unless (= (length operands) 1)
                     (error "--supervise requires exactly one source file"))
                   (let* ((source (first operands))
                          (forms
                            (%read-language-forms
                             (%read-source-file source)
                             source
                             (%source-surface source)))
                          (value
                            (%run-language-forms
                             forms source pass-output
                             :print-values nil :return-value t
                             :session session :grant-specs grants :why why
                             :no-cache (or no-cache force-rerun) :check check
                             :retain-thunks stabilize
                             :error-output pass-error-output)))
                    (%command-install-process-services session)
                    (let* ((desired (runtime-evaluator-force-deep
                                     (runtime-session-evaluator session) value))
                           (target (if (getf options :member-name)
                                       (%command-member-domain-desired
                                        desired (getf options :member-name) "proc")
                                       desired))
                           (domains (pp.kernel:make-vmap
                                     (list (cons (pp.kernel:make-vstring "proc")
                                                 target)))))
                      (let ((*error-output* pass-error-output))
                        (runtime-lifecycle-reconcile
                         session nil domains :fenced t))
                      desired))
                )
                 (%run-language-files operands pass-output :session session
                                      :grant-specs grants :why why
                                      :no-cache no-cache
                                      :member-name (getf options :member-name)
                                      :check check
                                      :retain-thunks stabilize
                                      :error-output pass-error-output)))))
    (when (getf options :pin-file)
      (%command-load-pin-file session (getf options :pin-file)))
    (when (getf options :policy-explicit)
      (runtime-session-register-service
       session :schedule-override (lambda () t)))
    (%command-schedule-node-force
     session policy :override (getf options :policy-explicit))
    (when (or (getf options :supervise)
              (getf options :member-name))
      (%command-install-process-services session))
    (if once
        (progn
          (funcall pass)
          (when (getf options :dump-pins)
            (%command-dump-pins session (getf options :dump-pins)
                                error-output))
          0)
        (let ((pass-output (make-string-output-stream))
              (pass-error-output (make-string-output-stream)))
          (let ((*command-effect-output* pass-error-output))
            (funcall pass pass-output pass-error-output))
          (when (getf options :dump-pins)
            (%command-dump-pins session (getf options :dump-pins)
                                error-output))
          (let ((snapshot (%command-watch-trace-snapshot session operands)))
            (write-string (get-output-stream-string pass-output) output)
            (write-string (get-output-stream-string pass-error-output)
                          error-output)
            (loop
              (runtime-watch-call-sleep (getf options :interval))
              (let* ((current (%command-watch-trace-snapshot session operands))
                     (changed (mapcar #'car
                                      (set-difference current snapshot
                                                      :test #'equal))))
                (when changed
                  (format error-output "[watch] ~D cell(s) changed~%"
                          (length changed))
                  (runtime-session-reset-pass-state session)
                  (let ((pass-output (make-string-output-stream))
                        (pass-error-output (make-string-output-stream)))
                    (let ((*command-effect-output* pass-error-output))
                      (when stabilize
                        (runtime-watch-stabilize session changed))
                      (unless stabilize
                        (setf force-rerun t))
                      (%command-schedule-node-force
                       session policy :override (getf options :policy-explicit))
                      (unless stabilize
                        (runtime-session-begin-watch session))
                      (funcall pass pass-output pass-error-output))
                    (setf force-rerun nil
                          snapshot
                          (%command-watch-trace-snapshot session operands))
                    (write-string (get-output-stream-string pass-output)
                                  output)
                    (write-string (get-output-stream-string pass-error-output)
                                  error-output))))))))
))

 (defun %command-pin-data-value (expression)
  (let ((expression (%language-form-inner expression)))
    (typecase expression
      (pp.kernel:expr-literal
       (pp.kernel:expr-literal-value expression))
      (pp.kernel:expr-symbol
       (pp.kernel:make-vsymbol (pp.kernel:expr-symbol-name expression)))
      (pp.kernel:expr-apply
       (let* ((function (pp.kernel:expr-apply-function expression))
              (name (and (typep function 'pp.kernel:expr-symbol)
                         (pp.kernel:expr-symbol-name function)))
              (arguments (pp.kernel:expr-apply-arguments expression)))
         (cond
           ((and name (string= name "hash-map"))
            (unless (evenp (length arguments))
              (error "pin-probe hash-map has odd arity"))
            (pp.kernel:make-vmap
             (loop for (key value) on arguments by #'cddr
                   collect (cons (%command-pin-data-value key)
                                 (%command-pin-data-value value)))))
           ((and name (string= name "vector"))
            (pp.kernel:make-vvector-from-list
             (mapcar #'%command-pin-data-value arguments)))
           ((and name (string= name "hash-set"))
            (pp.kernel:make-vset
             (mapcar #'%command-pin-data-value arguments)))
           (t (pp.runtime:runtime-quote-to-value expression)))))
      (t (pp.runtime:runtime-quote-to-value expression)))))

 (defun %command-pin-form (form path)
  (let* ((inner (%language-form-inner form))
         (function (and (typep inner 'pp.kernel:expr-apply)
                        (pp.kernel:expr-apply-function inner)))
         (name (and (typep function 'pp.kernel:expr-symbol)
                    (pp.kernel:expr-symbol-name function)))
         (arguments (and (typep inner 'pp.kernel:expr-apply)
                         (pp.kernel:expr-apply-arguments inner))))
    (unless (and name arguments)
      (error "pin file ~A contains a malformed line" path))
    (cond
      ((string= name "pin")
       (unless (= (length arguments) 2)
         (error "pin expects cell and hash"))
       (let* ((cell (%command-value-text
                     (%command-pin-data-value (first arguments))
                     "pin cell"))
              (hash (%command-value-text
                     (%command-pin-data-value (second arguments))
                     "pin hash"))
              (parsed (pp.kernel:cell-parse cell)))
         (unless (pp.runtime:store-digest-p hash)
           (error "pin hash is not canonical: ~A" hash))
         (list :pin parsed cell hash)))
      ((string= name "pin-probe")
       (unless (= (length arguments) 2)
         (error "pin-probe expects name and value"))
       (let ((probe (%command-value-text
                     (%command-pin-data-value (first arguments))
                     "pin-probe name"))
             (value (%command-pin-data-value (second arguments))))
         (unless (pp.runtime:runtime-executor-request-data-p value)
           (error "pin-probe value is not canonical data"))
         (list :pin-probe probe value)))
      (t (error "pin file ~A has unknown form: ~A" path name)))))

 (defun %command-load-pin-file (session path)
  (unless (and path (probe-file path))
    (error "pin file is not readable: ~A" path))
  (with-open-file (stream path :direction :input)
    (loop for line = (cl:read-line stream nil nil)
          while line
          for text = (string-trim '(#\Space #\Tab #\Return #\Newline) line)
          unless (or (string= text "")
                     (char= (char text 0) #\;))
            do (dolist (form (%read-language-forms text path :sexpr))
                 (destructuring-bind (kind a &optional b c) (%command-pin-form form path)
                   (ecase kind
                     (:pin
                      (pp.runtime:runtime-session-preseed-run-pin session a c)
                      (pp.runtime:runtime-session-preseed-run-pin session b c))
                     (:pin-probe
                      (pp.runtime:runtime-session-preseed-probe session a b)))))))
  session)

 (defun %command-pin-render (name arguments)
  (let ((form (pp.kernel:make-eapply
               (pp.kernel:make-esymbol name)
               (mapcar #'pp.runtime:runtime-value-to-expr arguments))))
    (string-trim '(#\Return #\Newline)
                 (pp.frontend:print-source (list form) :surface :sexpr))))

 (defun %command-dump-pins (session path error-output)
  (let ((lines (make-hash-table :test #'equal)))
    (dolist (observation (pp.runtime:runtime-session-observations session))
      (let* ((cell (car observation))
             (hash (pp.runtime:store-identity-string (cdr observation)))
             (text (pp.kernel:cell-serialize
                    (if (typep cell 'pp.kernel:cell)
                        cell
                        (pp.kernel:cell-parse
                         (pp.runtime:store-identity-string cell))))))
        (setf (gethash (format nil "pin:~A" text) lines)
              (%command-pin-render "pin"
                                   (list (pp.kernel:make-vstring text)
                                         (pp.kernel:make-vstring hash))))))
    (pp.runtime:runtime-session-iter-probes
     session
     (lambda (name value)
       (when (and value (pp.runtime:runtime-executor-request-data-p value))
         (setf (gethash (format nil "pin-probe:~A" name) lines)
               (%command-pin-render "pin-probe"
                                    (list (pp.kernel:make-vstring name)
                                          value))))
       (when (and value
                  (not (pp.runtime:runtime-executor-request-data-p value)))
         (format error-output "[pins] skipping non-data probe ~A~%" name))))
    (with-open-file (stream path :direction :output
                            :if-exists :supersede :if-does-not-exist :create)
      (let ((ordered nil))
        (maphash (lambda (ignored line)
                   (declare (ignore ignored))
                   (push line ordered))
                 lines)
        (dolist (line (sort ordered #'string<))
          (format stream "~A~%" line))))
    path))

 (defun %command-publish-copy-blobs (value source destination)
  (labels ((walk (item)
             (cond
               ((typep item 'pp.kernel:value-map)
                (handler-case
                    (dolist (entry (pp.runtime:runtime-artifact-tree-from-value item))
                      (let* ((hash (pp.runtime:runtime-artifact-entry-blob entry))
                             (bytes (and hash
                                         (pp.runtime:blob-repository-get source hash))))
                        (when bytes
                          (pp.runtime:blob-repository-put destination bytes))))
                  (error () nil))
                (dolist (entry (pp.kernel:value-map-entries item))
                  (walk (cdr entry))))
               ((typep item 'pp.kernel:value-vector)
                (map nil #'walk (pp.kernel:value-vector-values item)))
               ((typep item 'pp.kernel:value-pair)
                (walk (pp.kernel:value-pair-car item))
                (walk (pp.kernel:value-pair-cdr item))))))
    (walk value)))

 (defun %command-publish-value (session value shared-root output)
  (let* ((layout (pp.runtime:make-store-layout shared-root))
         (source (funcall (pp.runtime:runtime-session-find-service
                           session :store-blobs)))
         (objects nil)
         (blobs nil))
    (pp.runtime:store-layout-init layout)
    (setf objects (pp.runtime:make-object-repository layout)
          blobs (pp.runtime:make-blob-repository layout))
    (%command-publish-copy-blobs value source blobs)
    (let ((hash (pp.kernel:hash-value value)))
      (pp.runtime:object-repository-put objects :key hash :value value)
      (format output "~A~%" hash)
      (finish-output output)
      hash)))

 (defun %run-expression-command (arguments output error-output)
  (multiple-value-bind (operands options) (%command-runtime-options arguments)
    (multiple-value-bind (operands grants why no-cache check ignored-keep ignored-grace)
        (%parse-command-options operands)
      (declare (ignore ignored-keep ignored-grace))
      (let ((expression (remove "-e" operands :test #'string= :count 1)))
        (unless (= (length expression) 1)
          (error "-e requires exactly one expression"))
        (let ((session (%make-command-session
                        grants :why why :no-cache no-cache
                        :check check :error-output error-output)))
          (when (getf options :pin-file)
            (%command-load-pin-file session (getf options :pin-file)))
          (%command-schedule-node-force
           session (%command-runtime-policy (getf options :policy))
           :override (getf options :policy-explicit))
          (let ((status
                  (%run-language-text
                   (first expression) "<?>"
                   :brace output :all-values t :session session
                   :grant-specs grants :why why :no-cache no-cache :check check
                   :error-output error-output)))
            (when (getf options :dump-pins)
              (%command-dump-pins session (getf options :dump-pins)
                                   error-output))
            status))))))

(defun %run-runtime-command (arguments output error-output)
  (multiple-value-bind (operands options) (%command-runtime-options arguments)
    (multiple-value-bind (files grants why no-cache check ignored-keep ignored-grace)
        (%parse-command-options
         (remove "run" operands :test #'string= :count 1))
      (declare (ignore ignored-keep ignored-grace))
      (let ((policy (%command-runtime-policy (getf options :policy))))
        (when (getf options :watch)
          (return-from %run-runtime-command
            (%run-watch-files files output error-output grants why no-cache check
                              (list* :policy policy options))))
        (let ((session (%make-command-session
                        grants :why why :no-cache no-cache :source-roots files
                        :check check :error-output error-output)))
          (when (getf options :pin-file)
            (%command-load-pin-file session (getf options :pin-file)))
          (when (getf options :policy-explicit)
            (runtime-session-register-service
             session :schedule-override (lambda () t)))
          (%command-schedule-node-force
           session policy :override (getf options :policy-explicit))
          (when (getf options :publish-root)
            (unless (= (length files) 1)
              (error "--publish-object requires exactly one source file"))
            (let ((value
                    (%run-language-forms
                     (%read-language-forms (%read-source-file (first files))
                                           (first files)
                                           (%source-surface (first files)))
                     (first files) output :print-values nil :return-value t
                     :session session :grant-specs grants :why why
                     :no-cache no-cache :check check :error-output error-output)))
              (%command-publish-value
               session
               (runtime-evaluator-force-deep
                (runtime-session-evaluator session) value)
               (getf options :publish-root)
               output)
              (when (getf options :dump-pins)
                (%command-dump-pins session (getf options :dump-pins)
                                    error-output))
              (return-from %run-runtime-command 0)))
          (when (getf options :supervise)
            (%command-install-process-services session))
          (when (getf options :supervise)
            (unless (= (length files) 1)
              (error "--supervise requires exactly one source file"))
            (let ((value (%run-language-forms
                          (%read-language-forms (%read-source-file (first files))
                                                (first files)
                                                (%source-surface (first files)))
                          (first files) output :print-values nil :return-value t
                          :session session :grant-specs grants :why why
                          :no-cache no-cache :check check :error-output error-output)))
              (%command-install-process-services session)
              (let* ((desired (runtime-evaluator-force-deep
                               (runtime-session-evaluator session) value))
                     (domains (pp.kernel:make-vmap
                               (list (cons (pp.kernel:make-vstring "proc")
                                           desired)))))
                (let ((*error-output* error-output))
                  (runtime-lifecycle-reconcile
                  session nil domains :fenced t)))
              (%command-report-runtime-events session output)
              (return-from %run-runtime-command 0)))
          (let ((status
                  (%run-language-files files output :session session
                                       :grant-specs grants :why why
                                       :no-cache no-cache
                                       :member-name (getf options :member-name)
                                       :check check
                                       :error-output error-output)))
            (when (getf options :dump-pins)
              (%command-dump-pins session (getf options :dump-pins)
                                   error-output))
            status))))))

(defun %command-load-path-absolute-p (path)
  (and (plusp (length path))
       (char= (char path 0) #\/)))

(defun %command-path-directory (path)
  (namestring
   (make-pathname :name nil :type nil :defaults (pathname path))))

(defun %command-source-root (path)
  (pp.runtime:store-canonical-path (%command-path-directory path)))

(defun %command-loader-roots ()
  (let* ((session (ignore-errors (runtime-dynamic-session nil)))
         (service (and session
                       (runtime-session-find-service session :load-roots))))
    (or (and service (funcall service))
        (list (pp.runtime:store-canonical-path (truename "."))))))

(defun %command-loader-path-authorized-p (path)
  (let* ((canonical (pp.runtime:store-canonical-path path))
         (target (pp.kernel:canonicalize-path
                  canonical :realpath #'pp.runtime:store-canonical-path)))
    (some (lambda (root)
            (pp.kernel:path-under-p
             (pp.kernel:canonicalize-path
              root :realpath #'pp.runtime:store-canonical-path)
             target))
          (%command-loader-roots))))

(defun %command-load-path (state path)
  (unless (and (stringp path) (plusp (length path)))
    (language-fail "load path must be a non-empty string" "evaluator.load"))
  (if (%command-load-path-absolute-p path)
      path
      (let* ((range (and state
                         (pp.runtime::runtime-evaluator-state-current-location
                          state)))
             (source (and range (source-range-source range)))
             (source-directory
               (and source
                    (plusp (length source))
                    (char/= (char source 0) #\<)
                    (%command-path-directory source)))
             (directories
               (remove-duplicates
                (append (and source-directory (list source-directory))
                        (list (namestring (truename ".")))
                        (%command-loader-roots))
                :test #'equal))
             (candidates (mapcar (lambda (directory)
                                   (namestring
                                    (merge-pathnames path
                                                     (pathname directory))))
                                 directories)))
        (or (find-if #'probe-file candidates)
            (first candidates)
            path))))

(defun %command-load-forms (state path environment modulep)
  (let* ((resolved (%command-load-path state path))
         (canonical (pp.runtime:store-canonical-path resolved)))
    (unless (%command-loader-path-authorized-p canonical)
      (language-fail
       (format nil "load path is outside the permitted source roots: ~A"
               canonical)
       "evaluator.load"))
    (handler-case
        (let* ((text (%read-source-file canonical))
               ;; Source files use the brace reader by default, while an
               ;; explicitly sexpr-suffixed file keeps its own surface.
               (surface (if (%suffix-p (string-downcase canonical) ".ppl")
                            :sexpr
                            :brace))
               (forms (%read-language-forms text canonical surface))
               (expanded (runtime-evaluator-expand-toplevel state forms))
               (old-environment
                 (runtime-evaluator-state-initial-env state))
               (base-environment (if modulep old-environment environment)))
          (pp.runtime:runtime-observation-record
           (pp.kernel:make-cell-runtime-file canonical)
           (pp.runtime:store-hash-content text))
          ;; MODULE evaluation exports only definitions introduced by the
          ;; loaded forms.  LOAD uses the caller's scope as its base.
          (unwind-protect
               (progn
                 (setf (runtime-evaluator-state-initial-env state)
                       base-environment)
                 (runtime-evaluator-eval
                  state (make-emodule expanded) :expand nil))
            (setf (runtime-evaluator-state-initial-env state)
                  old-environment)))
      (frontend-error (condition)
        (language-fail (%frontend-error-message condition)
                       (frontend-error-code condition)
                       (frontend-error-range condition)))
      (language-error (condition)
        (error condition))
      (error (condition)
        (language-fail (format nil "load ~A: ~A" canonical condition)
                       "evaluator.load")))))


(defun %command-install-loaders (session)
  (runtime-session-register-callback
   session :load
   (lambda (state path environment)
     (%command-load-forms state path environment nil)))
  (runtime-session-register-callback
   session :load-module
   (lambda (state path)
     (%command-load-forms state path nil t)))
  (runtime-session-register-callback
   session :island
   (lambda (state uri pin)
     ;; Resolution never touches the network and verifies the pin on every
     ;; resolve; the module root loads as a module (exports only).
     (let ((dir (pp.runtime:island-resolve uri pin)))
       (%command-load-forms state (pp.runtime:island-entry-file dir) nil t))))
  session)

(defun %make-command-session
    (grant-specs &key (why nil) (no-cache nil) (check nil) error-output
                         source-roots)
  "Create a normal command session with an explicit HOME-derived store."
  (let* ((capabilities (%command-capabilities grant-specs))
         (program-arguments (copy-list *command-program-arguments*))
         (invocation (list :argv program-arguments))
         (exit-status nil)
         (roots
           (remove-duplicates
            (append
             (remove nil
                     (mapcar (lambda (path)
                               (ignore-errors (%command-source-root path)))
                             source-roots))
             (list (pp.runtime:store-canonical-path (truename "."))
                   (pp.runtime:store-canonical-path
                    (merge-pathnames
                     (pathname ".pp/")
                     (pathname (%command-home))))))
            :test #'equal))
         (evaluator-state (runtime-evaluator-default-state))
         (session
           (make-runtime-session
            :evaluator-state evaluator-state
            :store-root (%command-store-root)
            :capabilities capabilities)))
    (pp.runtime:runtime-lifecycle-install-executor
     session (%command-closed-executor))
    (runtime-session-register-service
     session :record-read
     (lambda (ignored-session cell-id hash)
       (declare (ignore ignored-session))
       (let ((cell (pp.kernel:cell-parse
                    (pp.runtime:store-identity-string cell-id))))
         (when (typep cell 'pp.kernel:cell-runtime-file)
           (let ((serialized (pp.kernel:cell-serialize cell)))
             (pp.runtime:runtime-session-set-run-pin
              session cell-id hash)
             (pp.runtime:runtime-session-set-run-pin
              session serialized hash))))
       (pp.runtime:runtime-session-add-observation session
                                                   (cons cell-id hash))))
    (runtime-session-register-service
     session :invocation (lambda () invocation))
    (runtime-session-register-service
     session :invocation-argv
     (lambda (&optional ignored)
       (declare (ignore ignored))
       (copy-list program-arguments)))
    (runtime-session-register-service
     session :observe-argv
     (lambda () (copy-list program-arguments)))
    (runtime-session-register-service
     session :exit
     (lambda (status)
       (setf exit-status status)
       (throw 'pp-command-exit status)))
    (runtime-session-register-service
     session :exit-status (lambda () exit-status))
    (runtime-session-register-service
     session :load-roots (lambda () roots))
    (%command-install-loaders session)
    (runtime-session-register-service
     session :observe-file
     (lambda (path) (%command-observe-file path nil)))
    (runtime-session-register-service
     session :observe-stat
     (lambda (path) (%command-observe-stat path)))
    (runtime-session-register-service
     session :observe-sealed
     (lambda (path) (%command-observe-file path t)))
    (runtime-session-register-service
     session :observe-env
     (lambda (name)
       (and (fboundp 'sb-ext:posix-getenv)
            (sb-ext:posix-getenv name))))
    (runtime-session-register-service
     session :observe-tool
     (lambda (path) (%command-tool-observed-hash path)))
    (runtime-session-register-service
     session :diagnose
     (lambda (text)
       (let ((policy-service (runtime-session-find-service session :cache-policy)))
         (when (and error-output
                    (or why
                        (and policy-service
                             (runtime-cache-why-enabled-p
                              (funcall policy-service)))))
           (format error-output "[why] ~A~%" text)
           (finish-output error-output)))))
    (%command-install-observation-primitives session error-output)
    (let ((policy-service (runtime-session-find-service session :cache-policy)))
      (when policy-service
        (runtime-cache-configure
         (funcall policy-service)
         :no-cache no-cache :why why :check check)))
    session))
(defun %command-session-invocation (session)
  (let ((service (runtime-session-find-service session :invocation)))
    (and service (funcall service))))
(defun %command-dynamic-top-level (session thunk)
  (runtime-dynamic-with-top-level
   session thunk :invocation (%command-session-invocation session)))


(defun %parse-decimal (text)
  (let* ((length (length text))
         (sign (if (and (> length 0)
                        (member (char text 0) '(#\+ #\-)))
                   (if (char= (char text 0) #\-) -1 1)
                   1))
         (start (if (and (> length 0)
                         (member (char text 0) '(#\+ #\-)))
                    1 0))
         (dot (cl:position #\. text :start start))
         (whole-end (or dot length))
         (fraction-start (and dot (1+ dot)))
         (whole (and (> whole-end start)
                     (parse-integer text :start start :end whole-end
                                    :junk-allowed nil)))
         (fraction (and dot (< fraction-start length)
                        (parse-integer text :start fraction-start
                                       :junk-allowed nil)))
         (fraction-length (and dot (- length fraction-start))))
    (unless (and whole
                 (or (null dot)
                     (and fraction fraction-length (plusp fraction-length))))
      (error "invalid decimal number: ~A" text))
    (* sign (+ whole
               (if dot
                   (/ fraction (expt 10 fraction-length))
                   0)))))

(defun %parse-command-options (arguments)
  "Remove command-owned grants and cache flags, retaining source operands."
  (%reject-runtime-flags arguments)
  (let ((rest nil) (grants nil) (why nil) (no-cache nil) (check nil)
        (keep-epochs 5) (grace-seconds 2.0))
    (loop while arguments do
      (let ((argument (pop arguments)))
        (cond
          ((string= argument "--grant")
           (unless arguments (error "--grant requires a capability specification"))
           (push (pop arguments) grants))
          ((or (string= argument "why") (string= argument "--why"))
           (setf why t))
          ((string= argument "--no-cache") (setf no-cache t))
          ((string= argument "--check") (setf check t))
          ((string= argument "--gc-keep-epochs")
           (unless arguments (error "--gc-keep-epochs requires an integer"))
           (setf keep-epochs
                 (or (ignore-errors (parse-integer (pop arguments)))
                     (error "--gc-keep-epochs requires an integer"))))
          ((string= argument "--gc-grace-seconds")
           (unless arguments (error "--gc-grace-seconds requires a number"))
           (setf grace-seconds (%parse-decimal (pop arguments))))
          (t (push argument rest)))))
    (values (nreverse rest) (nreverse grants) why no-cache check
            keep-epochs grace-seconds)))

(defun %language-leading-load-info (form)
  (let ((inner (%language-form-inner form)))
    (cond
      ((typep inner 'expr-load)
       (values (expr-load-path inner) nil t))
      ((typep inner 'expr-loadmodule)
       (values (expr-loadmodule-path inner) t t))
      (t (values nil nil nil)))))

(defun %language-preload-leading-loads (state forms)
  "Load leading source imports before prebinding the remaining block.

The evaluator prebinds every definition in one block.  A load merged into
that block afterward cannot reach closures already capturing the prebound
environment, so leading loads must establish the initial environment first."
  (let ((remaining forms)
        (environment (runtime-evaluator-state-initial-env state))
        (loaded-values nil))
    (loop
      (multiple-value-bind (path modulep foundp)
          (and remaining (%language-leading-load-info (first remaining)))
        (unless foundp (return))
        (let ((saved-location
                (pp.runtime::runtime-evaluator-state-current-location state)))
          (unwind-protect
               (progn
                 (setf (pp.runtime::runtime-evaluator-state-current-location state)
                       (and (typep (first remaining) 'expr-located)
                            (expr-located-range (first remaining))))
                 (let ((loaded
                         (%command-load-forms state path environment modulep)))
                   (push loaded loaded-values)
                   (setf environment
                         (%language-merge-module-value environment loaded)))
                 (setf (runtime-evaluator-state-initial-env state)
                       environment))
            (setf (pp.runtime::runtime-evaluator-state-current-location state)
                  saved-location)))
        (pop remaining)))
    (values remaining environment (nreverse loaded-values))))

(defun %run-language-forms (forms source output
                            &key (all-values nil)
                                 (print-values t)
                                 (continue-errors nil)
                                 (return-value nil)
                                 session grant-specs (why nil)
                                 (no-cache nil) (check nil) (retain-thunks nil)
                                 error-output)
  "Evaluate FORMS through one explicit command session."
  (if (null forms)
      (if return-value nil 0)
      (handler-case
          (let ((session (or session
                             (%make-command-session
                              grant-specs :why why :no-cache no-cache
                              :check check :error-output error-output))))
            (let ((policy-service
                    (runtime-session-find-service session :cache-policy)))
              (when policy-service
                (runtime-cache-configure
                 (funcall policy-service)
                 :no-cache no-cache :why why :check check)))
            (unless (runtime-session-find-service session :scheduler)
              (%command-schedule-node-force
               session (%command-runtime-policy "serial")))
            (runtime-session-begin-evaluation
             session :retain-thunks retain-thunks)
            (let ((*standard-output* output))
              (%command-dynamic-top-level
               session
               (lambda ()
                 (let ((state (runtime-session-evaluator session)))
                   (multiple-value-bind (forms environment loaded-values)
                       (%language-preload-leading-loads state forms)
                     (let* ((binding-p (some #'%language-binding-form-p forms))
                            (last-value (car (last loaded-values))))
                       (when (and all-values (not binding-p) print-values)
                         (dolist (value loaded-values)
                           (%language-print-value state value output)))
                       (if (and all-values (not binding-p))
                           (dolist (form forms)
                             (handler-case
                                 (progn
                                   (setf last-value
                                         (runtime-evaluator-eval
                                          state form :environment environment))
                                   (when print-values
                                     (%language-print-value
                                      state last-value output)))
                               (error (condition)
                                 (if continue-errors
                                     (progn
                                       (format output "Error: ~A~%"
                                               (%language-error-text condition))
                                       (finish-output output))
                                     (error condition)))))
                           (setf last-value
                                 (runtime-evaluator-eval-expressions
                                  state forms :environment environment)))
                       (unless (and all-values (not binding-p))
                         (when print-values
                           (%language-print-value state last-value output)))
                       (if return-value last-value 0))))))))
        (language-error (condition)
          (%language-reraise-with-source condition forms source)))))

(defun %read-language-forms (text source surface)
  (read-source text :source source :surface surface))


(defun %run-language-stdin
    (input output &key grant-specs (why nil) (no-cache nil) (check nil)
                 error-output session)
  "Run piped REPL input as independent forms in one explicit session."
  (let ((session (or session
                     (%make-command-session
                      grant-specs :why why :no-cache no-cache :check check
                      :error-output error-output)))
        (pending ""))
    (unless (runtime-session-find-service session :scheduler)
      (%command-schedule-node-force
       session (%command-runtime-policy "serial")))
    (let ((*standard-output* output))
      (%command-dynamic-top-level
       session
       (lambda ()
       (let ((state (runtime-session-evaluator session))
             (environment nil))
         (setf environment (runtime-evaluator-state-initial-env state))
         (labels
             ((report (condition &optional input)
                (let ((message (%language-error-text condition)))
                  (when (and input
                             (search "expected parameter list" message
                                     :test #'char-equal)
                             (search "def" input :test #'char-equal))
                    (let ((marker "expected parameter list"))
                      (setf message
                            (concatenate 'string
                                         "def requires a parameter list"
                                         (subseq message (length marker))))))
                  (when (and input
                             (typep condition 'frontend-error)
                             (null (frontend-error-range condition))
                             (search "expected newline" message
                                     :test #'char-equal))
                    (let* ((trimmed
                             (string-right-trim
                              '(#\Space #\Tab #\Return #\Newline) input))
                           (separator
                             (position-if
                              (lambda (character)
                                (member character
                                        '(#\Space #\Tab #\Return #\Newline)
                                        :test #'char=))
                              trimmed :from-end t))
                           (token (subseq trimmed (if separator
                                                     (1+ separator)
                                                     0))))
                      (setf message (format nil "~A, got ~A" message token))))
                  (format output "Error: ~A~%" message)
                  (finish-output output)))
              (evaluate (forms)
                (dolist (form forms)
                  ;; Each submitted form gets a fresh dynamic extent.  The
                  ;; evaluator state and lexical environment persist, while
                  ;; config and effect handlers cannot leak to the next form.
                  (%command-dynamic-top-level
                   session
                   (lambda ()
                  (handler-case
                      (let* ((binding-p (%language-persistent-form-p form))
                             (binding-name (%language-binding-name form))
                             (direct-p (%language-direct-binding-p form))
                             (value
                               (cond
                                 ;; DEFMACRO is a top-level expansion form:
                                 ;; eval-expressions records it in the session's
                                 ;; macro state without requiring an evaluator
                                 ;; value to be installed in the environment.
                                 ((%language-defmacro-form-p form)
                                  (runtime-evaluator-eval-expressions
                                   state (list form) :environment environment))
                                 ;; Evaluate ordinary definitions directly:
                                 ;; their value is the binding, and extending
                                 ;; the immutable environment here avoids
                                 ;; depending on a terminal module result.
                                 ((and binding-p direct-p)
                                  (runtime-evaluator-eval
                                   state (%language-persistent-module form)
                                   :environment environment))
                                 ;; Other assignment-like/module forms use the
                                 ;; evaluator's exported environment map.
                                 (binding-p
                                  (runtime-evaluator-eval
                                   state (%language-persistent-module form)
                                   :environment environment))
                                 (t
                                  (runtime-evaluator-eval
                                   state form :environment environment))))
                             ;; A direct definition is evaluated through a
                             ;; one-export module, so retain that exported
                             ;; value rather than installing the whole map.
                             (binding-value
                               (if (and direct-p
                                        (typep value 'value-env-map))
                                   (let ((entry (and binding-name
                                                     (assoc
                                                      binding-name
                                                      (value-env-map-bindings

                                                       value)
                                                      :test #'string=))))
                                     (or (and entry (cdr entry))
                                         (error
                                          "definition did not export ~A"
                                          binding-name)))
                                   value))
                             (display-value
                               (if (and binding-p binding-name)
                                   (if direct-p
                                       (cons binding-name binding-value)
                                       (if (typep value 'value-env-map)
                                           (or (assoc binding-name
                                                      (value-env-map-bindings
                                                       value)
                                                      :test #'string=)
                                               (cons binding-name value))
                                           (cons binding-name value)))
                                   (cons nil value))))
                        ;; Do not publish a binding until its display value has
                        ;; been forced successfully.  A typed RHS is lazy, so
                        ;; printing is part of the submission's commit point:
                        ;; if forcing reports an error, the failed form must
                        ;; not leave a binding in the next REPL environment.
                        (%language-print-value state (cdr display-value) output)
                        (when binding-p
                          (setf environment
                                (if (and binding-name direct-p)
                                    (%language-extend-environment
                                     environment
                                     (list (cons binding-name binding-value)))
                                    (%language-merge-module-value
                                     environment value)))
                          ;; Macro expansion evaluates against this callback's
                          ;; initial environment, so keep it aligned with the
                          ;; persistent REPL environment as definitions arrive.
                          (setf (runtime-evaluator-state-initial-env state)
                                environment)))
                    (error (condition) (report condition)))))))
              (try-pending ()
                (handler-case
                    (let ((parsed (%read-language-forms
                                   pending "<stdin>" :brace)))
                      (setf pending "")
                      (evaluate parsed))
                  (frontend-error (condition)
                    (if (frontend-error-incomplete-p condition)
                        nil
                        (let ((input pending))
                          (setf pending "")
                          (report condition input))))
                  (error (condition)
                    (setf pending "")
                    (report condition))))
           )
           (loop for line = (cl:read-line input nil nil)
                 while line
                 do (let ((trimmed
                            (string-trim
                             '(#\Space #\Tab #\Return #\Newline) line)))
                      (if (and (string= pending "")
                               (or (string= trimmed ":why on")
                                   (string= trimmed ":why off")))
                          (let ((policy-service
                                  (runtime-session-find-service
                                   session :cache-policy)))
                            (when policy-service
                              (runtime-cache-set-why
                               (funcall policy-service)
                               (string= trimmed ":why on"))))
                          (progn
                            (setf pending
                                  (if (string= pending "")
                                      line
                                      (concatenate 'string pending
                                                   (string #\Newline) line)))
                            (try-pending)))))
           ;; EOF with an unterminated form is an ordinary REPL error, not a
           ;; command failure.  Preserve the frontend's structured message.
           (unless (string= (string-trim '(#\Space #\Tab #\Return #\Newline)
                                         pending)
                            "")
             (handler-case
                 (let ((parsed (%read-language-forms
                                pending "<stdin>" :brace)))
                   (setf pending "")
                   (evaluate parsed))
              (frontend-error (condition)
                (let ((input pending))
                  (setf pending "")
                  (report condition input)))
               (error (condition)
                 (setf pending "")
                 (report condition))))
           (%command-report-runtime-events session output)
           0)))))))
(defun %run-language-text
    (text source surface output &key (all-values nil) session grant-specs
                                  (why nil) (no-cache nil) (check nil)
                                  error-output)
  (let ((*language-source-context* source)
        (session (or session
                     (%make-command-session
                      grant-specs :why why :no-cache no-cache
                      :check check :error-output error-output))))
    (handler-case
        (let ((result
                (%run-language-forms
                 (%read-language-forms text source surface)
                 source output :all-values all-values :session session
                 :grant-specs grant-specs :why why :no-cache no-cache :check check
                 :error-output error-output)))
          (%command-report-runtime-events session output)
          result)
      (frontend-error (condition)
        ;; Normalize source-aware surface diagnostics while the source
        ;; context is still dynamically bound.
        (error 'frontend-error
               :code (frontend-error-code condition)
               :message (%frontend-error-message condition)
               :range (frontend-error-range condition)
               :incomplete-p (frontend-error-incomplete-p condition))))))

(defun %command-member-desired (value member-name)
  (unless (typep value 'pp.kernel:value-map)
    (error "--member-name requires a host-keyed desired map"))
  (let ((entry
          (find-if
           (lambda (item)
             (and (typep (car item) 'pp.kernel:value-string)
                  (string= (pp.kernel:value-string-value (car item))
                           member-name)))
           (pp.kernel:value-map-entries value))))
    (or (and entry (cdr entry))
        (error "no such host key: ~A" member-name))))

(defun %command-member-domain-desired (value member-name domain-name)
  (let* ((slice (%command-member-desired value member-name))
         (entry (and (typep slice 'pp.kernel:value-map)
                     (find-if
                      (lambda (item)
                        (and (typep (car item) 'pp.kernel:value-string)
                             (string= (pp.kernel:value-string-value
                                       (car item))
                                      domain-name)))
                      (pp.kernel:value-map-entries slice)))))
    (or (and entry (cdr entry))
        (error "no such domain key for host ~A: ~A"
               member-name domain-name))))

(defun %run-language-files
    (paths output &key session grant-specs (why nil) (no-cache nil)
                         (retain-thunks nil) (check nil) error-output member-name)
  (unless paths
    (error "expected at least one .pp or .ppl source file"))
  (let ((session
          (or session
              (%make-command-session
               grant-specs :why why :no-cache no-cache :source-roots paths
               :check check :error-output error-output)))
        (last-value nil))
    (dolist (path paths)
      (let ((*language-source-context* path))
        (handler-case
            (setf last-value
                  (%run-language-forms
                   (%read-language-forms
                    (%read-source-file path) path
                    (%source-surface path))
                   path output :print-values nil :session session
                   :return-value t
                   :grant-specs grant-specs :why why :no-cache no-cache :check check
                   :retain-thunks retain-thunks :error-output error-output))
          (frontend-error (condition)
            (error 'frontend-error
                   :code (frontend-error-code condition)
                   :message (%frontend-removed-surface-message
                             (frontend-error-message condition)
                             (handler-case
                                 (%read-source-file path)
                               (error () nil)))
                   :range (frontend-error-range condition)
                   :incomplete-p (frontend-error-incomplete-p condition)))))
      )
    ;; A program that registers write domains and returns a desired-state
    ;; map converges them after evaluation (no --reconcile flag needed).
    (let ((desired (and last-value
                        (if member-name
                            (%command-member-desired last-value member-name)
                            last-value))))
      (when (and desired
                 (pp.runtime:runtime-domain-any-write-domain-registered-p session))
        (pp.runtime:runtime-lifecycle-reconcile
         session nil desired :fenced t))
      (unless (and desired
                   (pp.runtime:runtime-domain-any-write-domain-registered-p session))
        (pp.runtime:runtime-fenced-drain session)))
    (%command-report-runtime-events session output)
    0))
;;; ---- Islands: `pp --update` and `pp island-pins` ----

(defun %island-token-char-p (char)
  (or (digit-char-p char) (alpha-char-p char)
      (member char '(#\- #\_ #\: #\. #\/ #\#))))

(defun %island-find-delimited (haystack needle)
  "Positions of NEEDLE in HAYSTACK not flanked by token characters."
  (loop with n = (length needle) and h = (length haystack)
        for i from 0 to (- h n)
        when (and (string= haystack needle :start1 i :end1 (+ i n))
                  (or (zerop i)
                      (not (%island-token-char-p (char haystack (1- i)))))
                  (or (= (+ i n) h)
                      (not (%island-token-char-p (char haystack (+ i n))))))
        collect i))

(defun %island-splice (text at length replacement)
  (concatenate 'string
               (subseq text 0 at) replacement
               (subseq text (+ at length))))

(defun %command-island-update-file (path output error-output)
  "Re-resolve every island form in PATH and rewrite its inline pin.
Conservative textual splice: any ambiguity prints the exact replacement and
changes nothing for that form — never a half-written file."
  (let* ((canonical (namestring path))
         (original (%read-source-file canonical))
         (surface (if (%suffix-p (string-downcase canonical) ".ppl")
                      :sexpr :brace))
         (forms (mapcan #'pp.runtime:island-forms-in
                        (%read-language-forms original canonical surface)))
         (text original)
         (updated 0) (skipped 0))
    (labels ((skip (uri message suggestion)
               (incf skipped)
               (format error-output "[update] ~A: ~A~%  apply by hand: ~A~%"
                       uri message suggestion))
             (replace-all (old fresh)
               (loop for hits = (%island-find-delimited text old)
                     while hits
                     do (setf text (%island-splice text (first hits)
                                                   (length old) fresh)))))
      (dolist (form forms)
        (let* ((uri (car form)) (old-pin (cdr form)))
          (multiple-value-bind (scheme locator ref-hint)
              (pp.runtime:island-parse-uri uri)
            (let ((fresh (pp.runtime:island-repin scheme locator uri ref-hint)))
              (cond
                ((and old-pin (string= old-pin fresh)))  ; already current
                ((and old-pin (pp.runtime:island-pin-p old-pin))
                 ;; Same pin = same content, so every delimited occurrence
                 ;; re-pins to the same fresh hash.
                 (if (%island-find-delimited text old-pin)
                     (progn (replace-all old-pin fresh) (incf updated))
                     (skip uri "old pin not found in file text"
                           (format nil "replace ~A... with ~A"
                                   (pp.runtime:island-short old-pin) fresh))))
                (old-pin
                 (skip uri
                       (format nil "existing pin argument is not a 64-hex ~
hash: ~A" old-pin)
                       (format nil "write island(~A, \"~A\")" uri fresh)))
                (t
                 ;; Insert after the URI as written.  Try the delimited
                 ;; forms first (<uri>, "uri") — a bare-URI search would
                 ;; also match INSIDE them — and use the first candidate
                 ;; with exactly one hit.
                 (let ((hit (loop for candidate in
                                     (list (format nil "<~A>" uri)
                                           (format nil "\"~A\"" uri)
                                           uri)
                                  for hits =
                                  (%island-find-delimited text candidate)
                                  when (= (length hits) 1)
                                    return (cons candidate (first hits)))))
                   (if hit
                       (let ((close (cl:position #\) text
                                              :start (+ (cdr hit)
                                                        (length (car hit))))))
                         (if close
                             ;; The separator is surface-specific: brace
                             ;; files take a comma, sexpr files whitespace.
                             (let ((sep (if (eq surface :sexpr) " " ", ")))
                               (setf text
                                     (%island-splice text close 0
                                                     (format nil "~A\"~A\""
                                                             sep fresh)))
                               (incf updated))
                             (skip uri "no closing paren found after URI"
                                   (format nil "add pin \"~A\" to the form"
                                           fresh))))
                       (skip uri "URI not found uniquely in file text"
                             (format nil "add pin \"~A\" to the form" fresh))))))))))
      (unless (string= text original)
        ;; Rewrite user source after staging the complete edit.
        (let ((tmp (format nil "~A.pp-update.~D" canonical (sb-posix:getpid))))
          (with-open-file (stream tmp :direction :output
                                       :if-exists :supersede)
            (write-string text stream))
          (rename-file tmp canonical)))
      (format output "~D pin(s) updated~@[, ~D skipped~]~%"
              updated (and (plusp skipped) skipped))
      0)))

(defun %run-island-update (paths output error-output)
  (unless paths
    (error "--update requires a source file"))
  (let ((status 0))
    (dolist (path paths status)
      (setf status (%command-island-update-file path output error-output)))))

(defun %run-island-pins (arguments output error-output)
  (let* ((paths (remove-if
                 (lambda (argument)
                   (char= (char argument 0) #\-))
                 arguments))
         (path (first paths)))
    (unless path
      (error "island-pins requires a source file"))
    (let* ((canonical (namestring path))
           (text (%read-source-file canonical))
           (surface (if (%suffix-p (string-downcase canonical) ".ppl")
                        :sexpr :brace))
           (forms (mapcan #'pp.runtime:island-forms-in
                          (%read-language-forms text canonical surface))))
      (if (null forms)
          (progn
            (format output "(no island forms in ~A)~%" path)
            0)
          (progn
            (dolist (form forms)
              (let* ((uri (car form)) (pin (cdr form)))
                (cond
                  ((null pin) (format output "~A~C(unpinned)~%" uri #\Tab))
                  ((not (pp.runtime:island-pin-p pin))
                   (format output "~A~C(invalid pin: ~A)~%" uri #\Tab pin))
                  (t
                   (let ((dir (pp.runtime:island-cached-tree pin)))
                     (format output "~A~C~A~C~A~%" uri #\Tab pin #\Tab
                             (cond ((not (probe-file dir)) "uncached")
                                   ((pp.runtime:island-verify dir pin) "TAMPERED")
                                   (t "cached"))))))))
            0)))))

(defun %gc-option-p (argument)
  (or (string= argument "--gc-keep-epochs")
      (string= argument "--gc-grace-seconds")))

(defun %runtime-flag-p (argument)
  (member argument
          '("--watch" "--watch-interval" "--stabilize" "--schedule"
            "--fenced-policy"
            "--desired-object" "--publish-object" "--remote-node"
            "--pin-file" "--dump-pins" "cluster-init" "--mint-token"
            "--transport-push" "--transport-pull" "--serve-hit" "--recv-hit"
          )
          :test #'string=))


(defun %run-why-command (arguments output error-output)
  (multiple-value-bind (paths grants ignored no-cache check ignored-keep ignored-grace)
      (%parse-command-options arguments)
    (declare (ignore ignored ignored-keep ignored-grace))
    (unless paths
      (error "why requires a source file"))
    (%run-language-files
     paths output :grant-specs grants :why t :no-cache no-cache :check check
     :error-output error-output)))

(defun %run-gc-command (arguments output)
  (multiple-value-bind (operands grants ignored no-cache check keep grace)
      (%parse-command-options
       (remove "gc" arguments :test #'string=))
    (declare (ignore grants ignored no-cache check))
    (when operands
      (error "gc does not accept source files"))
    (when (<= keep 0)
      (error "invalid --gc-keep-epochs: must be positive"))
    (let ((layout (pp.runtime:make-store-layout (%command-store-root))))
      (pp.runtime:store-layout-init layout)
      (pp.runtime:runtime-store-with-repositories
       layout
       (lambda (layout objects blobs traces cells)
         (declare (ignore blobs cells))
         (let* ((roots (pp.runtime:gc-roots-read-all layout)))
           (if (null roots)
               (progn
                 (format output "pp gc: no wanted roots; nothing to do~%")

                 (finish-output output)
                 0)
               (let ((report (pp.runtime:store-gc-run
                              layout traces objects :grace-seconds grace
                              :roots roots)))
                 (format output
                         "pp gc: objects kept=~D deleted=~D, traces kept=~D deleted=~D, blobs kept=~D deleted=~D~%"
                         (car (getf report :objects))
                         (cdr (getf report :objects))
                         (car (getf report :traces))
                         (cdr (getf report :traces))
                         (car (getf report :blobs))
                         (cdr (getf report :blobs)))
                 (finish-output output)
                 0))))))))
(defun %reconcile-stratification-check (session root)
  (let ((prefix (format nil "~A/" (string-right-trim "/" (pp.runtime:store-canonical-path root)))))
    (dolist (observation (pp.runtime:runtime-session-observations session))
      (let* ((cell-id (pp.runtime:store-identity-string (car observation)))
             (cell (pp.kernel:cell-parse cell-id))
             (kind (pp.kernel:cell-kind cell))
             (data (pp.kernel:cell-data cell)))
        (when (and (member kind '(:file :tree :stat)) (stringp data)
                   (or (string= data (string-right-trim "/" prefix))
                       (and (>= (length data) (length prefix))
                            (string= prefix data :end2 (length prefix)))))
          (error "reconcile: stratification violation: desired state reads its own domain: ~A"
                 data))))))
(defun %reconcile-list (values)
  (reduce (lambda (tail value)
            (pp.kernel:make-vpair value tail))
          (reverse values)
          :initial-value (pp.kernel:make-vnil)))

(defun %reconcile-root-value (value)
  (pp.kernel:make-vmap
   (list (cons (pp.kernel:make-vstring "fs") value))))

(defun %reconcile-fs-diff-hash (root)
  (labels ((capture (name hash)
             (pp.kernel:hash-concat (list "capture" name hash)))
           (builtin (name)
             (capture name (pp.kernel:hash-concat (list "builtin" name))))
           (unbound (name)
             (pp.kernel:hash-concat (list "capture-unbound" name))))
    (let ((captures
            (list
             (builtin "=")
             (capture "append"
                      "f112b61cdb0aa045623bbd86a6c8f716315872268a7b0a15cb36d1382935b4a6")
             (unbound "desired")
             (capture "each"
                      "500eb8dcc240b8882cbddf4f21c8461aa5899dafcca50f207891254692cb49d0")
             (capture "filter"
                      "a059a1a8b351347bc5fedd96245a265cb669dcfb2bc8698c57f25b4f54b61843")
             (capture "fs-content-hash"
                      "b1af0df1fbe961f1398ad327aa338ee51167e7e34267e4e5f88943d1b8cdd5b6")
             (capture "fs-plan-item"
                      "f50ba798dcbfe1aabd906ff873ca11eb818df4265db9107841f7d27ff611d3e2")
             (capture "fs-validate-rel"
                      "636a6608b47d11f267b16cfadbf4dca8582d61c9d70ea796bca213ac2ef5d074")
             (capture "hash-map"
                      "3e51d1daafca4ea6026828de75fe70cb421f57ba98f5da6c92e4cf8209a034c9")
             (capture "hash-map-get"
                      "4f600ed90a5aad238a25d21dedc84cb635e02d8f33e8c256578981a4add87946")
             (capture "length"
                      "389d42959065b82ad6d8d511560213c15ff85b0c807d5eed14579a046d1b5ab5")
             (capture "map"
                      "3d1ad8c2eb15f599e9abd14ec1e5783ba66480caf3a6f4eb306517aa8d28eb31")
             (capture "map-keys"
                      "a00bb7852cc00726354acbda6753366f4fcfdd57d07b9b104b1df96ed62764dd")
             (builtin "nil?")
             (builtin "not")
             (capture "number->string"
                      "6aafd6e3fbf3d2307ccc2fd7c699bf28e51e875617d08a3f018450960e956bcb")
             (unbound "observed")
             (capture "root"
                      (pp.kernel:hash-concat (list "string" root)))
             (builtin "vector"))))
      (pp.kernel:hash-concat
       (list "closure" "anon"
             (pp.kernel:hash-concat (list "params" "observed" "desired"))
             "62f390d6e9604af0592fccb193dd98a8bc1a24b7b6b31dea451e207204884a21"
             (pp.kernel:hash-concat (cons "captures" captures)))))))
(defun %reconcile-entry-value (entry &optional (kind "create"))
  (pp.kernel:make-vmap
   (list (cons (pp.kernel:make-vkeyword "content")
               (pp.kernel:make-vmap
                (list (cons (pp.kernel:make-vkeyword "blob")
                            (pp.kernel:make-vstring
                             (pp.runtime::runtime-artifact-entry-blob entry)))
                      (cons (pp.kernel:make-vkeyword "kind")
                            (pp.kernel:make-vkeyword "file"))
                      (cons (pp.kernel:make-vkeyword "mode")
                            (pp.kernel:make-vint
                             (pp.runtime::runtime-artifact-entry-mode entry))))))
         (cons (pp.kernel:make-vkeyword "kind")
               (pp.kernel:make-vstring kind))
         (cons (pp.kernel:make-vkeyword "rel")
               (pp.kernel:make-vstring
                (pp.runtime::runtime-artifact-entry-path entry))))))

(defun %reconcile-plan (root entries observed)
  (let ((creates nil) (updates nil) (deletes nil)
        (desired (make-hash-table :test #'equal)))
    (dolist (entry entries)
      (when (eq (pp.runtime::runtime-artifact-entry-kind entry) :file)
        (let ((path (pp.runtime::runtime-artifact-entry-path entry)))
          (setf (gethash path desired) entry)
          (let* ((pair (find path (pp.kernel:value-map-entries observed)
                              :key (lambda (item)
                                     (pp.kernel:value-string-value
                                      (car item)))
                              :test #'string=))
                 (old (and pair
                           (pp.kernel:value-string-value (cdr pair)))))
            (cond ((null old) (push entry creates))
                  ((not (string= old
                                 (pp.runtime::runtime-artifact-entry-blob entry)))
                   (push entry updates)))))))
    (dolist (pair (pp.kernel:value-map-entries observed))
      (let ((path (pp.kernel:value-string-value (car pair))))
        (unless (gethash path desired)
          (push path deletes))))
    (setf creates (sort creates #'string<
                           :key #'pp.runtime::runtime-artifact-entry-path)
          updates (sort updates #'string<
                           :key #'pp.runtime::runtime-artifact-entry-path)
          deletes (sort deletes #'string<))
    (let ((items
            (append
             (mapcar (lambda (entry)
                       (%reconcile-entry-value entry))
                     creates)
             (mapcar (lambda (entry)
                       (%reconcile-entry-value entry "update"))
                     updates)
             (mapcar (lambda (path)
                       (pp.kernel:make-vmap
                        (list (cons (pp.kernel:make-vkeyword "content")
                                    (pp.kernel:make-vnil))
                              (cons (pp.kernel:make-vkeyword "kind")
                                    (pp.kernel:make-vstring "delete"))
                              (cons (pp.kernel:make-vkeyword "rel")
                                    (pp.kernel:make-vstring path)))))
                     deletes)))
          (summary
            (pp.kernel:make-vvector-from-list
             (list (pp.kernel:make-vvector-from-list
                    (list (pp.kernel:make-vkeyword "root")
                          (pp.kernel:make-vstring root)))
                   (pp.kernel:make-vvector-from-list
                    (list (pp.kernel:make-vkeyword "create")
                          (pp.kernel:make-vstring (format nil "~D" (length creates)))))
                   (pp.kernel:make-vvector-from-list
                    (list (pp.kernel:make-vkeyword "update")
                          (pp.kernel:make-vstring (format nil "~D" (length updates)))))
                   (pp.kernel:make-vvector-from-list
                    (list (pp.kernel:make-vkeyword "delete")
                          (pp.kernel:make-vstring (format nil "~D" (length deletes)))))))))
      (values
       (pp.kernel:make-vmap
        (list (cons (pp.kernel:make-vkeyword "items")
                    (%reconcile-list items))
              (cons (pp.kernel:make-vkeyword "summary") summary)))
       creates updates deletes))))

 (defun %reconcile-record-gc-root (session value &key (keep 0))
  (let ((layout (pp.runtime::runtime-session-store-layout session)))
    (when layout
      (let ((objects-service
              (pp.runtime:runtime-session-find-service session :store-objects))
            (root-value (%reconcile-root-value value)))
        (when objects-service
          (pp.runtime::object-repository-put
           (funcall objects-service)
           :key (pp.kernel:hash-value root-value)
           :value root-value))
        (pp.runtime:gc-roots-record
         layout
         (pp.runtime:make-store-gc-root
          (pp.kernel:hash-value root-value)
          (pp.runtime:runtime-session-wanted-nodes session))
         :keep keep)))))

 (defun %run-reconcile-command-basic (arguments output error-output
                                      &key runtime-options desired-value)
  (multiple-value-bind (operands grants why no-cache check keep-epochs grace-seconds)
      (%parse-command-options arguments)
    (declare (ignore grace-seconds))
    (when (<= keep-epochs 0)
      (error "--gc-keep-epochs must be positive"))
    (unless (or desired-value (= (length operands) 2))
      (error "--reconcile requires ROOT and one source file"))
    (let* ((root (first operands))
           (source-path (second operands))
           (session (%make-command-session
                     grants :why why :no-cache no-cache
                     :source-roots (and source-path (list source-path))
                     :check check :error-output error-output))
           (desired-blobs
             (let ((shared-root (and runtime-options
                                     (getf runtime-options :desired-shared-root))))
               (and shared-root
                    (pp.runtime:make-blob-repository
                     (pp.runtime:make-store-layout shared-root)))))
           (target (pp.kernel:canonicalize-path root
                                                 :realpath #'pp.runtime:store-canonical-path)))
      (declare (ignore target))
      (when runtime-options
        (%command-schedule-node-force
         session (%command-runtime-policy
                  (getf runtime-options :policy)))
        (%command-recover-fenced
         session (getf runtime-options :fenced) error-output))
      (%command-dynamic-top-level
       session
       (lambda ()
         (unless (%command-capability-allows-file-p nil root nil :write)
           (error "reconcile: capability denied for write: ~A" root))
         (let* ((raw-value
                  (if desired-value
                      (%command-map-field desired-value "fs")
                      (let ((forms
                              (%read-language-forms (%read-source-file source-path)
                                                    source-path
                                                    (%source-surface source-path))))
                        (let ((pp.runtime::*runtime-artifact-session* session))
                          (%run-language-forms forms source-path output
                                               :print-values nil :return-value t
                                               :session session :grant-specs grants
                                               :why why :no-cache no-cache :check check
                                               :error-output error-output)))))
                (value (pp.runtime:runtime-evaluator-force-deep
                        (pp.runtime:runtime-session-evaluator session) raw-value))
                (entries (pp.runtime::runtime-artifact-tree-from-value value))
                (read-current
                  (%command-capability-allows-file-p nil root nil :read))
                (observed (if read-current
                              (pp.runtime::runtime-artifact-observe-value root)
                              (pp.kernel:make-vmap nil))))
           (when desired-blobs
             (%command-publish-copy-blobs
              value desired-blobs
              (funcall (runtime-session-find-service session :store-blobs))))
           (%reconcile-stratification-check session root)
           (multiple-value-bind (plan creates updates deletes)
               (%reconcile-plan root entries observed)
             (declare (ignore creates updates deletes))
             (let* ((root-value (%reconcile-root-value value))
                    (root-hash (pp.kernel:hash-value root-value))
                    (objects-service
                      (pp.runtime:runtime-session-find-service session :store-objects))
                    (traces-service
                      (pp.runtime:runtime-session-find-service session :store-traces))
                    (objects (and objects-service (funcall objects-service)))
                    (traces (and traces-service (funcall traces-service)))
                    (plan-key
                      (pp.kernel:hash-concat
                       (list "domain-plan" (%reconcile-fs-diff-hash root)
                             (pp.kernel:hash-value observed)
                             (pp.kernel:hash-value value)))))
               (when objects
                 (pp.runtime::object-repository-put objects
                  :key root-hash :value root-value)
                 (pp.runtime::object-repository-put objects
                  :key (pp.kernel:hash-value plan) :value plan))
               (when traces
                 (pp.runtime::trace-repository-put
                  traces :key plan-key :outcome :ok
                  :result-hash (pp.kernel:hash-value plan) :reads nil))
               (let ((counts
                       (let ((pp.runtime::*runtime-artifact-session* session))
                         (multiple-value-list
                          (pp.runtime::runtime-artifact-reconcile
                           root value :read-current read-current)))))
                 (let* ((observed-after
                          (if read-current
                              (pp.runtime::runtime-artifact-observe-value root)
                              observed))
                        (plan-after
                          (multiple-value-bind (p c u d)
                              (%reconcile-plan root entries observed-after)
                            (declare (ignore c u d))
                            p))
                        (plan-after-key
                          (pp.kernel:hash-concat
                           (list "domain-plan" (%reconcile-fs-diff-hash root)
                                 (pp.kernel:hash-value observed-after)
                                 (pp.kernel:hash-value value)))))
                   (when objects
                     (pp.runtime::object-repository-put objects
                      :key (pp.kernel:hash-value plan-after)
                      :value plan-after))
                   (when traces
                     (pp.runtime::trace-repository-put
                      traces :key plan-after-key :outcome :ok
                      :result-hash (pp.kernel:hash-value plan-after)
                      :reads nil))
                   (%reconcile-record-gc-root session value :keep keep-epochs)
                   (let ((pass-hash
                           (pp.kernel:hash-concat
                            (list "domain-pass" "fs"
                                  (pp.kernel:hash-value value)))))
                     (pp.runtime::runtime-journal-append
                      session
                      (pp.runtime::make-runtime-journal-domain-intent
                       pass-hash
                       (list (cons "root" root)
                             (cons "create" (format nil "~D" (first counts)))
                             (cons "update" (format nil "~D" (second counts)))
                             (cons "delete" (format nil "~D" (third counts))))))
                     (pp.runtime::runtime-journal-append
                      session
                      (pp.runtime::make-runtime-journal-domain-done pass-hash))
                     (pp.runtime::runtime-journal-append
                      session
                      (pp.runtime::make-runtime-journal-epoch root-hash)))
                   (when runtime-options
                     (runtime-fenced-drain session))
                   (format error-output
                           "[reconcile:fs] root=~A create=~D update=~D delete=~D~%"
                           root (first counts) (second counts) (third counts))
                   (finish-output error-output)
                   0))))))))
))
 (defun %run-reconcile-command (arguments output error-output)
  (multiple-value-bind (operands options)
      (%command-runtime-options arguments)
    (let ((reconcile (remove "--reconcile" operands :test #'string= :count 1))
          (desired-hash (getf options :desired-object))
          (shared-root (getf options :desired-shared-root)))
      (if desired-hash
          (let* ((layout (pp.runtime:make-store-layout shared-root))
                 (objects (progn
                            (pp.runtime:store-layout-init layout)
                            (pp.runtime:make-object-repository layout)))
                 (value (pp.runtime:object-repository-get
                         objects :key desired-hash)))
            (unless value
              (error "desired object unavailable: ~A" desired-hash))
            (%run-reconcile-command-basic
             reconcile output error-output :runtime-options options
             :desired-value value))
          (%run-reconcile-command-basic
           reconcile output error-output :runtime-options options)))))
(defun %run-graph-command (arguments output error-output)
  (multiple-value-bind (operands grants why no-cache check ignored-keep ignored-grace)
      (%parse-command-options (remove "graph" arguments :test #'string= :count 1))
    (declare (ignore ignored-keep ignored-grace))
    (unless (= (length operands) 1)
      (error "graph requires exactly one source file"))
    (let ((path (first operands)))
      (%run-language-files
       (list path) output :grant-specs grants :why why :no-cache no-cache
       :check check :error-output error-output)
    (let* ((layout (make-store-layout (%command-store-root)))
           (traces (make-trace-repository layout))
           (nodes (trace-repository-keys traces))
           (edges 0))

      (dolist (key nodes)
        (dolist (trace (trace-repository-load traces :key key))
          (dolist (read (store-trace-reads trace))
            (incf edges)
            (format output "~A → ~A~%"
                    (store-trace-read-cell read) key))))
      (format output "~D node(s), ~D edge(s)~%" (length nodes) edges)
      (finish-output output)
      0)))
)
(defun %command-unix-time ()
  (- (get-universal-time) 2208988800))
(defun %command-random-hex (octet-count)
  (let ((bytes (make-array octet-count :element-type '(unsigned-byte 8))))
    #+sbcl
    (with-open-file (stream "/dev/urandom" :direction :input
                            :element-type '(unsigned-byte 8))
      (unless (= (read-sequence bytes stream) octet-count)
        (error "unable to read secure random bytes")))
    #-sbcl
    (dotimes (index octet-count)
      (setf (aref bytes index) (random 256)))
    (string-downcase
     (with-output-to-string (output)
       (loop for byte across bytes do (format output "~2,'0X" byte))))))

(defun %command-read-required-text (path kind)
  (or (and (stringp path) (probe-file path) (store-read-text path))
      (error "~A is not readable: ~A" kind path)))

(defun %command-write-text (path text &key exclusive)
  (when (and exclusive (probe-file path))
    (error "refusing to overwrite existing file: ~A" path))
  (with-open-file (stream path :direction :output
                          :if-exists (if exclusive :error :supersede)
                          :if-does-not-exist :create)
    (write-string text stream)
    (finish-output stream))
  #+sbcl
  (sb-posix:chmod (store-absolute-path path) #o600)
  path)
(defun %command-store-version-path (layout)
  (merge-pathnames "VERSION"
                   (pathname (format nil "~A/" (store-layout-root layout)))))


(defun %run-cluster-init-command (arguments output)
  (unless (= (length arguments) 1)
    (error "cluster-init does not accept arguments"))
  (let* ((home (%command-home))
         (directory (pp.kernel:cluster-dir home))
         (secret-path (pp.kernel:secret-path home))
         (id-path (pp.kernel:id-path home))
         (secret (%command-random-hex 32))
         (cluster-id (%command-random-hex 16)))
    (store-ensure-directory directory)
    (when (probe-file secret-path)
      (error "pp cluster-init: a cluster secret already exists at ~A — refusing to overwrite (this would invalidate every token already minted against it); remove it by hand first if you really mean to rotate"
             secret-path))
    (store-atomic-replace secret-path (concatenate 'string secret (string #\Newline)))
    (unless (probe-file id-path)
      (store-atomic-replace id-path (concatenate 'string cluster-id (string #\Newline))))
    (format output
            "pp cluster-init: minted ~A (mode 0600) and cluster id ~A~%pp cluster-init: distribute BOTH files to other cluster members out of band, at the same path (~~/.pp/cluster/) — pp never transmits them~%"
            secret-path cluster-id)
    (finish-output output)
    0))

(defun %run-mint-token-command (arguments)
  (unless (and (>= (length arguments) 3)
               (string= (first arguments) "--mint-token"))
    (error "--mint-token requires OUT TTL-SECS"))
  (let ((output-path (second arguments))
        (ttl-text (third arguments))
        (rest (cdddr arguments))
        (grants nil))
    (let ((ttl (handler-case (parse-integer ttl-text :junk-allowed nil)
                 (error () (error "invalid --mint-token ttl-seconds: ~A"
                                  ttl-text)))))
      (loop while rest do
        (let ((argument (pop rest)))
          (unless (string= argument "--grant")
            (error "--mint-token: unrecognized argument: ~A" argument))
          (unless rest
            (error "--grant requires one capability specification"))
          (push (pop rest) grants)))
      (let* ((home (%command-home))
             (secret (pp.kernel:load-secret
                      (lambda (path)
                        (%command-read-required-text path "cluster secret"))
                      home))
             (cluster-id (pp.kernel:load-cluster-id
                          (lambda (path)
                            (%command-read-required-text path "cluster id"))
                          home))
             (token
               (pp.kernel:mint-capability-token
                :secret secret :cluster-id cluster-id
                :specs (nreverse grants)
                :issued (%command-unix-time)
                :ttl-seconds ttl)))
        (%command-write-text output-path token)
        0))))

(defun %command-reply-quoted (text cursor)
  (multiple-value-bind (value next)
      (pp.kernel:parse-quoted-string text cursor)
    (unless (and value next) (error "malformed serve-hit reply"))
    (values value next)))

(defun %command-reply-prefix (text cursor literal)
  (and (<= (+ cursor (length literal)) (length text))
       (string= text literal :start1 cursor
               :end1 (+ cursor (length literal)))
       (+ cursor (length literal))))


(defun %command-parse-serve-reply (text)
  (setf text (string-trim '(#\Space #\Tab #\Return #\Newline) text))
  (let ((cursor 0)
        (length (length text)))
    (labels ((fail ()
               (error "malformed serve-hit reply"))
             (prefix (literal)
               (when (and (<= (+ cursor (length literal)) length)
                          (string= text literal :start1 cursor
                                  :end1 (+ cursor (length literal))))
                 (incf cursor (length literal))
                 t))
             (space ()
               (unless (and (< cursor length)
                            (char= (char text cursor) #\Space))
                 (fail))
               (incf cursor))
             (quoted ()
               (multiple-value-bind (value next)
                   (pp.kernel:parse-quoted-string text cursor)
                 (unless (and value next) (fail))
                 (setf cursor next)
                 value))
             (close-reply ()
               (unless (and (< cursor length)
                            (char= (char text cursor) #\)))
                 (fail))
               (incf cursor)))
      (unless (prefix "(serve-hit-reply ") (fail))
      (let* ((end (or (cl:position #\Space text :start cursor) (fail)))
             (kind (subseq text cursor end)))
        (setf cursor (1+ end))
        (let ((key (quoted)))
          (cond
            ((string= kind "miss")
             (close-reply)
             (unless (= cursor length) (fail))
             (list :kind :miss :key key))
            ((string= kind "deny")
             (space)
             (let ((reason (quoted)))
               (close-reply)
               (unless (= cursor length) (fail))
               (list :kind :deny :key key :reason reason)))
            ((string= kind "hit")
             (let ((result nil)
                   (blobs nil))
               (space)
               (setf result (quoted))
               (space)
               (unless (and (< cursor length)
                            (char= (char text cursor) #\())
                 (fail))
               (incf cursor)
               (loop
                 (when (>= cursor length) (fail))
                 (if (char= (char text cursor) #\))
                     (progn (incf cursor) (return))
                     (progn
                       (push (quoted) blobs)
                       (cond
                         ((and (< cursor length)
                               (char= (char text cursor) #\Space))
                          (incf cursor))
                         ((and (< cursor length)
                               (char= (char text cursor) #\)))
                          nil)
                         (t (fail))))))
               (close-reply)
               (unless (= cursor length) (fail))
               (list :kind :hit :key key :result result
                     :blobs (nreverse blobs))))
            (t (fail))))))))
(defun %command-serve-hit-blobs (value traces)
  (let ((hashes nil))
    (labels ((add (hash)
               (when (and (stringp hash) (store-digest-p hash))
                 (push hash hashes))))
      (handler-case
          (dolist (entry (runtime-artifact-tree-from-value value))
            (add (runtime-artifact-entry-blob entry)))
        (error () nil))
      (dolist (trace traces)
        (dolist (read (store-trace-reads trace))
          (let* ((cell-text (store-identity-string
                             (store-trace-read-cell read)))
                 (cell (ignore-errors (pp.kernel:cell-parse cell-text))))
            (when (and cell
                       (or (typep cell 'pp.kernel:cell-file)
                           (typep cell 'pp.kernel:cell-runtime-file)))
              (add (store-identity-string
                    (store-trace-read-hash read)))))))
    (sort (remove-duplicates hashes :test #'string=) #'string<))))

(defun %command-serve-hit-command (arguments output)
  (declare (ignore output))
  (unless (= (length arguments) 5)
    (error "--serve-hit requires KEY TOKEN-FILE SHARED-ROOT REPLY-FILE"))
  (let* ((key (second arguments))
         (token-path (third arguments))
         (shared-root (fourth arguments))
         (reply-path (fifth arguments))
         (home (%command-home))
         (secret (pp.kernel:load-secret
                  (lambda (path)
                    (%command-read-required-text path "cluster secret"))
                  home))
         (cluster-id (pp.kernel:load-cluster-id
                      (lambda (path)
                        (%command-read-required-text path "cluster id"))
                      home))
         (token (%command-read-required-text token-path "token"))
         (session (%make-command-session nil :error-output *error-output*))
         (decision nil))
    (unless (store-digest-p key)
      (error "--serve-hit requires a canonical node key"))
    (multiple-value-bind (capabilities rejection)
        (pp.kernel:verify-capability-token
         token :secret secret :cluster-id cluster-id
         :now (%command-unix-time)
         :realpath #'pp.runtime:store-canonical-path)
      (if rejection
          (setf decision (list :kind :deny :key key :reason rejection))
          (setf decision
                (%command-dynamic-top-level
                 session
                 (lambda ()
                   (let* ((traces-service
                            (runtime-session-find-service session :store-traces))
                          (objects-service
                            (runtime-session-find-service session :store-objects))
                          (blobs-service
                            (runtime-session-find-service session :store-blobs))
                          (traces (funcall traces-service))
                          (objects (funcall objects-service))
                          (blobs (funcall blobs-service))
                          (all (trace-repository-load traces :key key))
                          (authorized
                            (remove-if-not
                             (lambda (trace)
                               (every
                                (lambda (read)
                                  (let ((cell (ignore-errors
                                                (pp.kernel:cell-parse
                                                 (store-identity-string
                                                  (store-trace-read-cell read))))))
                                    (and cell
                                         (runtime-observation-authorized-p
                                          capabilities cell))))
                                (store-trace-reads trace)))
                             all))
                          (chosen nil)
                          (chosen-trace nil))
                     (dolist (trace authorized)
                       (let* ((result-hash
                                (store-identity-string
                                 (store-trace-result-hash trace)))
                              (value (object-repository-get
                                      objects :key result-hash)))
                         (when (and value
                                    (string= result-hash (hash-value value))
                                    (ignore-errors (encode-value value)))
                           (when (or (null chosen)
                                     (store-trace-outcome-ok-p
                                      (store-trace-outcome trace)))
                             (setf chosen value chosen-trace trace))
                           (when (and chosen-trace
                                      (store-trace-outcome-ok-p
                                       (store-trace-outcome trace)))
                             (return)))))
                     (if (null chosen)
                         (list :kind :miss :key key)
                         (let ((visible (remove-if-not
                                         (lambda (trace)
                                           (member trace authorized))
                                         (list chosen-trace))))
                           (list :kind :hit :key key
                                 :result (hash-value chosen)
                                 :value chosen
                                 :traces visible
                                 :blobs (%command-serve-hit-blobs
                                         chosen visible)
                                 :blobrepo blobs)))))))))
    (ecase (getf decision :kind)
      (:deny
       (%command-write-text
        reply-path
        (format nil "(serve-hit-reply deny ~A ~A)~%"
                (pp.kernel:quote-string key)
                (pp.kernel:quote-string (getf decision :reason)))))
      (:miss
       (%command-write-text
        reply-path
        (format nil "(serve-hit-reply miss ~A)~%"
                (pp.kernel:quote-string key))))
      (:hit
       (let* ((layout (make-store-layout shared-root))
              (local-layout (make-store-layout (%command-store-root)))
              (remote-traces nil)
              (version-path (%command-store-version-path layout))
              (had-version (probe-file version-path)))
         (store-layout-init layout)
         (setf remote-traces (make-trace-repository layout))
         (distribution-transport-push
          local-layout layout :object (getf decision :result))
         (dolist (trace (getf decision :traces))
           (trace-repository-put
            remote-traces :key key
            :outcome (store-trace-outcome trace)
            :result-hash (store-trace-result-hash trace)
            :reads (store-trace-reads trace)))
         (dolist (blob (getf decision :blobs))
           (distribution-transport-push local-layout layout :blob blob))
         (unless had-version
           (when (probe-file version-path)
             (delete-file version-path)))
         (%command-write-text

          reply-path
          (format nil "(serve-hit-reply hit ~A ~A (~{~A~^ ~}))~%"
                  (pp.kernel:quote-string key)
                  (pp.kernel:quote-string (getf decision :result))
                  (mapcar #'pp.kernel:quote-string (getf decision :blobs)))))
    ))
    0))

(defun %run-recv-hit-command (arguments output)
  (unless (= (length arguments) 3)
    (error "--recv-hit requires REPLY-FILE SHARED-ROOT"))
  (let* ((reply-path (second arguments))
         (shared-root (third arguments))
         (reply (%command-read-required-text reply-path "serve-hit reply"))
         (decision (%command-parse-serve-reply reply)))
    (ecase (getf decision :kind)
      (:miss
       (format output "recv-hit: miss key=~A~%" (getf decision :key)))
      (:deny
       (format output "recv-hit: deny key=~A reason=~A~%"
               (getf decision :key) (getf decision :reason)))
      (:hit
       (let* ((local (make-store-layout (%command-store-root)))
              (shared (make-store-layout shared-root))
              (version-path (%command-store-version-path shared))
              (had-version (probe-file version-path)))
         (store-layout-init local)
         (unless (probe-file shared-root)
           (error "transport: shared root is unavailable: ~A" shared-root))
         (unless had-version
           (store-atomic-replace version-path pp.runtime:+store-version+))
         (unwind-protect
             (progn
               (distribution-transport-pull
                shared local :object (getf decision :result))
               (distribution-transport-pull
                shared local :trace (getf decision :key))
               (dolist (blob (getf decision :blobs))
                 (distribution-transport-pull shared local :blob blob))
               (format output "recv-hit: hit key=~A result=~A~%"
                       (getf decision :key) (getf decision :result)))
           (unless had-version
             (when (probe-file version-path)
               (delete-file version-path)))))))
    (finish-output output)
    0))

(defun %run-transport-command (direction arguments output)
  (unless (= (length arguments) 4)
    (error "~A requires KIND HASH ROOT"
           (if (eq direction :push) "--transport-push" "--transport-pull")))
  (let* ((kind (second arguments))
         (hash (third arguments))
         (root (fourth arguments))
         (local (pp.runtime:make-store-layout (%command-store-root))))
    (pp.runtime:store-layout-init local)
    (if (eq direction :push)
        (let* ((shared (pp.runtime:make-store-layout root))
               (version-path (%command-store-version-path shared))
               (had-version (probe-file version-path)))
          (pp.runtime:store-layout-init shared)
          (unwind-protect
              (handler-case
                  (pp.runtime:distribution-transport-push local shared kind hash)
                (pp.runtime:distribution-error (condition)
                  (error "transport: ~A~:[~; (corrupt or tampered in transit)~]"
                         (pp.runtime:distribution-error-detail condition)
                         (not (search "tampered in transit"
                                      (pp.runtime:distribution-error-detail condition)
                                      :test #'char-equal)))))
            (unless had-version
              (when (probe-file version-path)
                (delete-file version-path)))))
        (progn
          (unless (probe-file root)
            (error "transport: shared root is unavailable: ~A" root))
          (let* ((shared (pp.runtime:make-store-layout root))
                 (version-path (%command-store-version-path shared))
                 (had-version (probe-file version-path)))
            (unless had-version
              (store-atomic-replace version-path pp.runtime:+store-version+))
            (unwind-protect
                (handler-case
                    (pp.runtime:distribution-transport-pull shared local kind hash)
                  (pp.runtime:distribution-error (condition)
                    (error "transport: ~A~:[~; (corrupt or tampered in transit)~]"
                           (pp.runtime:distribution-error-detail condition)
                           (not (search "tampered in transit"
                                        (pp.runtime:distribution-error-detail condition)
                                        :test #'char-equal)))))
              (unless had-version
                (when (probe-file version-path)
                  (delete-file version-path)))))))
    0))


(defun %reject-runtime-flags (arguments)
  (let ((flag (find-if #'%runtime-flag-p arguments)))
    (when flag
      (error "~A is unavailable: effect/distribution runtime services are not installed"
             flag)))
  arguments)


(defun %parse-fmt-arguments (arguments)
  (let ((target nil) (path nil) (in-place nil))
    (loop while arguments do
      (let ((argument (pop arguments)))
        (cond
          ((or (string= argument "-i") (string= argument "--in-place"))
           (setf in-place t))
          ((or (string= argument "--to-braces")
               (string= argument "--to-sexpr"))
           (when target
             (error "pp fmt: specify exactly one of --to-braces or --to-sexpr"))
           (unless arguments
             (error "pp fmt: unrecognized argument: ~A" argument))
           (setf target (if (string= argument "--to-braces")
                            :brace :sexpr)
                 path (pop arguments)))
          (t (error "pp fmt: unrecognized argument: ~A" argument)))))
    (unless target
      (error "pp fmt: specify exactly one of --to-braces or --to-sexpr"))
    (values target path in-place)))

(defun %run-fmt (arguments output)
  (multiple-value-bind (target path in-place)
      (%parse-fmt-arguments arguments)
    (let ((source (%read-source-file path)))
      (case target
        (:brace
         ;; fmt reads the file with the target surface's inverse reader
         ;; directly; the file's extension carries no authority (OCaml
         ;; command_frontend.ml never checked it either).
         (let* ((forms (read-source source :source path :surface :sexpr))
                (comments (scan-comments source :surface :sexpr))
                (base (handler-case
                          (print-source forms :surface :brace :source path)
                        (frontend-error (condition)
                          (error "pp fmt --to-braces: ~A"
                                 (frontend-error-message condition)))))
                (text (splice-comments comments base :delim #\#)))
           (if in-place
               (progn
                 (%write-source-file path text)
                 0)
               (progn
                 (%emit-frontend-text text output)
                 0))))
        (:sexpr
         (let* ((forms (read-source source :source path :surface :brace))
                (comments (scan-comments source :surface :brace))
                (base (print-source forms :surface :sexpr :source path))
                (text (splice-comments comments base :delim #\;)))
           (if in-place
               (progn
                 (%write-source-file path text)
                 0)
               (progn
                 (%emit-frontend-text text output)
                 0))))))))

(defun %run-emit-braces (path output)
  (when (%brace-source-path-p path)
    (error "pp --emit-braces: ~A is already a brace file" path))
  (let* ((source (%read-source-file path))
         (forms (read-source source :source path :surface :sexpr))
         (text (handler-case
                   (print-source forms :surface :brace :source path)
                 (frontend-error (condition)
                   (error "pp --emit-braces: ~A"
                          (frontend-error-message condition))))))
    (%emit-frontend-text text output)))

(defun %canonical-form-hash (form source)
  ;; Reader locations are surface metadata.  Re-reading the canonical sexpr
  ;; printer output gives both sides the same location shape before the kernel
  ;; hash is compared, while still checking the actual AST/hash boundary.
  (let* ((text (print-source (list form) :surface :sexpr :source source))
         (canonical (read-source text :source source :surface :sexpr)))
    (unless (= (length canonical) 1)
      (error "canonical form did not re-read as one expression"))
    (pp.kernel:hash-expr (first canonical))))

(defun %run-roundtrip-braces (path output error-output)
  (declare (ignore output))
  (when (%brace-source-path-p path)
    (error "pp --roundtrip-braces: ~A is already a brace file" path))
  (let* ((source (%read-source-file path))
         (forms (read-source source :source path :surface :sexpr))
         (braces
           (handler-case
               (print-source forms :surface :brace :source path)
             (frontend-error (condition)
               (error "roundtrip: unprintable: ~A"
                      (frontend-error-message condition))))))
    (handler-case
        (let ((roundtripped
                (read-source braces :source path :surface :brace)))
          (unless (= (length forms) (length roundtripped))
            (error "roundtrip: form count diverged: ~D sexpr vs ~D brace"
                   (length forms) (length roundtripped)))
          (loop for left in forms
                for right in roundtripped
                for index from 0
                for left-hash = (%canonical-form-hash left path)
                for right-hash = (%canonical-form-hash right path)
                unless (string= left-hash right-hash)
                  do (error "roundtrip: form ~D hash diverged: ~A vs ~A"
                            index left-hash right-hash))
          0)
      (frontend-error (condition)
        (format error-output "--- emitted brace text ---~%~A~%"
                braces)
        (finish-output error-output)
        (error "roundtrip: brace re-read failed: ~A"
               (%frontend-error-text condition)))
      (error (condition)
        (format error-output "--- emitted brace text ---~%~A~%"
                braces)
        (finish-output error-output)
        (error "~A" condition)))))

(defun %run-compare-hash (path1 path2)
  (let* ((source1 (%read-source-file path1))
         (source2 (%read-source-file path2))
         (forms1 (read-source source1 :source path1
                              :surface (%source-surface path1)))
         (forms2 (read-source source2 :source path1
                              :surface (%source-surface path2))))
    (unless (= (length forms1) (length forms2))
      (error "--compare-hash: form count diverged: ~D (~A) vs ~D (~A)"
             (length forms1) path1 (length forms2) path2))
    (loop for left in forms1
          for right in forms2
          for index from 0
          unless (string= (%canonical-form-hash left path1)
                          (%canonical-form-hash right path1))
            do (error "--compare-hash: form ~D hash diverged" index))
    0))

(defun %run-list-comments (surface path output)
  (let* ((source (%read-source-file path))
         (comments (scan-comments source :surface surface)))
    (dolist (comment comments)
      (format output "~D: ~A~%"
              (pp.frontend::frontend-comment-line comment)
              (string-trim '(#\Space #\Tab #\Return)
                           (pp.frontend::frontend-comment-text comment))))
    (finish-output output)
    0))

(defun %run-lint (path output error-output)
  (declare (ignore output))
  (let ((source (%read-source-file path)))
    (handler-case
        (let* ((forms (read-source source :source path :surface :brace))
               (warnings (lint-source forms :source path))
               (ordered (stable-sort (copy-list warnings) #'< :key (lambda (w)
                                                                    (getf w :line)))))
          (if ordered
              (progn
                (dolist (warning ordered)
                  (format error-output "~A:~D: warning: ~A~%"
                          path (getf warning :line)
                          (getf warning :message)))
                (format error-output "~D warning~:P found in ~A~%"
                        (length ordered) path)
                (finish-output error-output)
                1)
              (progn
                (format error-output "pp lint: no warnings for ~A~%" path)
                (finish-output error-output)
                0)))
      (frontend-error (condition)
        (if (frontend-error-incomplete-p condition)
            (error condition)
            (progn
              (format error-output "pp lint: parse error in ~A: ~A~%"
                      path (%frontend-error-text condition :full-range t))
              (finish-output error-output)
              1))))))

(defun %dump-surface-tables (output)
  ;; Keep this rendering data-driven: the frontend owns the closed sets, while
  ;; the app owns only the stream representation of the dump.
  (let* ((tables (surface-tables))
         (observations (getf tables :observations))
         (with-descriptors (getf tables :with))
         (grant-descriptors (getf tables :needs)))
    (format output "#### Observation heads — `$KIND(args…)`~%~%")
    (format output "| head | arity | qq | lowering | meaning |~%")
    (format output "|---|---|---|---|---|~%")
    (dolist (row observations)
      (destructuring-bind (name minimum maximum qq lowering) row
        (let* ((arity (if (= minimum maximum)
                          (format nil "~D" minimum)
                          (format nil "~D..~D" minimum maximum)))
               (lowering-text
                 (cond
                   ((member name '("file" "secret") :test #'string=)
                    "(slurp $1)")
                   ((string= name "env")
                    "(if (nil? (env-get $1)) $2 (env-get $1))")
                   ((string= name "glob")
                    "(perform tree-observe $1)")
                   ((string= name "probe") "(probe $1)")
                   ((string= name "config") "(config $1 $2)")
                   (t (or lowering ""))))
               (meaning
                 (cond
                   ((string= name "file")
                    "$file(path) — read a file's contents (records a file: cell)")
                   ((string= name "env")
                    "$env(name[, default]) — read an environment variable (records an env: cell); the optional default is used when the variable is unset")
                   ((string= name "glob")
                    "$glob(path) — observe a directory tree (records a tree: cell)")
                   ((string= name "probe")
                    "$probe(name) — read an observer-written volatile probe cell")
                   ((string= name "secret")
                    "$secret(path) — read a sealed (confidential) file")
                   ((string= name "config")
                    "$config(key[, default]) — read a scoped config value (records a config: cell); the optional default is used when the key is unset")
                   (t "surface observation"))))
          (format output "| `$~A` | ~A | ~A | `~A` | ~A |~%"
                  name arity (if qq "yes" "no") lowering-text meaning))))
    (format output "~%#### `with { }` clauses~%~%")
    (format output "| keyword | wrapper | meaning |~%")
    (format output "|---|---|---|~%")
    (dolist (row with-descriptors)
      (let* ((name (first row))
             (wrapper (getf (rest row) :wrapper))
             (colon (getf (rest row) :colon))
             (meaning (cond
                        ((string= name "caps")
                         "caps: C — run the body with capability set C")
                        ((string= name "config")
                         "config: M — run the body with ambient config map M")
                        ((string= name "handlers")
                         "handlers: { :name -> fn, ... } — install a map of effect handlers")
                        (t (format nil "~A: clause lowered by the frontend" name)))))
        (format output "| `~A~A` | `~(~A~)` | ~A |~%"
                name (if colon ":" "") wrapper meaning)))
    (format output "~%#### Grant-descriptor sugar (inside `needs`)~%~%")
    (format output "| descriptor | lowering | meaning |~%")
    (format output "|---|---|---|~%")
    (dolist (row grant-descriptors)
      (let ((name (first row))
            (mode (getf (rest row) :mode)))
        (format output "| `~A` | `(cap-restrict (current-capabilities) $1 :~A)` | ~A |~%"
                name mode
                (cond
                  ((string= name "fs.read")
                   "fs.read(p) — read-only fs grant for p")
                  ((string= name "fs.write")
                   "fs.write(p) — write-only fs grant for p")
                  ((string= name "fs.rw")
                   "fs.rw(p) — read-write fs grant for p")
                  (t (format nil "~A capability grant" name)))))
    (finish-output output)
    0)))

(defun %dump-builtins (output)
  (write-string (runtime-primitive-render (runtime-install-pure-primitives))
                output)
  (finish-output output)
  0)

(defun %run-kernel-props (arguments output)
  (unless (and (first arguments)
               (string= (first arguments) "--check-kernel-props"))
    (error "--check-kernel-props requires --seed and --count options"))
  (let ((seed 1)
        (count 3000)
        (rest (rest arguments)))
    (loop while rest do
      (let ((argument (pop rest)))
        (cond
          ((member argument '("--seed" "--count") :test #'string=)
           (unless rest (error "~A requires an integer" argument))
           (let ((value (handler-case
                            (parse-integer (pop rest) :junk-allowed nil)
                          (error ()
                            (error "invalid --kernel-props ~A: ~A"
                                   (subseq argument 2) (first rest))))))
             (if (string= argument "--seed")
                 (setf seed value)
                 (setf count value))))
          (t (error "--check-kernel-props: unrecognized argument: ~A"
                    argument)))))
    (unless (plusp count)
      (error "--kernel-props count must be positive"))
    (let* ((expr-specs
             '(("literal-int" "1") ("symbol" "x") ("if" "x")
               ("let" "x") ("fn" "x") ("apply" "x") ("quote" "x")
               ("force" "x") ("with-caps" "x") ("perform" "x")
               ("with-handler" "x") ("delay" "x") ("node" "x")
               ("defnode" "x") ("do" "x") ("def" "x")
               ("defvalue" "x") ("letstar" "x") ("module" "x")
               ("import" "x") ("load" "x") ("loadmodule" "x")
               ("island" "x") ("with-config" "x") ("config" "x")
               ("typed" "x") ("located" "x") ("match" "x")))
           (expressions
             (mapcar (lambda (spec)
                       (%property-expr (first spec) (second spec)))
                     expr-specs))
           (printable-expressions
             (remove-if
              (lambda (form)
                (or (typep form 'expr-force)
                    (typep form 'expr-fn)
                    (typep form 'expr-defnode)
                    (typep form 'expr-def)
                    (typep form 'expr-defvalue)))
              expressions))
           (patterns
             (list (make-pliteral (make-vint 1))
                   (make-pvariable "x")
                   (make-pwildcard)
                   (make-plist (list (make-pliteral (make-vint 1))))
                   (make-ptagged "tag" (list (make-pliteral (make-vint 1))))))
           (values
             (list (make-vnil) (make-vbool t) (make-vint 1)
                   (make-vfloat 1.5d0) (make-vstring "x")
                   (make-vkeyword "k") (make-vsymbol "s")
                   (make-vpair (make-vint 1) (make-vnil))
                   (make-vvector-from-list (list (make-vint 1)))
                   (make-vmap (list (cons (make-vstring "k") (make-vint 1))))
                   (make-vset (list (make-vint 1)))))
           (caps
             (list
              (make-cap-none)
              (mint-capability "fs:/g:ro" :realpath #'identity)
              (mint-capability "net:example.test:443" :realpath #'identity)
              (mint-capability "secret:/g" :realpath #'identity)
              (mint-capability "process" :realpath #'identity)
              (compose-capabilities
               (list (make-cap-none)
                     (mint-capability "process" :realpath #'identity)))
              (restrict-capability
               (mint-capability "fs:/g:rw" :realpath #'identity)
               (canonicalize-path "/g" :realpath #'identity)
               :mode :read)))
           (failures nil)
           (print-checks 0)
           (print-skips 0)
           (cap-checks 0))
      (labels ((fail (property detail)
                 (push (list property detail) failures))
               (check-injective (name items hash-function)
                 (let ((seen (make-hash-table :test #'equal)))
                   (dolist (item items)
                     (let ((hash (funcall hash-function item)))
                       (when (gethash hash seen)
                         (fail name (format nil "hash collision: ~A" hash)))
                       (setf (gethash hash seen) t)))))
               (check-print (form)
                 (handler-case
                     (let* ((text (print-source (list form)
                                                :surface :sexpr
                                                :source "kernel-props"))
                            (round (read-source text
                                                :source "kernel-props"
                                                :surface :sexpr)))
                       (incf print-checks)
                       (unless (and (= (length round) 1)
                                    (string= (hash-expr
                                              (%language-form-inner form))
                                             (hash-expr
                                              (%language-form-inner
                                               (first round)))))
                         (fail "print-rt" "printed form changed its hash")))
                   (frontend-error ()
                     (incf print-skips))
                   (error (condition)
                     (incf print-skips)
                     (fail "print-rt" (princ-to-string condition))))))
        (check-injective "expr" expressions #'hash-expr)
        (check-injective "pattern" patterns #'hash-pattern)
        (check-injective "value" values #'hash-value)
        (dotimes (index count)
          (let ((form (%property-expr
                       "literal-int" (format nil "~D" (+ seed index)))))
            (handler-case
                (check-injective "expr-sweep"
                                 (list form) #'hash-expr)
              (error (condition)
                (fail "expr-sweep" (princ-to-string condition)))))
          (let ((value (make-vint (+ seed index))))
            (handler-case
                (unless (string= (hash-value value)
                                 (hash-value (runtime-quote-to-value
                                              (runtime-value-to-expr value))))
                  (fail "quote-rt" "integer quote round-trip changed its hash"))
              (error (condition)
                (fail "quote-rt" (princ-to-string condition)))))
          (check-print
           (nth (mod index (length printable-expressions))
                printable-expressions)))
        (dolist (value (subseq values 0 8))
          (handler-case
              (unless (string= (hash-value value)
                               (hash-value
                                (runtime-quote-to-value
                                 (runtime-value-to-expr value))))
                (fail "quote-rt" "value quote round-trip changed its hash"))
            (error (condition)
              (fail "quote-rt" (princ-to-string condition)))))
        (dolist (cap caps)
          (unless (member (cap-kind cap) (all-cap-tags))
            (fail "cap-kind"
                  (format nil "unclassified capability: ~A"
                          (capability-to-string cap))))
          (unless (capability-subseteq-p cap (list cap))
            (fail "cap-subseteq" "a capability was not a subset of itself"))
          (unless (null (encode-value (make-vcapability cap)))
            (fail "node-boundary" "capability encoded as durable data"))
          (incf cap-checks (length (cap-probe-vector cap))))
        (dotimes (index (max 0 (1- count)))
          (declare (ignore index))
          (dolist (cap caps)
            (unless (capability-subseteq-p cap (list cap))
              (fail "cap-subseteq" "repeated subset check failed"))
            (incf cap-checks (length (cap-probe-vector cap)))))
        (format output
                "kernel-props: seed=~D count=~D | adv:e=~D v=~D p=~D faith:e=~D | forms=28/28 value-kinds=11/11 pattern-kinds=5/5 cap-kinds=7/7 | print-rt: ~D checked, ~D printer-refused | cap-checks: ~D~%"
                seed count (+ 28 count) (+ 11 count) (+ 5 count)
                count print-checks print-skips cap-checks)
        (if failures
            (progn
              (format output "kernel-props: ~D FAILURE~:P~%"
                      (length failures))
              (dolist (failure (remove-duplicates failures :test #'equal))
                (format output "  [~A] ~A~%" (first failure) (second failure)))
              (finish-output output)
              1)
            (progn
              (format output
                      "kernel-props: OK — injectivity, quote-rt, print-rt, caps all hold~%")
              (finish-output output)
              0))))))

(defun %usage (stream)
  (format stream
          "pp v~A~%Usage: pp --version | pp --help | pp -e EXPR | pp [--once] FILE.pp|FILE.ppl | pp fmt --to-braces FILE [-i]~%~%"
          +version+)
  (format stream
          "Language commands:~%  pp -e '<brace expression>'~%  pp [--once] <file.pp|file.ppl>~%  pp run <file.pp|file.ppl>~%  pp (stdin/REPL reads brace forms)~%~%")
  (format stream
          "Frontend commands:~%  pp fmt --to-braces <file.ppl> [-i]~%  pp fmt --to-sexpr <file.pp> [-i]~%  pp --emit-braces <file.ppl>~%  pp --roundtrip-braces <file.ppl>~%  pp --compare-hash <file1.pp> <file2.pp>~%  pp --list-comments sexpr|brace <file>~%  pp lint <file.pp>~%  pp --dump-surface-tables~%~%")
  (format stream
          "Admin and verification commands:~%  pp --dump-builtins~%  pp --check-kernel-props [--seed N] [--count N]~%  pp cluster-init~%  pp --mint-token OUT TTL-SECS [--grant SPEC]~%  pp --transport-push|--transport-pull KIND HASH ROOT~%  pp --serve-hit KEY TOKEN-FILE SHARED-ROOT REPLY-FILE~%  pp --recv-hit REPLY-FILE SHARED-ROOT~%~%")
)


(defun %run-frontend-command (arguments output error-output)
  (let ((command (first arguments))
        (rest (rest arguments)))
    (cond
      ((string= command "fmt")
       (%run-fmt rest output))
      ((string= command "--emit-braces")
       (unless (= (length rest) 1)
         (error "--emit-braces requires exactly one source file"))
       (%run-emit-braces (first rest) output)
       0)
      ((string= command "--roundtrip-braces")
       (unless (= (length rest) 1)
         (error "--roundtrip-braces requires exactly one source file"))
       (%run-roundtrip-braces (first rest) output error-output))
      ((string= command "--compare-hash")
       (unless (= (length rest) 2)
         (error "--compare-hash requires exactly two source files"))
       (%run-compare-hash (first rest) (second rest)))
      ((string= command "--list-comments")
       (unless (= (length rest) 2)
         (error "--list-comments requires SURFACE and FILE"))
       (let ((surface (cond ((string= (first rest) "sexpr") :sexpr)
                            ((string= (first rest) "brace") :brace)
                            (t (error "--list-comments requires sexpr|brace <file>")))))
         (%run-list-comments surface (second rest) output)))
      ((string= command "lint")
       (unless (= (length rest) 1)
         (error "lint requires exactly one source file"))
       (%run-lint (first rest) output error-output))
      (t nil))))

(defun run (&optional (arguments (cdr sb-ext:*posix-argv*))
                      (input *standard-input*)
                      (output *standard-output*)
                      (error-output *error-output*))
  (multiple-value-bind (command-arguments program-arguments)
      (%command-split-program-arguments arguments)
    (let ((arguments command-arguments)
          (*command-program-arguments* program-arguments))
      (labels ((language-error (condition)
                 (format error-output "pp: error: ~A~%"
                         (%language-error-text condition))
                 (finish-output error-output)
                 1)
               (frontend-error (condition)
                 (let* ((source (find-if #'%language-source-path-p arguments))
                        (*language-source-context*
                          (or source *language-source-context*))
                        (raw (frontend-error-message condition))
                        (message
                          (%frontend-removed-surface-message
                           raw
                           (and source
                                (handler-case
                                    (%read-source-file source)
                                  (error () nil))))))
                   (format error-output "pp: error: ~A~%"
                           (if (string= message raw)
                               (%frontend-error-text condition)
                               message))
                   (finish-output error-output))
                 1)
           (host-error (condition)
             ;; Keep ordinary host failures unchanged, but apply the same
             ;; typed-force normalization to non-REPL commands that escape
             ;; before the evaluator can wrap the condition.
             (format error-output "pp: error: ~A~%"
                     (if (typep condition 'type-error)
                         (%language-error-text condition)
                         condition))
             (finish-output error-output)
             1)
           (run-language (thunk)
             (catch 'pp-command-exit
               (handler-case
                 (funcall thunk)
               (pp.runtime:language-exit (condition)
                 (pp.runtime:language-exit-status condition))
               (language-error (condition) (language-error condition))
               (error (condition) (host-error condition))))))
    (or (when arguments
          (let ((status (run-language
                         (lambda ()
                           (%validate-command-modes arguments)
                           0))))
            (and (/= status 0) status)))
    (cond
      ((null arguments)
       (run-language
        (lambda ()
          (%run-language-stdin input output :error-output error-output))))
      ((or (string= (first arguments) "--version")
           (string= (first arguments) "-v"))
       (if (null (rest arguments))
           (progn
             (format output "pp v~A~%" +version+)
             (finish-output output)
             0)
           (progn
             (format error-output
                     "pp: error: --version does not accept arguments~%")
             (finish-output error-output)
             1)))
      ((string= (first arguments) "--dump-builtins")
       (if (null (rest arguments))
           (handler-case
               (%dump-builtins output)
             (error (condition) (host-error condition)))
           (progn
             (format error-output
                     "pp: error: --dump-builtins does not accept arguments~%")
             (finish-output error-output)
             1)))
      ((string= (first arguments) "--check-kernel-props")
       (handler-case
           (%run-kernel-props arguments output)
         (error (condition) (host-error condition))))
      ((string= (first arguments) "--update")
       (run-language
        (lambda ()
          (let ((pp.runtime:*island-fetch-enabled* t)
                (pp.runtime:*island-update-mode* t))
            (%run-island-update (rest arguments) output error-output)))))
      ((string= (first arguments) "island-pins")
       (run-language
        (lambda ()
          (%run-island-pins (rest arguments) output error-output))))
      ((member "--fetch-islands" arguments :test #'string=)
       (run-language
        (lambda ()
          (let ((pp.runtime:*island-fetch-enabled* t))
            (multiple-value-bind (operands grants why no-cache check
                                  ignored-keep ignored-grace)
                (%parse-command-options arguments)
              (declare (ignore ignored-keep ignored-grace))
              (%run-language-files
               operands output :grant-specs grants :why why
               :no-cache no-cache :check check :error-output error-output))))))
      ((string= (first arguments) "cluster-init")
       (handler-case
           (%run-cluster-init-command arguments output)
         (error (condition) (host-error condition))))
      ((string= (first arguments) "--mint-token")
       (handler-case
           (%run-mint-token-command arguments)
         (error (condition) (host-error condition))))
      ((member "--mint-token" arguments :test #'string=)
       (handler-case
           (let ((at (cl:position "--mint-token" arguments :test #'string=)))
             (%run-mint-token-command
              (append (nthcdr at arguments)
                      (subseq arguments 0 at))))
         (error (condition) (host-error condition))))
      ((string= (first arguments) "--serve-hit")
       (handler-case
           (%command-serve-hit-command arguments output)
         (error (condition) (host-error condition))))
      ((string= (first arguments) "--recv-hit")
       (handler-case
           (%run-recv-hit-command arguments output)
         (error (condition) (host-error condition))))
      ((member (first arguments)
               '("--transport-push" "--transport-pull")
               :test #'string=)
       (handler-case
           (%run-transport-command
            (if (string= (first arguments) "--transport-push") :push :pull)
            arguments output)
         (error (condition) (host-error condition))))
      ((member "--reconcile" arguments :test #'string=)
       (run-language
        (lambda ()
          (%run-reconcile-command
           (remove "--reconcile" arguments :test #'string= :count 1)
           output error-output))))
      ((and (member "--grant" arguments :test #'string=)
            (not (member "-e" arguments :test #'string=))
            (not (some #'%language-source-path-p arguments)))
       (run-language
        (lambda ()
          (multiple-value-bind
                (operands grants why no-cache check ignored-keep ignored-grace)
              (%parse-command-options arguments)
            (declare (ignore ignored-keep ignored-grace))
            (if operands
                (%run-language-files
                 operands output :grant-specs grants :why why
                 :no-cache no-cache :check check :error-output error-output)
                (%run-language-stdin
                 input output :grant-specs grants :why why
                 :no-cache no-cache :check check :error-output error-output))))))
      ((or (member "--watch" arguments :test #'string=)
           (member "--stabilize" arguments :test #'string=)
           (member "--schedule" arguments :test #'string=)
           (member "--supervise" arguments :test #'string=)
           (member "--once" arguments :test #'string=)
           (member "--publish-object" arguments :test #'string=)
           (member "--pin-file" arguments :test #'string=)
           (member "--dump-pins" arguments :test #'string=)
           (member "run" arguments :test #'string=))
       (run-language
        (lambda ()
          (%run-runtime-command arguments output error-output))))
      ((or (string= (first arguments) "--help")
           (string= (first arguments) "-h"))
       (if (null (rest arguments))
           (progn
             (%usage output)
             (finish-output output)
             0)
           (progn
             (format error-output
                     "pp: error: --help does not accept arguments~%")
             (%usage error-output)
             (finish-output error-output)
             1)))
      ((member "-e" arguments :test #'string=)
       (run-language
        (lambda ()
          (%run-expression-command arguments output error-output))))
      ((string= (first arguments) "--reconcile")
       (run-language
        (lambda () (%run-reconcile-command (rest arguments) output error-output))))
      ((string= (first arguments) "graph")
       (run-language
        (lambda () (%run-graph-command arguments output error-output))))
      ((or (member (first arguments)
                   '("why" "--why" "gc" "--grant" "--no-cache" "--check")
                   :test #'string=)
           (%gc-option-p (first arguments)))
       (run-language
        (lambda ()
          (cond
            ((or (string= (first arguments) "gc")
                 (%gc-option-p (first arguments)))
             (%run-gc-command
              (if (string= (first arguments) "gc")
                  (rest arguments)
                  arguments)
              output))
            ((or (string= (first arguments) "why")
                 (string= (first arguments) "--why"))
             (%run-why-command (rest arguments) output error-output))
            ((member "graph" arguments :test #'string=)
             (%run-graph-command arguments output error-output))
            ((member "--member-name" arguments :test #'string=)
             (%run-runtime-command arguments output error-output))
            (t
             (multiple-value-bind
                   (operands grants why no-cache check ignored-keep ignored-grace)
                 (%parse-command-options arguments)
               (declare (ignore ignored-keep ignored-grace))
               (%run-language-files
                operands output :grant-specs grants :why why
                :no-cache no-cache :check check
                :error-output error-output)))))))
      ((string= (first arguments) "--once")
       (run-language
        (lambda ()
          (multiple-value-bind (operands grants why no-cache check ignored-keep ignored-grace)
              (%parse-command-options (rest arguments))
            (declare (ignore ignored-keep ignored-grace))
            (unless (= (length operands) 1)
              (error "--once requires exactly one source file"))
            (%run-language-files
             operands output :grant-specs grants :why why
             :no-cache no-cache :check check :error-output error-output)))))
      ((member (first arguments)
               '("fmt" "--emit-braces" "--roundtrip-braces"
                 "--compare-hash" "--list-comments" "lint")
               :test #'string=)
       (handler-case
           (%run-frontend-command arguments output error-output)
         (frontend-error (condition) (frontend-error condition))
         (error (condition) (host-error condition))))
      ((string= (first arguments) "--dump-surface-tables")
       (if (null (rest arguments))
           (%dump-surface-tables output)
           (progn
             (format error-output
                     "pp: error: --dump-surface-tables does not accept arguments~%")
             (%usage error-output)
             (finish-output error-output)
             1)))
      ((string= (first arguments) "run")
       (run-language
        (lambda ()
          (multiple-value-bind (operands grants why no-cache check ignored-keep ignored-grace)
              (%parse-command-options (rest arguments))
            (declare (ignore ignored-keep ignored-grace))
            (%run-language-files
             operands output :grant-specs grants :why why
             :no-cache no-cache :check check :error-output error-output)))))
      ((%language-source-path-p (first arguments))
       (run-language
        (lambda ()
          (multiple-value-bind (operands grants why no-cache check ignored-keep ignored-grace)
              (%parse-command-options arguments)
            (declare (ignore ignored-keep ignored-grace))
            (%run-language-files
             operands output :grant-specs grants :why why
             :no-cache no-cache :check check :error-output error-output)))))
      ((and (first arguments)
            (char= (char (first arguments) 0) #\-))
       (format error-output "pp: error: unrecognized option: ~A~%"
               (first arguments))
       (finish-output error-output)
       1)
      ((%runtime-flag-p (first arguments))
       (format error-output
               "pp: error: ~A is unavailable: effect/distribution runtime services are not installed~%"
               (first arguments))
       (finish-output error-output)
       2)
      (t
       (format error-output
               "pp: error: unsupported command or source input: ~A~%"
               (first arguments))
       (%usage error-output)
       (finish-output error-output)
       2))))))
  ;; SAVE-LISP-AND-DIE invokes this function in the resulting executable.
  )

(defun main ()
  ;; Keeping EXIT here (rather than in RUN) makes isolated checks composable.
  (sb-ext:exit :code (run)))
