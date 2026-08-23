;;;; Process-isolated scheduling and hash-checked artifact transport.

(in-package #:pp.runtime)

(eval-when (:compile-toplevel :load-toplevel :execute)
  #+sbcl (require :sb-posix))

(defparameter +distribution-wire-version+ "pp-distribution 1")
(defparameter *distribution-process-counter* 0)

(define-condition distribution-error (error)
  ((code :initarg :code :reader distribution-error-code)
   (detail :initarg :detail :reader distribution-error-detail))
  (:report (lambda (condition stream)
             (format stream "distribution (~A): ~A"
                     (distribution-error-code condition)
                     (distribution-error-detail condition)))))

(defun distribution-fail (code detail)
  (error 'distribution-error :code code :detail detail))

(defun %distribution-string-octets (string)
  (if (fboundp 'store-string-octets)
      (store-string-octets string)
      (pp.kernel:string-octets string)))

(defun %distribution-octets-string (octets)
  (if (fboundp 'store-octets-string)
      (store-octets-string octets)
      (error "distribution requires the canonical UTF-8 decoder")))

(defun %distribution-hash-octets (octets)
  (if (fboundp 'store-hash-octets)
      (store-hash-octets octets)
      (error "distribution requires the store hash adapter")))

(defun %distribution-digest-p (name)
  (and (stringp name)
       (if (fboundp 'store-digest-p)
           (store-digest-p name)
           (and (= (length name) 64)
                (every (lambda (c)
                        (or (digit-char-p c 16)
                            (and (char>= c #\a) (char<= c #\f))))
                       name)))))

(defun %distribution-key-text (key)
  (cond ((stringp key) key)
        ((keywordp key) (string-downcase (symbol-name key)))
        (t (distribution-fail "descriptor" "map keys must be strings"))))

(defun %distribution-hex (octets)
  (string-downcase
   (with-output-to-string (out)
     (loop for byte across octets do (format out "~2,'0X" byte)))))

(defun %distribution-unhex (text)
  (unless (evenp (length text))
    (distribution-fail "wire" "odd-length hexadecimal string"))
  (let ((result (make-array (/ (length text) 2)
                            :element-type '(unsigned-byte 8))))
    (loop for i from 0 below (length text) by 2
          for j from 0
          do (let ((value (parse-integer text :start i :end (+ i 2)
                                          :radix 16 :junk-allowed nil)))
               (unless value (distribution-fail "wire" "invalid hexadecimal byte"))
               (setf (aref result j) value)))
    result))

(defun %distribution-safe-integer-p (value)
  (and (integerp value)
       (<= (- (expt 2 63)) value)
       (< value (expt 2 63))))
(defun %distribution-map-p (value)
  (and (listp value)
       (every (lambda (item)
                (and (consp item) (consp (cdr item)) (null (cddr item))))
              value)))
(declaim (ftype function %distribution-pp-value-p))
(defun %distribution-normalize-data (value)
  (cond
    ((or (null value) (eq value t) (stringp value) (integerp value)
         (%distribution-pp-value-p value))
     value)
    ((vectorp value)
     (map 'vector #'%distribution-normalize-data value))
    ((consp value)
     (if (or (%distribution-map-p value) (every #'consp value))
         (mapcar (lambda (entry)
                   (let* ((key (%distribution-key-text (car entry)))
                          (tail (cdr entry))
                          (item (if (and (consp tail) (null (cddr entry)))
                                    (cadr entry)
                                    tail)))
                     (list key (%distribution-normalize-data item))))
                 value)
         (mapcar #'%distribution-normalize-data value)))
    (t value)))

(defun %distribution-field (map name)
  (let ((entry (assoc name map :test #'string=)))
    (and entry (second entry))))
(defun %distribution-pp-value-p (value)
  (or (typep value 'pp.kernel:value-nil)
      (typep value 'pp.kernel:value-bool)
      (typep value 'pp.kernel:value-int)
      (typep value 'pp.kernel:value-float)
      (typep value 'pp.kernel:value-string)
      (typep value 'pp.kernel:value-keyword)
      (typep value 'pp.kernel:value-symbol)
      (typep value 'pp.kernel:value-pair)
      (typep value 'pp.kernel:value-vector)
      (typep value 'pp.kernel:value-map)
      (typep value 'pp.kernel:value-set)
      (typep value 'pp.kernel:value-closure)
      (typep value 'pp.kernel:value-builtin)
      (typep value 'pp.kernel:value-capability)
      (typep value 'pp.kernel:value-thunk)
      (typep value 'pp.kernel:value-env-map)
      (typep value 'pp.kernel:value-sealed)))


(defun %distribution-data-p (value &optional (depth 0))
  (when (> depth 128) (return-from %distribution-data-p nil))
  (cond
    ((null value) t)
    ((or (eq value t) (stringp value) (%distribution-safe-integer-p value)) t)
    ((typep value 'function) nil)
    ((or (pathnamep value) (hash-table-p value) (streamp value)) nil)
    ((%distribution-pp-value-p value)
     (not (null (ignore-errors (pp.kernel:encode-value value)))))
    ((vectorp value)
     (loop for item across value always (%distribution-data-p item (1+ depth))))
    ((consp value)
     (if (%distribution-map-p value)
         (and (every (lambda (item)
                       (and (%distribution-data-p (car item) (1+ depth))
                            (%distribution-data-p (cadr item) (1+ depth)))) value)
              (let ((keys (mapcar (lambda (item) (%distribution-key-text (car item))) value)))
                (= (length keys) (length (remove-duplicates keys :test #'string=)))))
         (every (lambda (item) (%distribution-data-p item (1+ depth))) value)))
    ((symbolp value) (or (keywordp value) (eq value t)))
    (t nil)))

(defun %distribution-wire-data (value)
  (unless (%distribution-data-p value)
    (distribution-fail "descriptor" "non-data value cannot cross a process boundary"))
  (cond
    ((null value) "n;")
    ((eq value t) "b1;")
    ((stringp value)
     (let* ((bytes (%distribution-string-octets value))
            (hex (%distribution-hex bytes)))
       (format nil "s~D:~A" (length bytes) hex)))
    ((integerp value) (format nil "i~D;" value))
    ((keywordp value)
     (%distribution-wire-data (string-downcase (symbol-name value))))
    ((%distribution-pp-value-p value)
     (let* ((encoded (pp.kernel:encode-value value))
            (bytes (%distribution-string-octets encoded)))
       (format nil "p~D:~A" (length bytes) (%distribution-hex bytes))))
    ((vectorp value)
     (with-output-to-string (out)
       (format out "v~D;" (length value))
       (loop for item across value do (write-string (%distribution-wire-data item) out))))
    ((consp value)
     (if (%distribution-map-p value)
         (let ((entries (sort (mapcar (lambda (item)
                                        (list (%distribution-key-text (car item))
                                              (cadr item))) value)
                              #'string< :key #'car)))
           (with-output-to-string (out)
             (format out "m~D;" (length entries))
             (dolist (entry entries)
               (write-string (%distribution-wire-data (car entry)) out)
               (write-string (%distribution-wire-data (cadr entry)) out))))
         (with-output-to-string (out)
           (format out "l~D;" (length value))
           (dolist (item value)
             (write-string (%distribution-wire-data item) out)))))
    (t (distribution-fail "descriptor" "unsupported descriptor value"))))

(defun %distribution-read-decimal (text cursor)
  (let ((end (cl:position #\; text :start cursor)))
    (unless end (distribution-fail "wire" "missing numeric terminator"))
    (values (parse-integer text :start cursor :end end :radix 10 :junk-allowed nil)
            (1+ end))))

(defun %distribution-read-data (text cursor)
  (when (>= cursor (length text)) (distribution-fail "wire" "truncated descriptor"))
  (let ((tag (char text cursor)) (at (1+ cursor)))
    (case tag
      (#\n (unless (and (< at (length text)) (char= (char text at) #\;))
             (distribution-fail "wire" "malformed nil"))
          (values nil (1+ at)))
      (#\b (multiple-value-bind (number next) (%distribution-read-decimal text at)
             (unless (or (= number 0) (= number 1))
               (distribution-fail "wire" "malformed boolean"))
             (values (= number 1) next)))
      (#\i (multiple-value-bind (number next) (%distribution-read-decimal text at)
             (unless (%distribution-safe-integer-p number)
               (distribution-fail "wire" "integer outside canonical range"))
             (values number next)))
      ((#\s #\p)
       (let ((colon (cl:position #\: text :start at)))
         (unless colon (distribution-fail "wire" "missing byte count"))
         (let* ((count (parse-integer text :start at :end colon :radix 10
                                     :junk-allowed nil))
                (hex-start (1+ colon))
                (hex-end (+ hex-start (* 2 count))))
           (unless (and (>= count 0) (<= hex-end (length text)))
             (distribution-fail "wire" "truncated byte string"))
           (let ((bytes (%distribution-unhex (subseq text hex-start hex-end))))
             (if (char= tag #\p)
                 (let* ((encoded (%distribution-octets-string bytes))
                        (value (ignore-errors (pp.kernel:decode-value encoded))))
                   (unless value (distribution-fail "wire" "invalid pp value payload"))
                   (values value hex-end))
                 (values (%distribution-octets-string bytes) hex-end))))))
      ((#\l #\v #\m)
       (multiple-value-bind (count next) (%distribution-read-decimal text at)
         (unless (and (>= count 0) (<= count 1000000))
           (distribution-fail "wire" "invalid collection count"))
         (if (char= tag #\m)
             (let ((entries nil) (cursor next))
               (dotimes (i count)
                 (multiple-value-bind (key after-key) (%distribution-read-data text cursor)
                   (unless (stringp key) (distribution-fail "wire" "map key is not a string"))
                   (multiple-value-bind (value after-value)
                       (%distribution-read-data text after-key)
                     (push (list key value) entries)
                     (setf cursor after-value))))
               (let* ((entries (nreverse entries))
                      (keys (mapcar #'car entries)))
                 (unless (and (equal keys (sort (copy-list keys) #'string<))
                              (= (length keys)
                                 (length (remove-duplicates keys :test #'string=))))
                   (distribution-fail "wire" "map is not in canonical order"))
                 (values entries cursor)))
             (let ((items nil) (cursor next))
               (dotimes (i count)
                 (multiple-value-bind (value after) (%distribution-read-data text cursor)
                   (push value items)
                   (setf cursor after)))
               (let ((items (nreverse items)))
                 (values (if (char= tag #\v) (coerce items 'vector) items) cursor))))))
      (otherwise (distribution-fail "wire" "unknown descriptor tag")))))

(defun distribution-wire-encode (value)
  (concatenate 'string +distribution-wire-version+ ":" (%distribution-wire-data value)))

(defun distribution-wire-decode (text)
  (unless (and (stringp text)
               (>= (length text) (1+ (length +distribution-wire-version+)))
               (string= +distribution-wire-version+ text :end1 (length +distribution-wire-version+)
                       :end2 (length +distribution-wire-version+)))
    (distribution-fail "wire" "unsupported distribution wire version"))
  (let ((start (length +distribution-wire-version+)))
    (unless (and (< start (length text)) (char= (char text start) #\:))
      (distribution-fail "wire" "malformed distribution wire header"))
    (multiple-value-bind (value cursor) (%distribution-read-data text (1+ start))
      (unless (= cursor (length text))
        (distribution-fail "wire" "trailing bytes in distribution descriptor"))
      value)))

(defstruct (distribution-policy (:constructor %make-distribution-policy))
  (kind :serial) (width 1) member)

(defun make-distribution-policy (&key (kind :serial) (width 1) member)
  (when (stringp kind)
    (let ((colon (cl:position #\: kind)))
      (if colon
          (let ((name (subseq kind 0 colon))
                (tail (subseq kind (1+ colon))))
            (setf kind (intern (string-upcase name) :keyword))
            (if (eq kind :remote)
                (setf member tail)
                (setf width (parse-integer tail :radix 10 :junk-allowed nil))))
          (setf kind (intern (string-upcase kind) :keyword)))))
  (unless (member kind '(:serial :parallel :race :remote))
    (distribution-fail "schedule" "unknown distribution policy"))
  (unless (and (integerp width) (plusp width))
    (distribution-fail "schedule" "schedule width must be positive"))
  (when (and (eq kind :remote) (or (null member) (not (stringp member))))
    (distribution-fail "schedule" "remote schedule requires a member name"))
  (%make-distribution-policy :kind kind :width width :member member))

(defstruct (distribution-job (:constructor %make-distribution-job))
  key (width 1) data-closed-p descriptor)

(defun make-distribution-job (&key key (width 1) data-closed-p descriptor)
  (unless (or (stringp key) (and key (ignore-errors (node-key-to-string key))))
    (distribution-fail "job" "job key must have canonical text"))
  (let* ((key (if (stringp key) key (node-key-to-string key)))
         (descriptor (and descriptor (%distribution-normalize-data descriptor))))
    (unless (and (integerp width) (plusp width))
      (distribution-fail "job" "job width must be positive"))
    (when (and descriptor (not (%distribution-data-p descriptor)))
      (distribution-fail "job" "job descriptor is not data-closed"))
    (%make-distribution-job :key key :width width
                            :data-closed-p (not (null data-closed-p))
                            :descriptor descriptor)))

(defun distribution-job-wire-descriptor (job)
  (or (distribution-job-descriptor job)
      (list (list "key" (distribution-job-key job))
            (list "width" (distribution-job-width job))
            (list "data-closed" (distribution-job-data-closed-p job)))))

(defun distribution-job-wire (job)
  (distribution-wire-encode
   (list (list "key" (distribution-job-key job))
         (list "width" (distribution-job-width job))
         (list "data-closed" (distribution-job-data-closed-p job))
         (list "descriptor" (distribution-job-wire-descriptor job)))))

(defstruct (distribution-result (:constructor %make-distribution-result))
  (status :ok) payload error artifacts)

(defun make-distribution-result (&key (status :ok) payload error artifacts)
  (unless (member status '(:ok :failed :cancelled))
    (distribution-fail "result" "unknown result status"))
  (let* ((payload (and payload (%distribution-normalize-data payload)))
         (artifacts (and artifacts (%distribution-normalize-data artifacts))))
    (when (and payload (not (%distribution-data-p payload)))
      (distribution-fail "result" "result payload is not data"))
    (when (and artifacts (not (%distribution-data-p artifacts)))
      (distribution-fail "result" "result artifacts are not descriptors"))
    (%make-distribution-result :status status :payload payload :error error
                               :artifacts artifacts)))

(defun %distribution-result-wire (result)
  (distribution-wire-encode
   (list (list "status" (string-downcase (symbol-name (distribution-result-status result))))
         (list "payload" (distribution-result-payload result))
         (list "error" (or (distribution-result-error result) ""))
         (list "artifacts" (or (distribution-result-artifacts result) nil)))))

(defun %distribution-result-from-wire (text)
  (let* ((data (distribution-wire-decode text))
         (status (%distribution-field data "status"))
         (payload (%distribution-field data "payload"))
         (error-text (%distribution-field data "error"))
         (artifacts (%distribution-field data "artifacts")))
    (unless (and (stringp status) (member status '("ok" "failed" "cancelled") :test #'string=))
      (distribution-fail "wire" "result has an unknown status"))
    (%make-distribution-result
     :status (intern (string-upcase status) :keyword)
     :payload payload
     :error (unless (or (null error-text) (string= error-text "")) error-text)
     :artifacts artifacts)))

(defstruct (distribution-scheduler (:constructor %make-distribution-scheduler))
  policy runner remote-send transport (live-children (make-hash-table :test #'eql))
  (closed nil))

(defun make-distribution-scheduler (&key policy runner remote-send transport)
  (unless (functionp runner)
    (distribution-fail "schedule" "scheduler requires a runner callback"))
  (%make-distribution-scheduler
   :policy (or policy (make-distribution-policy))
   :runner runner :remote-send remote-send :transport transport))

(defun %distribution-temp-root ()
  (or #+sbcl (sb-posix:getenv "TMPDIR")
      (ignore-errors (namestring (truename "/tmp"))) "/tmp"))

(defun %distribution-temp-path (prefix)
  (incf *distribution-process-counter*)
  (merge-pathnames
   (format nil "~A-~D-~D.wire" prefix
           #+sbcl (sb-posix:getpid) #-sbcl 0 *distribution-process-counter*)
   (pathname (format nil "~A/" (%distribution-temp-root)))))

(defun %distribution-write-file (path text)
  (ensure-directories-exist path)
  (let ((temporary (format nil "~A.tmp.~D" path *distribution-process-counter*)))
    (with-open-file (stream temporary :direction :output :if-exists :supersede
                           :element-type '(unsigned-byte 8))
      (write-sequence (%distribution-string-octets text) stream)
      (finish-output stream))
    (rename-file temporary path)
    path))

(defun %distribution-read-file (path)
  (with-open-file (stream path :direction :input :element-type '(unsigned-byte 8))
    (let ((bytes (make-array (file-length stream) :element-type '(unsigned-byte 8))))
      (read-sequence bytes stream)
      (%distribution-octets-string bytes))))

(defun %distribution-delete-file (path)
  (ignore-errors (when (probe-file path) (delete-file path))))

(defun %distribution-run-direct (scheduler job)
  (handler-case
      (let ((value (funcall (distribution-scheduler-runner scheduler) job)))
        (if (typep value 'distribution-result)
            value
            (make-distribution-result :payload value)))
    (distribution-error (condition)
      (make-distribution-result :status :failed
                                :error (distribution-error-detail condition)))
    (error (condition)
      (make-distribution-result :status :failed
                                :error (princ-to-string condition)))))

(defun %distribution-child-run (scheduler job path)
  (handler-case
      (let ((result (%distribution-run-direct scheduler job)))
        (%distribution-write-file path (%distribution-result-wire result))
        0)
    (error (condition)
      (handler-case
          (%distribution-write-file
           path (%distribution-result-wire
                 (make-distribution-result :status :failed
                                           :error (princ-to-string condition))))
        (error () nil))
      1)))

(defun %distribution-fork-job (scheduler job)
  #+sbcl
  (let ((path (%distribution-temp-path "pp-distribution")))
    (finish-output)
    (force-output)
    (let ((pid (sb-posix:fork)))
      (if (zerop pid)
          (sb-posix:_exit (%distribution-child-run scheduler job path))
          (progn
            (setf (gethash pid (distribution-scheduler-live-children scheduler))
                  (cons job path))
            (values pid path)))))
  #-sbcl
  (declare (ignore scheduler job))
  #-sbcl
  (distribution-fail "process" "fork is unavailable"))

(defun %distribution-status-ok-p (status)
  #+sbcl (= (logand status #xff) 0)
  #-sbcl (= status 0))

(defun %distribution-terminate-pid (pid)
  #+sbcl
  (progn
    (ignore-errors (sb-posix:kill pid 15))
    (sleep 0.02)
    (ignore-errors (sb-posix:kill pid 9))
    (ignore-errors (sb-posix:waitpid pid 0)))
  #-sbcl (declare (ignore pid)))

(defun distribution-cancel (scheduler)
  (maphash (lambda (pid entry)
             (%distribution-terminate-pid pid)
             (%distribution-delete-file (cdr entry)))
           (distribution-scheduler-live-children scheduler))
  (clrhash (distribution-scheduler-live-children scheduler))
  t)

(defun %distribution-reap-pid (scheduler pid status)
  (let* ((entry (gethash pid (distribution-scheduler-live-children scheduler)))
         (job (and entry (car entry)))
         (path (and entry (cdr entry))))
    (remhash pid (distribution-scheduler-live-children scheduler))
    (values
     (if (and path (probe-file path))
         (handler-case
             (let ((result (%distribution-result-from-wire (%distribution-read-file path))))
               (%distribution-delete-file path)
               (if (%distribution-status-ok-p status)
                   result
                   (make-distribution-result :status :failed
                                             :error "worker exited before completing")))
           (error (condition)
             (%distribution-delete-file path)
             (make-distribution-result :status :failed :error (princ-to-string condition))))
         (make-distribution-result :status :failed
                                   :error "worker produced no result descriptor"))
     job)))

(defun %distribution-wait-one (scheduler)
  #+sbcl
  (handler-case
      (multiple-value-bind (pid status) (sb-posix:waitpid -1 0)
        (multiple-value-bind (result job) (%distribution-reap-pid scheduler pid status)
          (values pid result job)))
    (error ()
      ;; A loser may have been reaped while another completion was handled.
      ;; Remove one stale ownership entry so the scheduler can make progress.
      (let ((pid nil) (entry nil))
        (maphash (lambda (candidate value)
                   (unless pid
                     (setf pid candidate entry value)))
                 (distribution-scheduler-live-children scheduler))
        (when pid
          (remhash pid (distribution-scheduler-live-children scheduler))
          (when entry
            (%distribution-delete-file (cdr entry))))
        (values pid
                (make-distribution-result
                 :status :failed
                 :error "worker exited before completing")
                (and entry (car entry))))))
  #-sbcl (declare (ignore scheduler) (distribution-fail "process" "wait is unavailable")))

(defun %distribution-run-parallel (scheduler jobs width)
  (let ((queue (copy-list jobs)) (active 0) (results nil))
    (unwind-protect
         (progn
           (loop while (or queue (> active 0)) do
             (loop while (and queue (< active width)) do
               (%distribution-fork-job scheduler (pop queue))
               (incf active))
             (when (> active 0)
               (multiple-value-bind (pid result job) (%distribution-wait-one scheduler)
                 (declare (ignore pid job))
                 (decf active)
                 (push result results))))
           (nreverse results))
      (when (plusp (hash-table-count (distribution-scheduler-live-children scheduler)))
        (distribution-cancel scheduler)))))
(defun %distribution-run-race (scheduler jobs width)
  (let ((queue nil) (results nil) (active 0)
        (winner (make-hash-table :test #'equal)))
    (dolist (job jobs)
      (loop repeat (max 1 (distribution-job-width job))
            do (push job queue)))
    (setf queue (nreverse queue))
    (labels ((stop-losers (key)
               (let ((losers nil))
                 (maphash (lambda (pid entry)
                            (when (string= key (distribution-job-key (car entry)))
                              (push pid losers)))
                          (distribution-scheduler-live-children scheduler))
                 (dolist (pid losers)
                   (%distribution-terminate-pid pid)
                   (remhash pid (distribution-scheduler-live-children scheduler))
                   (decf active)))))
      (unwind-protect
           (loop while (or queue (> active 0)) do
             (loop while (and queue (< active width)) do
               (let ((job (pop queue)))
                 (unless (gethash (distribution-job-key job) winner)
                   (%distribution-fork-job scheduler job)
                   (incf active))))
             (when (> active 0)
               (multiple-value-bind (pid result job) (%distribution-wait-one scheduler)
                 (declare (ignore pid))
                 (decf active)
                 (push result results)
                 (when (and job (eq (distribution-result-status result) :ok))
                   (let ((key (distribution-job-key job)))
                     (setf (gethash key winner) t)
                     (setf queue (remove-if
                                  (lambda (pending)
                                    (string= key (distribution-job-key pending)))
                                  queue))
                     (stop-losers key)))))
         (when (plusp (hash-table-count (distribution-scheduler-live-children scheduler)))
           (distribution-cancel scheduler))))
    (or (find :ok results :key #'distribution-result-status)
        (car (last results))
        (make-distribution-result :status :failed :error "race produced no result")))))
(declaim (ftype function distribution-remote-dispatch))
(defun %distribution-remote-wire (scheduler policy jobs)
  (if (null jobs)
      nil
      (let ((send (distribution-scheduler-remote-send scheduler)))
        (unless (functionp send)
          (distribution-fail "remote" "remote transport service is unavailable"))
        (distribution-remote-dispatch (distribution-policy-member policy)
                                       jobs send))))

(defun distribution-dispatch (scheduler jobs)
  (unless (and (listp jobs) (every (lambda (job) (typep job 'distribution-job)) jobs))
    (distribution-fail "schedule" "dispatch expects distribution jobs"))
  (let ((policy (distribution-scheduler-policy scheduler)))
    (case (distribution-policy-kind policy)
      (:serial (mapcar (lambda (job) (%distribution-run-direct scheduler job)) jobs))
      (:parallel (%distribution-run-parallel scheduler jobs (distribution-policy-width policy)))
      (:race (list (%distribution-run-race scheduler jobs (distribution-policy-width policy))))
      (:remote
       (let ((closed (remove-if-not #'distribution-job-data-closed-p jobs))
             (local (remove-if #'distribution-job-data-closed-p jobs)))
         (append (%distribution-remote-wire scheduler policy closed)
                 (mapcar (lambda (job) (%distribution-run-direct scheduler job)) local)))))))

(defun distribution-run (scheduler jobs)
  (unwind-protect (distribution-dispatch scheduler jobs)
    (distribution-cancel scheduler)))

;;; Artifact transport -------------------------------------------------------

(defstruct (distribution-artifact (:constructor %make-distribution-artifact))
  kind hash size)

(defun make-distribution-artifact (&key kind hash size)
  (let ((kind (if (stringp kind) (intern (string-upcase kind) :keyword) kind)))
    (unless (member kind '(:object :blob :trace))
      (distribution-fail "transport" "unknown artifact kind"))
    (unless (and (stringp hash) (%distribution-digest-p hash))
      (distribution-fail "transport" "artifact name is not a canonical digest"))
    (%make-distribution-artifact :kind kind :hash hash :size size)))

(defun %distribution-layout (root)
  (let ((layout (if (typep root 'store-layout) root (make-store-layout root))))
    (store-layout-init layout)
    layout))

(defun %distribution-artifact-path (layout kind hash)
  (store-layout-path layout
                     (ecase kind (:object :objects) (:blob :blobs) (:trace :traces))
                     hash))

(defun %distribution-trace-lines (content)
  (let ((lines (remove-if #'(lambda (line) (zerop (length line)))
                          (store-split-lines content))))
    (unless lines (distribution-fail "transport" "trace artifact is empty"))
    (mapcar (lambda (line)
              (let ((trace (trace-repository-of-line line)))
                (unless trace
                  (distribution-fail "transport" "trace artifact has malformed line"))
                (let ((canonical (trace-repository-to-line trace)))
                  (unless (string= canonical line)
                    (distribution-fail "transport" "trace artifact is noncanonical"))
                  canonical)))
            lines)))

(defun %distribution-merge-trace (destination key lines)
  (let ((existing (when (probe-file (%distribution-artifact-path destination :trace key))
                    (%distribution-trace-lines
                     (%distribution-octets-string
                      (store-read-octets (%distribution-artifact-path destination :trace key)))))))
    (let ((all (remove-duplicates (append existing lines) :test #'string=)))
      (store-atomic-replace (%distribution-artifact-path destination :trace key)
                            (with-output-to-string (out)
                              (dolist (line all) (format out "~A~%" line)))))))

(defun distribution-transport-push (source target kind hash)
  "Copy one local artifact into TARGET, verifying it before publication."
  (let* ((source (%distribution-layout source))
         (target (%distribution-layout target))
         (kind (if (stringp kind) (intern (string-upcase kind) :keyword) kind))
         (hash (store-identity-string hash)))
    (unless (%distribution-digest-p hash)
      (distribution-fail "transport" "invalid artifact name"))
    (let ((source-path (%distribution-artifact-path source kind hash)))
      (unless (probe-file source-path)
        (distribution-fail "transport" "source artifact is unavailable"))
      (ecase kind
        (:object
         (let* ((bytes (store-read-octets source-path))
                (value (ignore-errors
                         (pp.kernel:decode-value (%distribution-octets-string bytes))))
                (encoded (and value (ignore-errors (pp.kernel:encode-value value))))
                (canonical (and encoded (%distribution-string-octets encoded))))
           (unless (and value encoded canonical
                        (string= hash (pp.kernel:hash-value value))
                        (equalp bytes canonical))
             (distribution-fail "integrity"
                                "object content is not canonical or does not match its name"))
           (store-atomic-write-octets (%distribution-artifact-path target kind hash) bytes)
           (%make-distribution-artifact :kind kind :hash hash :size (length bytes))))
        (:blob
         (let ((bytes (store-read-octets source-path))
               (actual nil))
           (setf actual (%distribution-hash-octets bytes))
           (unless (string= hash actual)
             (distribution-fail
              "wire"
              (format nil
                      "wire: blob ~A: content hashes to ~A, not its claimed name — refusing to accept (corrupt or tampered in transit)"
                      hash actual)))
           (store-atomic-write-octets (%distribution-artifact-path target kind hash) bytes)
           (%make-distribution-artifact :kind kind :hash hash :size (length bytes))))
        (:trace
         (let* ((content (%distribution-octets-string (store-read-octets source-path)))
                (lines (%distribution-trace-lines content)))
           (%distribution-merge-trace target hash lines)
           (%make-distribution-artifact :kind kind :hash hash
                                        :size (length (%distribution-string-octets content)))))))))

(defun distribution-transport-pull (source target kind hash)
  "Receive one artifact from SOURCE and verify before writing TARGET."
  (distribution-transport-push source target kind hash))

(defun distribution-transport-move (source target artifacts)
  (unless (and (listp artifacts)
               (every (lambda (item)
                       (or (typep item 'distribution-artifact)
                           (and (listp item) (assoc "kind" item :test #'string=))))
                     artifacts))
    (distribution-fail "transport" "artifact movement expects descriptors"))
  (mapcar (lambda (item)
            (if (typep item 'distribution-artifact)
                (distribution-transport-push source target
                                              (distribution-artifact-kind item)
                                              (distribution-artifact-hash item))
                (distribution-transport-push source target
                                              (%distribution-field item "kind")
                                              (%distribution-field item "hash"))))
          artifacts))

(defun distribution-transport-encode-artifacts (artifacts)
  (distribution-wire-encode
   (mapcar (lambda (artifact)
             (list (list "kind" (string-downcase
                                  (symbol-name (distribution-artifact-kind artifact))))
                   (list "hash" (distribution-artifact-hash artifact))
                   (list "size" (or (distribution-artifact-size artifact) 0))))
           artifacts)))

;;; Remote placement ---------------------------------------------------------

(defun distribution-remote-descriptor (job)
  "Return only canonical data for a remote request; no closures or caps."
  (distribution-wire-encode
   (list (list "key" (distribution-job-key job))
         (list "width" (distribution-job-width job))
         (list "data-closed" (distribution-job-data-closed-p job))
         (list "descriptor" (distribution-job-wire-descriptor job)))))

(defun distribution-remote-dispatch (member jobs send)
  (unless (and (stringp member) (functionp send))
    (distribution-fail "remote" "remote member and descriptor sender are required"))
  (let ((wires (mapcar #'distribution-remote-descriptor jobs)))
    (dolist (wire wires) (distribution-wire-decode wire))
    (let ((replies (funcall send member wires)))
      (unless (listp replies) (distribution-fail "remote" "malformed remote reply"))
      (mapcar (lambda (reply)
                (let ((wire (if (typep reply 'distribution-result)
                                (%distribution-result-wire reply)
                                reply)))
                  (unless (stringp wire)
                    (distribution-fail "remote" "remote reply contained host data"))
                  (%distribution-result-from-wire wire)))
              replies))))

(defun distribution-members-path ()
  (or #+sbcl (sb-posix:getenv "PP_CLUSTER_MEMBERS")
      (let ((home #+sbcl (sb-posix:getenv "HOME") #-sbcl nil))
        (and home (merge-pathnames ".pp/cluster/members" (pathname home))))))

(defun distribution-load-members (&optional path)
  (let ((path (or path (distribution-members-path))))
    (if (and path (probe-file path))
        (loop for line in (store-split-lines (%distribution-read-file path))
              for trimmed = (string-trim '(#\Space #\Tab #\Return) line)
              unless (or (zerop (length trimmed)) (char= (char trimmed 0) #\#))
              collect (let ((fields
                              (remove-if
                               (lambda (s) (zerop (length s)))
                               (uiop:split-string trimmed
                                                  :separator (coerce (list #\Space #\Tab)
                                                                     'string)))))
                        (unless (>= (length fields) 2)
                          (distribution-fail "remote" "malformed cluster member row"))
                        (cons (first fields) (second fields))))
        nil)))

(defun distribution-member-root (member &optional path)
  (cdr (assoc member (distribution-load-members path) :test #'string=)))

;;; Reachability adapters ----------------------------------------------------

(defun %distribution-root-text (value)
  (cond ((stringp value) value)
        ((and (fboundp 'store-identity-string)
              (ignore-errors (store-identity-string value))))
        (t nil)))

(defun distribution-gc-root (result-hash node-keys)
  (let ((result-hash (%distribution-root-text result-hash))
        (node-keys (mapcar #'%distribution-root-text node-keys)))
    (unless (and result-hash (%distribution-digest-p result-hash)
                 (every (lambda (key) (and key (%distribution-digest-p key)))
                        node-keys))
      (distribution-fail "gc" "invalid reachability root"))
    (make-store-gc-root result-hash node-keys)))

(defun distribution-gc-root-from-descriptor (descriptor)
  (let* ((hash (%distribution-field descriptor "result-hash"))
         (nodes (%distribution-field descriptor "node-keys"))
         (nodes (if (vectorp nodes) (coerce nodes 'list) nodes)))
    (unless (and hash (listp nodes))
      (distribution-fail "gc" "descriptor has no durable root"))
    (distribution-gc-root hash nodes)))

(defun distribution-gc-mark (layout roots &key reachable-blobs)
  (let ((layout (%distribution-layout layout)))
    (let ((traces (make-trace-repository layout))
          (objects (make-object-repository layout)))
      (store-gc-mark-graph roots traces objects :reachable-blobs reachable-blobs))))

(defun distribution-gc-run (layout &key roots reachable-blobs grace-seconds snapshot-current)
  (let ((layout (%distribution-layout layout)))
    (store-gc-run layout (make-trace-repository layout) (make-object-repository layout)
                  :roots roots :reachable-blobs reachable-blobs
                  :grace-seconds (or grace-seconds 2)
                  :snapshot-current snapshot-current)))

(export '(distribution-error distribution-error-code distribution-error-detail
          distribution-fail distribution-policy make-distribution-policy
          distribution-policy-kind distribution-policy-width distribution-policy-member
          distribution-job make-distribution-job distribution-job-key
          distribution-job-width distribution-job-data-closed-p
          distribution-job-descriptor distribution-job-wire
          distribution-result make-distribution-result distribution-result-status
          distribution-result-payload distribution-result-error distribution-result-artifacts
          distribution-scheduler make-distribution-scheduler distribution-dispatch
          distribution-run distribution-cancel
          distribution-artifact make-distribution-artifact distribution-artifact-kind
          distribution-artifact-hash distribution-artifact-size
          distribution-wire-encode distribution-wire-decode
          distribution-transport-push distribution-transport-pull
          distribution-transport-move distribution-transport-encode-artifacts
          distribution-remote-descriptor distribution-remote-dispatch
          distribution-members-path distribution-load-members distribution-member-root
          distribution-gc-root distribution-gc-root-from-descriptor distribution-gc-mark
          distribution-gc-run)
        (find-package '#:pp.runtime))
