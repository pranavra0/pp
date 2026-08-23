;;;; Observation cells, trace validation, and authority checks.
(in-package #:pp.runtime)

(defun runtime-observation-error (message &optional (code "runtime.observation"))
  (if (fboundp 'language-fail) (language-fail message code) (error "~A" message)))

(defun runtime-observation-session () (runtime-dynamic-session nil))
(defun runtime-observation-service (name)
  (let ((scope (runtime-dynamic-current nil)))
    (or (and scope (runtime-dynamic-find-service name))
        (and scope (runtime-session-find-service (runtime-dynamic-scope-session scope) name)))))
(defun runtime-observation-call (name &rest args)
  (let ((fn (runtime-observation-service name)))
    (and fn (apply fn args))))
(defun runtime-observation-text (value)
  (cond ((stringp value) value)
        ((typep value 'value-string) (value-string-value value))
        ((typep value 'value-symbol) (value-symbol-value value))
        ((typep value 'value-keyword) (value-keyword-value value))
        (t nil)))
(defun runtime-observation-raw-octets (value)
  (let ((value (if (typep value 'value-sealed)
                   (value-sealed-bytes value)
                   value)))
    (cond
      ((stringp value)
       (let ((bytes (make-array (length value) :element-type '(unsigned-byte 8))))
         (loop for char across value
               for i from 0
               for code = (char-code char)
               do (unless (<= code 255)
                    (runtime-observation-error "sealed bytes contain a non-octet character"
                                               "runtime.observation"))
                  (setf (aref bytes i) code))
         bytes))
      ((vectorp value)
       (let ((bytes (make-array (length value) :element-type '(unsigned-byte 8))))
         (loop for item across value
               for i from 0
               do (unless (and (integerp item) (<= 0 item 255))
                    (runtime-observation-error "sealed bytes must be octets"
                                               "runtime.observation"))
                  (setf (aref bytes i) item))
         bytes))
      (t (runtime-observation-error "sealed observation did not return raw bytes"
                                    "runtime.observation")))))
(defun runtime-observation-sealed-hash (value)
  ;; A sealed pin is either its raw bytes or an already sealed digest.
  (if (and (stringp value) (store-digest-p value))
      value
      (store-hash-octets (runtime-observation-raw-octets value))))
(defun runtime-observation-canonical-cell (cell)
  (check-type cell cell)
  (typecase cell
    ((or cell-file cell-runtime-file cell-tree cell-stat cell-sealed)
     (make-cell :kind (cell-kind cell) :data (store-canonical-path (cell-data cell))))
    (cell-config (make-cell-config (or (runtime-observation-text (cell-config-value cell))
                                       (runtime-observation-error
                                        "configuration cell key must be text"))))
    ((or cell-handler cell-probe cell-node)
     (make-cell :kind (cell-kind cell)
                :data (store-identity-string (cell-data cell))))
    (cell-domain (make-cell-domain (cell-domain-name cell) (cell-domain-sub cell)))
    (t cell)))
(defun runtime-observation-cell-id (cell)
  (cell-serialize (runtime-observation-canonical-cell cell)))

(defun runtime-observe-file (path &optional sealed)
  (let* ((canonical (store-canonical-path path))
         (session (runtime-observation-session))
         (cell (runtime-observation-cell-id
                (if sealed (make-cell-sealed canonical) (make-cell-file canonical))))
         (pin (and session (if sealed (runtime-session-find-sealed-pin session cell)
                                  (runtime-session-find-run-pin session cell))))
         (service (runtime-observation-service (if sealed :observe-sealed :observe-file))))
    (or (and pin
             (if sealed
                 (let ((bytes (or (runtime-observation-call :sealed-bytes pin)
                                  ;; Sealed pins are raw bytes when no adapter
                                  ;; service is installed.
                                  (unless (and (stringp pin)
                                               (store-digest-p pin))
                                    pin))))
                   (if bytes (runtime-observation-sealed-hash bytes)
                       (store-identity-string pin)))
                 (store-identity-string pin)))
        (and service
             (let ((observed (funcall service canonical)))
               (if sealed
                   (runtime-observation-sealed-hash observed)
                   (store-identity-string observed))))
        (let ((bytes (handler-case
                         (store-read-octets canonical)
                       (error () nil))))
          (and bytes
               (if sealed
                   (store-hash-octets bytes)
                   (store-hash-content bytes)))))))

(defun runtime-observe-tree (path)
  (let ((canonical (store-canonical-path path)))
    (or (runtime-observation-call :observe-tree canonical)
        (runtime-observation-call :tree-hash canonical))))
(defun runtime-observe-stat (path)
  (let ((canonical (store-canonical-path path)))
    (or (runtime-observation-call :observe-stat canonical)
        (runtime-observation-call :stat-hash canonical))))
(defun runtime-observe-env (name)
  (let* ((name (or (runtime-observation-text name)
                   (runtime-observation-error "environment name must be text")))
         (service (runtime-observation-service :observe-env)))
    (when service
      (let ((value (funcall service name)))
        (if value
            (hash-concat (list "env-present" value))
            (hash-concat (list "env-absent")))))))
(defun runtime-observe-argv ()
  (or (runtime-observation-call :observe-argv)
      (let ((inv (runtime-dynamic-invocation nil)))
        (and inv (runtime-observation-call :invocation-argv inv)))))

(defun runtime-observation-probe (name)
  (let ((session (runtime-observation-session)))
    (when session
      (let ((old (runtime-session-find-probe session name)))
        (if old (hash-value old)
            (let ((domain (runtime-session-find-domain session name)))
              (when domain
                (let ((observe (runtime-domain-entry-observe domain))
                      (cap (runtime-domain-entry-cap domain)))
                  (when observe
                    (let ((run (lambda ()
                                 (if (functionp observe) (funcall observe)
                                     (runtime-session-call session observe nil (runtime-session-global-env session))))))
                      (let ((value (if (runtime-dynamic-current nil)
                                       (runtime-dynamic-without-observations run)
                                       (funcall run))))
                        (runtime-session-set-probe session name value)
                        (hash-value value))))))))))))

(defun runtime-observe-domain (name sub)
  (let* ((session (runtime-observation-session))
         (domain (and session (runtime-session-find-domain session name))))
    (when (and domain (runtime-domain-entry-observe-cell domain))
      (let* ((fn (runtime-domain-entry-observe-cell domain))
             (value (if (functionp fn) (funcall fn sub)
                        (runtime-session-call session fn (list (make-vstring sub))
                                               (runtime-session-global-env session)))))
        (cond ((typep value 'value-nil) nil)
              ((typep value 'value-string) (value-string-value value))
              (t (hash-value value)))))))

(defun runtime-observe-node-trace (key &optional (seen nil))
  (let* ((name (store-identity-string key))
         (session (runtime-observation-session))
         (traces (runtime-observation-repository :store-traces)))
    (when (and session traces (not (member name seen :test #'string=)))
      (dolist (trace (trace-repository-load traces :key name))
        (when (and (store-trace-outcome-ok-p (store-trace-outcome trace))
                   (every (lambda (read)
                            (let ((current
                                    (runtime-observe-cell
                                     (cell-parse
                                      (store-identity-string
                                       (store-trace-read-cell read)))
                                     (cons name seen))))
                              (and current
                                   (string=
                                    (store-identity-string current)
                                    (store-identity-string
                                     (store-trace-read-hash read))))))
                          (store-trace-reads trace)))
          (return (store-identity-string (store-trace-result-hash trace))))))))
(defun runtime-observe-cell (cell &optional (seen nil))
  (check-type cell cell)
  (let* ((cell (runtime-observation-canonical-cell cell))
         (value
           (typecase cell
             (cell-file (runtime-observe-file (cell-file-value cell)))
             (cell-runtime-file (runtime-observe-file (cell-runtime-file-value cell)))
             (cell-sealed (runtime-observe-file (cell-sealed-value cell) t))
             (cell-tree (runtime-observe-tree (cell-tree-value cell)))
             (cell-stat (runtime-observe-stat (cell-stat-value cell)))
             (cell-env (runtime-observe-env (cell-env-value cell)))
             (cell-argv (runtime-observe-argv))
             (cell-config
              (multiple-value-bind (v p)
                  (runtime-configuration-lookup (cell-config-value cell))
                (if p (hash-value v) "config-cell:absent")))
             (cell-handler (runtime-dynamic-observe-handler (cell-handler-value cell)))
             (cell-probe (runtime-observation-probe (cell-probe-value cell)))
             (cell-node (runtime-observe-node-trace (cell-node-value cell) seen))
             (cell-domain (runtime-observe-domain (cell-domain-name cell)
                                                  (cell-domain-sub cell)))
             (cell-tool (runtime-observation-call :observe-tool
                                                  (cell-tool-value cell)))
             (cell-unknown nil))))
    (and value (if (stringp value) value (store-identity-string value)))))
(defun runtime-observe (cell) (runtime-observe-cell cell))
(defun runtime-observe-id (id)
  (runtime-observe-cell (cell-parse (store-identity-string id))))
(defun runtime-observation-record (cell hash)
  (let ((cell (runtime-observation-canonical-cell cell)))
    ;; The command boundary historically supplied an unframed env hash.
    ;; Record the same presence-framed value that validation observes.
    (let ((hash (if (typep cell 'cell-env)
                    (or (runtime-observe-env (cell-env-value cell))
                        (store-identity-string hash))
                    hash)))
      (runtime-dynamic-record-read
       (cell-serialize cell)
       (store-identity-string hash)))))
(defun runtime-observation-record-config (key)
  (runtime-observation-record
   (make-cell-config key)
   (or (runtime-observe-cell (make-cell-config key)) "config-cell:absent")))
(defun runtime-observation-record-handler (name)
  (runtime-observation-record
   (make-cell-handler name)
   (or (runtime-observe-cell (make-cell-handler name)) "handler-cell:builtin")))
(defun runtime-observation-replay (reads)
  (dolist (read reads)
    (runtime-observation-record
     (cell-parse (store-identity-string (store-trace-read-cell read)))
     (store-trace-read-hash read))))

(defun runtime-observation-authorized-p (capabilities cell &optional (seen nil))
  (handler-case
      (let ((cell (runtime-observation-canonical-cell cell)))
        (labels ((fs (path)
                   (some (lambda (cap)
                           (capability-check-fs-read-p
                            cap (canonicalize-path path :realpath (lambda (x) x))))
                         capabilities))
                 (secret (path)
                   (some (lambda (cap)
                           (capability-check-secret-p
                            cap (canonicalize-path path :realpath (lambda (x) x))))
                         capabilities)))
          (typecase cell
            ((or cell-file cell-tree cell-stat) (fs (cell-data cell)))
            (cell-sealed (secret (cell-sealed-value cell)))
            (cell-tool (some #'capability-check-process-p capabilities))
            (cell-domain
             (let* ((session (runtime-observation-session))
                    (domain (and session
                                 (runtime-session-find-domain
                                  session (cell-domain-name cell)))))
               (and domain
                    (capability-subseteq
                     (runtime-domain-entry-cap domain) capabilities))))
            (cell-node
             (let* ((name (store-identity-string (cell-node-value cell)))
                    (traces (runtime-observation-repository :store-traces))
                    (loaded (and traces
                                 (trace-repository-load traces :key name))))
               (and (plusp (length loaded))
                    (not (member name seen :test #'string=))
                    (let ((seen (cons name seen)))
                      (every
                       (lambda (trace)
                         (and (or (store-trace-outcome-ok-p
                                   (store-trace-outcome trace))
                                  (store-trace-outcome-failed-p
                                   (store-trace-outcome trace)))
                              (every
                               (lambda (read)
                                 (runtime-observation-authorized-p
                                  capabilities
                                  (cell-parse
                                   (store-identity-string
                                    (store-trace-read-cell read)))
                                  seen))
                               (store-trace-reads trace)))
                       )
                       loaded)))))
            ((or cell-runtime-file cell-env cell-argv cell-config
                 cell-handler cell-probe) t)
            (t nil))))
    (error () nil)))
(defun runtime-authorized-p (capabilities cell) (runtime-observation-authorized-p capabilities cell))
(defun observation-observe (cell) (runtime-observe-cell cell))
(defun observation-observe-id (id) (runtime-observe-id id))
(defun observation-record (cell hash) (runtime-observation-record cell hash))
(defun observation-replay (reads) (runtime-observation-replay reads))
(defun observation-authorized-p (caps cell) (runtime-observation-authorized-p caps cell))
(defun runtime-observation-repository (name)
  (let ((service (runtime-observation-service name)))
    (and service (if (functionp service) (funcall service) service))))
