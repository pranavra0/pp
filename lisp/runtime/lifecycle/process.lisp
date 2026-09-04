;;;; Process-domain primitives and process-isolation records.
(in-package #:pp.rt.lifecycle.process)

(defstruct (runtime-process-record
            (:constructor make-runtime-process-record
                (&key name spec-hash spec pid argv cwd environment status
                      output-path error-path)))
  name spec-hash spec pid argv cwd environment status output-path error-path)

(defun runtime-process-capability-p (&optional (capabilities nil capabilities-p))
  (let* ((scope (and (fboundp 'runtime-dynamic-current)
                     (runtime-dynamic-current nil)))
         (caps (if capabilities-p capabilities
                   (and scope (runtime-dynamic-capabilities)))))
    (some (lambda (cap)
            (and (fboundp 'capability-check-process-p)
                 (capability-check-process-p cap))) caps)))

(defun runtime-process-require-capability ()
  (unless (runtime-process-capability-p)
    (if (fboundp 'pp.rt.effects:runtime-effects-error)
        (pp.rt.effects:runtime-effects-error "capability error: no process authority"
                               "runtime.capability")
        (error "capability error: no process authority")))
  t)

(defun runtime-process-split-path (path)
  (let ((parts nil) (start 0))
    (loop for at = (cl:position #\: path :start start)
          do (if at
                 (progn (unless (= at start) (push (subseq path start at) parts))
                        (setf start (1+ at)))
                 (progn (unless (= start (length path)) (push (subseq path start) parts))
                        (return (nreverse parts)))))))

(defun runtime-process-resolve-command (command)
  (unless (and (stringp command) (plusp (length command)))
    (error "process command must be a nonempty string"))
  (if (find #\/ command)
      (and (probe-file command) command)
      (let ((path #+sbcl (or (sb-ext:posix-getenv "PATH") "") #-sbcl ""))
        (loop for directory in (runtime-process-split-path path)
              for candidate = (merge-pathnames command
                                               (pathname (format nil "~A/" directory)))
              when (probe-file candidate)
                do (return (namestring (truename candidate)))))))
(defun runtime-process-read-file (path)
  (if (probe-file path)
      (with-open-file (stream path :direction :input :element-type 'character)
        (let ((text (make-string (file-length stream))))
          (read-sequence text stream) text))
      ""))

(defun runtime-process-exec (argv &key environment cwd)
  (unless (and (consp argv) (every #'stringp argv))
    (error "process execution expects a nonempty argv"))
  (let ((program (runtime-process-resolve-command (first argv)))
        (session (runtime-dynamic-session nil)))
    (unless program (error "process command not found: ~A" (first argv)))
    (when session
      (runtime-journal-append session
                              (make-runtime-journal-exec (cons program (rest argv)))))
    #+sbcl
    (let* ((tmpdir (or (and (sb-ext:posix-getenv "TMPDIR")
                            (plusp (length (sb-ext:posix-getenv "TMPDIR")))
                            (sb-ext:posix-getenv "TMPDIR"))
                       "/tmp"))
           (out (store-exclusive-temp-name tmpdir "pp-run-" ".out"))
           (err (store-exclusive-temp-name tmpdir "pp-run-" ".err"))
           (process nil))
      ;; The exclusive reservation prevents collisions; run-program must
      ;; recreate the paths because its pathname output mode rejects existing
      ;; files.
      (sb-posix:unlink out)
      (sb-posix:unlink err)
      (unwind-protect
           (progn
             (setf process
                   (sb-ext:run-program program (rest argv)
                                       :search nil :wait t :input "/dev/null"
                                       :output out :error err :directory cwd
                                       :environment
                                       (and environment
                                            (mapcar (lambda (pair)
                                                      (format nil "~A=~A"
                                                              (car pair) (cdr pair)))
                                                    environment))))
             (values (or (sb-ext:process-exit-code process) 128)
                     (runtime-process-read-file out)
                     (runtime-process-read-file err)))
        (ignore-errors (delete-file out))
        (ignore-errors (delete-file err))))
    #-sbcl (error "process execution provider is unavailable on this Lisp")))

(defun runtime-process-spec-hash (spec)
  (let ((hash (and (fboundp 'hash-value)
                   (handler-case (hash-value spec) (error () nil)))))
    (cond (hash hash)
          ((stringp spec) (pp.kernel:hash-string spec))
          (t (error "process specification is not canonical data")))))

(defun runtime-process-require-durable-spec (spec)
  (unless (pp.kernel:durable-value-p spec)
    (pp.rt.effects:runtime-effects-error
     "process specification is not durable" "runtime.authority"))
  spec)

(defun runtime-process-spec-field (spec name)
  (when (typep spec 'pp.kernel:value-map)
    (let ((entry (find-if
                  (lambda (item)
                    (let ((key (car item)))
                      (and (or (typep key 'pp.kernel:value-string)
                               (typep key 'pp.kernel:value-keyword))
                           (string= name
                                    (if (typep key 'pp.kernel:value-string)
                                        (value-string-value key)
                                        (value-keyword-value key))))))
                  (value-map-entries spec))))
      (and entry (cdr entry)))))

(defun %runtime-process-force (value)
  (let ((session (and (fboundp 'runtime-dynamic-session)
                      (runtime-dynamic-session nil))))
    (if session (runtime-domain-force session value) value)))

(defun runtime-process-text (value field)
  (let ((value (%runtime-process-force value)))
    (cond ((typep value 'pp.kernel:value-string) (value-string-value value))
          ((typep value 'pp.kernel:value-keyword) (value-keyword-value value))
          ((typep value 'pp.kernel:value-symbol) (value-symbol-value value))
          (t (error "process ~A must be a string" field)))))

(defun runtime-process-string-list (value field)
  (let ((value (and value (%runtime-process-force value))))
    (cond
      ((or (null value) (typep value 'pp.kernel:value-nil)) nil)
      ((typep value 'pp.kernel:value-vector)
       (map 'list (lambda (item) (runtime-process-text item field))
            (value-vector-values value)))
      ((typep value 'pp.kernel:value-pair)
       (labels ((collect (item)
                  (let ((item (%runtime-process-force item)))
                    (cond ((typep item 'pp.kernel:value-nil) nil)
                          ((typep item 'pp.kernel:value-pair)
                           (cons (runtime-process-text
                                  (value-pair-car item) field)
                                 (collect (value-pair-cdr item))))
                          (t (error "process ~A must be a list or vector of strings"
                                    field))))))
         (collect value)))
      (t (error "process ~A must be a list or vector of strings" field)))))

(defun runtime-process-environment (spec)
  (let* ((value (runtime-process-spec-field spec "env"))
         (overrides
           (if (or (null value) (typep value 'pp.kernel:value-nil))
               nil
               (let ((value (%runtime-process-force value)))
                 (unless (typep value 'pp.kernel:value-map)
                   (error "process env must be a map"))
                 (mapcar (lambda (entry)
                           (cons (runtime-process-text (car entry) "env key")
                                 (runtime-process-text (cdr entry) "env value")))
                         (value-map-entries value))))))
    #+sbcl
    (let ((environment (copy-list (sb-ext:posix-environ))))
      (dolist (override overrides)
        (let ((prefix (concatenate 'string (car override) "=")))
          (setf environment
                (remove-if (lambda (item)
                            (and (stringp item)
                                 (>= (length item) (length prefix))
                                 (string= prefix item :end2 (length prefix))))
                          environment)))
        (push (format nil "~A=~A" (car override) (cdr override))
              environment))
      environment)
    #-sbcl overrides))

(defun runtime-process-cwd (spec)
  (let ((value (runtime-process-spec-field spec "cwd")))
    (if (or (null value) (typep value 'pp.kernel:value-nil))
        nil
        (runtime-process-text value "cwd"))))

(defun runtime-process-argv (spec)
  (cond
    ((typep spec 'pp.kernel:value-map)
     (let ((command (runtime-process-spec-field spec "cmd")))
       (unless command (error "process specification has no cmd"))
       (cons (runtime-process-text command "cmd")
             (runtime-process-string-list
              (runtime-process-spec-field spec "args") "args"))))
    ((and (listp spec) (every #'stringp spec)) (copy-list spec))
    (t (error "process specification is not an argv"))))

(defun %runtime-process-state-field (value name)
  (and (typep value 'pp.kernel:value-map)
       (let ((entry
               (find-if
                (lambda (item)
                  (let ((key (car item)))
                    (and (or (typep key 'pp.kernel:value-keyword)
                             (typep key 'pp.kernel:value-string))
                         (string= name
                                  (if (typep key 'pp.kernel:value-keyword)
                                      (value-keyword-value key)
                                      (value-string-value key))))))
                (value-map-entries value))))
         (and entry (cdr entry)))))

(defun %runtime-process-state-name (value)
  (typecase value
    (pp.kernel:value-string (value-string-value value))
    (pp.kernel:value-keyword (value-keyword-value value))
    (pp.kernel:value-symbol (value-symbol-value value))
    (t (error "known service name is not a string"))))

(defun %runtime-process-state-names (value)
  (cond
    ((or (null value) (typep value 'pp.kernel:value-nil)) nil)
    ((typep value 'pp.kernel:value-vector)
     (map 'list #'%runtime-process-state-name
          (value-vector-values value)))
    ((typep value 'pp.kernel:value-pair)
     (labels ((collect (item)
                (cond
                  ((typep item 'pp.kernel:value-nil) nil)
                  ((typep item 'pp.kernel:value-pair)
                   (cons (%runtime-process-state-name
                          (value-pair-car item))
                         (collect (value-pair-cdr item))))
                  (t (error "process known-services state is not a list")))))
       (collect value)))
    (t (error "process known-services state is not a list or vector"))))
(defun %runtime-process-record-from-state (session name value)
  (let* ((pid (%runtime-process-state-field value "pid"))
         (spec (%runtime-process-state-field value "spec")))
    (unless (and (typep pid 'pp.kernel:value-int)
                 (plusp (value-int-value pid))
                 spec)
      (error "process record for ~A is corrupt" name))
    (let* ((pid (value-int-value pid))
           (hash (runtime-process-spec-hash spec))
           (argv (runtime-process-argv spec))
           (cwd (runtime-process-cwd spec))
           (environment (runtime-process-environment spec)))
      (make-runtime-process-record
       :name name :spec-hash hash :spec spec :pid pid :argv argv
       :cwd cwd :environment environment :status :running
       :output-path (runtime-process-io-path session name "out")
       :error-path (runtime-process-io-path session name "err")))))

(defun runtime-process-records (session)
  ;; Pure loader over the durable index plus session table: no host or OS
  ;; observation happens here. The single alive probe per record lives in
  ;; runtime-process-domain-observe, which freezes it into a snapshot;
  ;; diff consumes snapshots only.
  (let ((table (runtime-session-process-records session)))
    (dolist (name (%runtime-process-state-names
                   (runtime-process-state-get session "proc" "known-services")))
      (unless (gethash name table)
        (let ((state (runtime-process-state-get
                      session "proc" (format nil "svc:~A" name))))
          (when state
            (setf (gethash name table)
                  (%runtime-process-record-from-state session name state))))))
    table))

(defun runtime-process-save-record (session record)
  (let ((spec (runtime-process-record-spec record)))
    (unless spec
      (error "process record ~A has no durable specification"
             (runtime-process-record-name record)))
    (let ((table (runtime-process-records session)))
      (setf (gethash (runtime-process-record-name record) table) record)
      (runtime-process-state-put
       session "proc"
       (format nil "svc:~A" (runtime-process-record-name record))
       (pp.kernel:make-vmap
        (list (cons (pp.kernel:make-vkeyword "pid")
                    (pp.kernel:make-vint (runtime-process-record-pid record)))
              (cons (pp.kernel:make-vkeyword "spec") spec))))
      (let ((names nil))
        (maphash (lambda (name ignored)
                   (declare (ignore ignored))
                   (push name names))
                 table)
        (setf names (sort names #'string<))
        (labels ((value-list (items)
                   (if (null items)
                       (pp.kernel:make-vnil)
                       (pp.kernel:make-vpair
                        (pp.kernel:make-vstring (first items))
                        (value-list (rest items))))))
          (runtime-process-state-put
           session "proc" "known-services" (value-list names)))))
    record))

(defun runtime-process-record (session name)
  (or (gethash name (runtime-process-records session))
      (let ((state (runtime-process-state-get
                    session "proc" (format nil "svc:~A" name))))
        (when state
          (let ((record (%runtime-process-record-from-state session name state)))
            (setf (gethash name (runtime-process-records session)) record)
            (runtime-process-reap record)
            record)))))

(defun runtime-process-state-path (session domain key)
  (let* ((layout (pp.rt.session:runtime-session-store-layout session))
         (directory (merge-pathnames
                     (format nil "domain-state/~A/" domain)
                     (pp.rt.store:store-directory-pathname
                      (pp.rt.store:store-layout-root layout)))))
    (pp.rt.store:store-ensure-directory directory)
    (namestring
     (merge-pathnames (pp.kernel:hash-string key) directory))))

(defun runtime-process-io-path (session name extension)
  (let* ((layout (pp.rt.session:runtime-session-store-layout session))
         (directory (merge-pathnames "domain-state/proc-io/"
                                     (pp.rt.store:store-directory-pathname
                                      (pp.rt.store:store-layout-root layout)))))
    (pp.rt.store:store-ensure-directory directory)
    (namestring
     (merge-pathnames
      (format nil "svc-~A.~A" (pp.kernel:hash-string name) extension)
      directory))))

(defun runtime-process-state-get (session domain key)
  (let* ((path (runtime-process-state-path session domain key))
         (bytes (pp.rt.store:store-read-octets path)))
    (when bytes
      (let ((value (ignore-errors
                     (pp.kernel:decode-value (pp.rt.store:store-octets-string bytes)))))
        (or value
            (error "corrupt durable process state: ~A" key))))))

(defun runtime-domain-state-get (session domain key)
  (handler-case
      (runtime-process-state-get session domain key)
    (error ()
      (error "corrupt state: ~A" key))))

(defun runtime-domain-state-put (session domain key value)
  (runtime-process-state-put session domain key value))

(defun runtime-process-state-put (session domain key value)
  (unless (pp.kernel:durable-value-p value)
    (error "process state value is not durable"))
  (let ((path (runtime-process-state-path session domain key)))
    (if (typep value 'pp.kernel:value-nil)
        (ignore-errors (delete-file path))
        (pp.rt.store:store-atomic-replace path
                                          (pp.kernel:encode-value value)))))

(defun runtime-process-start (session name spec)
  (runtime-process-require-capability)
  (runtime-process-require-durable-spec spec)
  (let* ((hash (runtime-process-spec-hash spec))
         (argv (runtime-process-argv spec))
         ;; Reject an unresolvable command BEFORE the journal records a
         ;; start intent: an intent without a matching done record must mean
         ;; crash-during-start, never bad input.
         (command (runtime-process-resolve-command (first argv)))
         (cwd (runtime-process-cwd spec))
         (output (runtime-process-io-path session name "out"))
         (error-output (runtime-process-io-path session name "err"))
         (environment (runtime-process-environment spec)))
    (unless command
      (error "process command not found: ~A" (first argv)))
    (ignore-errors (delete-file output))
    (ignore-errors (delete-file error-output))
    (runtime-journal-append
     session (make-runtime-journal-proc-start-intent name hash))
    (let ((process (sb-ext:run-program command
                                       (rest argv)
                                       :search nil :wait nil :input "/dev/null"
                                       :output output :error error-output
                                       :directory cwd
                                       :environment environment)))
      (let* ((pid (sb-ext:process-pid process))
             (record (make-runtime-process-record
                      :name name :spec-hash hash :spec spec :pid pid
                      :argv argv :cwd cwd :environment environment
                      :status :running :output-path output
                      :error-path error-output)))
        (runtime-journal-append
         session (make-runtime-journal-proc-start-done name hash pid))
        (runtime-process-save-record session record)))
    #-sbcl (error "process isolation provider is unavailable on this Lisp")))

(defun %runtime-process-reap-pid (pid)
  #+sbcl
  (handler-case
      (multiple-value-bind (reaped status)
          (sb-posix:waitpid pid sb-posix:wnohang)
        (declare (ignore status))
        (and (integerp reaped) (= reaped pid)))
    (error () nil))
  #-sbcl nil)

(defun runtime-process-alive-p (pid)
  #+sbcl
  (and (integerp pid) (plusp pid)
       (not (%runtime-process-reap-pid pid))
       (handler-case
           (progn (sb-posix:kill pid 0) t)
         (error () nil)))
  #-sbcl nil)

(defun %runtime-process-wait-exit (pid seconds)
  #+sbcl
  (let ((deadline (+ (get-internal-real-time)
                     (round (* seconds internal-time-units-per-second)))))
    (loop
      (when (%runtime-process-reap-pid pid) (return t))
      (unless (runtime-process-alive-p pid) (return t))
      (when (>= (get-internal-real-time) deadline) (return nil))
      (sleep 0.05)))
  #-sbcl (declare (ignore pid seconds)))

(defun runtime-process-stop (session name &optional record)
  (runtime-process-require-capability)
  (let ((record (or record (runtime-process-record session name))))
    (when record
      (runtime-journal-append
       session (make-runtime-journal-proc-stop-intent name))
      #+sbcl
      (unless (%runtime-process-wait-exit
               (runtime-process-record-pid record) 0)
        (ignore-errors
          (sb-posix:kill (runtime-process-record-pid record) sb-posix:sigterm))
        (unless (%runtime-process-wait-exit
                 (runtime-process-record-pid record) 1.0)
          (ignore-errors
            (sb-posix:kill (runtime-process-record-pid record) sb-posix:sigkill))
          ;; Reap a child after SIGKILL without waiting indefinitely.
          (%runtime-process-wait-exit
           (runtime-process-record-pid record) 0.25)))
      (runtime-journal-append
       session (make-runtime-journal-proc-stop-done name))
      (runtime-process-state-put
       session "proc" (format nil "svc:~A" name)
       (pp.kernel:make-vnil))
      (setf (runtime-process-record-status record) :stopped)
      record)))

(defun runtime-process-reap (record)
  (when (and record (eq (runtime-process-record-status record) :running)
             (not (runtime-process-alive-p (runtime-process-record-pid record))))
    (setf (runtime-process-record-status record) :exited))
  record)

(defun runtime-process-start-service (session name spec)
  (runtime-process-require-durable-spec spec)
  (let ((provider (runtime-session-find-service session :process-start)))
    (if provider (funcall provider session name spec)
        (runtime-process-start session name spec))))
(defun runtime-process-stop-service (session name record)
  (let ((provider (runtime-session-find-service session :process-stop)))
    (if provider (funcall provider session name record)
        (runtime-process-stop session name record))))
(defstruct (runtime-process-plan
            (:constructor make-runtime-process-plan
                (actions started stopped restarted)))
  actions started stopped restarted)

(defstruct (runtime-process-snapshot
            (:constructor make-runtime-process-snapshot
                (&key name pid alive spec-hash spec status)))
  name pid alive spec-hash spec status)

(defun runtime-process-domain-observe (session)
  ;; The domain's single OS observation point: one alive probe (reap) per
  ;; record, frozen into an immutable per-service snapshot. Everything
  ;; downstream, diff in particular, is a pure function of these snapshots.
  (let ((snapshots (make-hash-table :test #'equal)))
    (maphash
     (lambda (name record)
       (let ((record (runtime-process-reap record)))
         (setf (gethash name snapshots)
               (make-runtime-process-snapshot
                :name name
                :pid (runtime-process-record-pid record)
                :alive (eq (runtime-process-record-status record) :running)
                :spec-hash (runtime-process-record-spec-hash record)
                :spec (runtime-process-record-spec record)
                :status (runtime-process-record-status record)))))
     (runtime-process-records session))
    snapshots))
(defun runtime-process-domain-diff (session observed desired)
  ;; Pure over the observation snapshot: no capability authority, no process
  ;; table access, no OS probes. Authority is enforced at mutation time by
  ;; runtime-process-start/-stop; plan actions carry a name and desired
  ;; spec, never mutable records or stale pids.
  (declare (ignore session))
  (let ((seen (make-hash-table :test #'equal))
        (actions nil) (started 0) (stopped 0) (restarted 0))
    (dolist (entry (value-map-entries desired))
      (let* ((name (runtime-process-text (car entry) "supervise service"))
             (spec (cdr entry))
             (hash (runtime-process-spec-hash spec))
             (snapshot (gethash name observed)))
        (setf (gethash name seen) t)
        (cond
          ((and snapshot
                (or (not (string= hash
                                  (runtime-process-snapshot-spec-hash snapshot)))
                    (not (runtime-process-snapshot-alive snapshot))))
           (push (list :restart name spec) actions)
           (incf stopped) (incf restarted))
          ((not snapshot)
           (push (list :start name spec) actions)
           (incf started)))))
    (maphash (lambda (name snapshot)
               (unless (gethash name seen)
                 (push (list :stop name nil) actions)
                 (incf stopped)))
             observed)
    (make-runtime-process-plan
     (nreverse actions) started stopped restarted)))
(defun runtime-process-domain-save-known-services (session)
  (let ((names nil))
    (maphash (lambda (name ignored)
               (declare (ignore ignored))
               (push name names))
             (runtime-process-records session))
    (labels ((value-list (items)
               (if (null items)
                   (pp.kernel:make-vnil)
                   (pp.kernel:make-vpair
                    (pp.kernel:make-vstring (first items))
                    (value-list (rest items))))))
      (runtime-process-state-put
       session "proc" "known-services"
       (value-list (sort names #'string<))))))
(defun runtime-process-domain-apply (session plan)
  (unless (runtime-process-plan-safe-p plan)
    (error "supervise: unsafe process plan"))
  (dolist (action (runtime-process-plan-actions plan))
    (destructuring-bind (kind name spec) action
      (when (member kind '(:stop :restart))
        ;; Resolve the CURRENT record at mutation time; the pid carried in
        ;; the plan is an identifier, never the mutation target.
        (let ((record (runtime-process-record session name)))
          (runtime-process-stop-service session name record))
        (when (eq kind :stop)
          (remhash name (runtime-process-records session))))
      (unless (eq kind :stop)
        (runtime-process-start-service session name spec))))
  (runtime-process-domain-save-known-services session)
  (format *error-output* "supervise: started=~D stopped=~D restarted=~D~%"
          (runtime-process-plan-started plan)
          (runtime-process-plan-stopped plan)
          (runtime-process-plan-restarted plan))
  (finish-output *error-output*)
  plan)

(defun runtime-process-plan-converged-p (session plan)
  (declare (ignore session))
  (and (null (runtime-process-plan-actions plan))
       (zerop (runtime-process-plan-started plan))
       (zerop (runtime-process-plan-stopped plan))
       (zerop (runtime-process-plan-restarted plan))))
(defun runtime-process-plan-safe-p (plan)
  (and (typep plan 'runtime-process-plan)
       (let ((actions-length (ignore-errors
                               (list-length
                                (runtime-process-plan-actions plan)))))
         (and actions-length
              (every
               (lambda (action)
                 (let ((action-length (ignore-errors (list-length action))))
                   (and action-length
                        (= action-length 3)
                        (or (eq (first action) :stop)
                            (pp.kernel:durable-value-p (third action))))))
               (runtime-process-plan-actions plan))))))

(defun runtime-process-domain-entry (session)
  (make-runtime-domain-entry
   :namespace '("process")
   :observe (lambda () (runtime-process-domain-observe session))
   :diff (lambda (observed desired)
           (runtime-process-domain-diff session observed desired))
   :apply (lambda (plan) (runtime-process-domain-apply session plan))
   :plan-valid-p
   (lambda (plan) (runtime-process-plan-safe-p plan))
   :converged-p #'runtime-process-plan-converged-p))
