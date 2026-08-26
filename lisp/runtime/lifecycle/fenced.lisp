;;;; Fenced intent/done actions and crash recovery.
(in-package #:pp.rt.fenced)

(defconstant +runtime-fenced-retry+ :retry)
(defconstant +runtime-fenced-abort+ :abort)
(defstruct (runtime-fenced-aborted
            (:constructor make-runtime-fenced-aborted (kind spec-hash reason)))
  kind spec-hash reason)

(defun runtime-fenced-force (session value)
  (runtime-domain-force session value))

(defun runtime-fenced-new-epoch (session)
  (let* ((nonce (runtime-session-next-fenced-epoch-nonce session))
         (pid #+sbcl (sb-posix:getpid) #-sbcl 0)
         (stamp (get-universal-time))
         (epoch (pp.kernel:hash-concat
                 (list "fenced-epoch" (princ-to-string stamp)
                       (princ-to-string pid) (princ-to-string nonce)))))
    (pp.rt.session:runtime-session-start-fenced-epoch session epoch)
    epoch))

(defun runtime-fenced-ensure-epoch (session)
  (or (let ((epoch (runtime-session-fenced-epoch session)))
        (and (plusp (length epoch)) epoch))
      (runtime-fenced-new-epoch session)))

(defun runtime-fenced-action-key (epoch kind spec-hash)
  (pp.kernel:hash-concat (list "fenced" epoch kind spec-hash)))

(defun runtime-fenced-spec-hash (session spec)
  (pp.kernel:hash-value (runtime-fenced-force session spec)))

(defun runtime-fenced-plain-data-p (value &optional (seen nil))
  (when (member value seen :test #'eq) (return-from runtime-fenced-plain-data-p nil))
  (let ((seen (cons value seen)))
    (typecase value
      ((or pp.kernel:value-nil pp.kernel:value-bool pp.kernel:value-int
           pp.kernel:value-float pp.kernel:value-string pp.kernel:value-keyword
           pp.kernel:value-symbol) t)
      (pp.kernel:value-pair
       (and (runtime-fenced-plain-data-p (value-pair-car value) seen)
            (runtime-fenced-plain-data-p (value-pair-cdr value) seen)))
      (pp.kernel:value-vector
       (every (lambda (item) (runtime-fenced-plain-data-p item seen))
              (coerce (value-vector-values value) 'list)))
      (pp.kernel:value-map
       (every (lambda (entry)
                (and (runtime-fenced-plain-data-p (car entry) seen)
                     (runtime-fenced-plain-data-p (cdr entry) seen)))
              (value-map-entries value)))
      (pp.kernel:value-set
       (every (lambda (item) (runtime-fenced-plain-data-p item seen))
              (value-set-values value)))
      (t nil))))

(defun runtime-fenced-map-find (session spec name)
  (find-if (lambda (entry)
             (let ((key (runtime-domain-string (car entry))))
               (and key (string= key name))))
           (value-map-entries (runtime-fenced-force session spec))))

(defun runtime-fenced-run-command (session spec)
  (let ((entry (runtime-fenced-map-find session spec "run")))
    (if (null entry)
        (make-vmap nil)
        (let* ((run (runtime-fenced-force session (cdr entry)))
               (argv
                 (cond ((typep run 'pp.kernel:value-nil) nil)
                       ((typep run 'pp.kernel:value-string)
                        (list "/bin/sh" "-c" (value-string-value run)))
                       ((typep run 'pp.kernel:value-vector)
                        (map 'list
                             (lambda (item)
                               (unless (typep item 'pp.kernel:value-string)
                                 (error "fenced: run argv must be strings"))
                               (value-string-value item))
                             (value-vector-values run)))
                       ((typep run 'pp.kernel:value-pair)
                        (labels ((collect (value)
                                   (let ((value (runtime-fenced-force session value)))
                                     (cond ((typep value 'pp.kernel:value-nil) nil)
                                           ((typep value 'pp.kernel:value-pair)
                                            (cons (let ((item (runtime-fenced-force
                                                               session (value-pair-car value))))
                                                    (unless (typep item 'pp.kernel:value-string)
                                                      (error "fenced: run argv must be strings"))
                                                    (value-string-value item))
                                                  (collect (value-pair-cdr value))))
                                           (t (error "fenced: run must be a proper string list"))))))
                          (collect run)))
                       (t (error "fenced: run must be a list, vector, or string")))))
          (unless (consp argv) (error "fenced: run argv is empty"))
          (multiple-value-bind (exit stdout stderr)
              (pp.rt.lifecycle.process:runtime-process-exec argv)
            (make-vmap
             (list (cons (make-vstring "exit") (make-vint exit))
                   (cons (make-vstring "out") (make-vstring stdout))
                   (cons (make-vstring "err") (make-vstring stderr)))))))))

(defun runtime-fenced-register (session kind spec)
  (unless (and (stringp kind) (plusp (length kind))
               (every (lambda (char) (> (char-code char) 32)) kind))
    (error "fenced: kind must be a nonempty token without whitespace"))
  (let ((scope (and (fboundp 'runtime-dynamic-current)
                    (runtime-dynamic-current nil))))
    (when (and scope (runtime-dynamic-in-node-p))
      (runtime-dynamic-require-script-tier
       "fenced effects may not appear inside node bodies (LAW 31)")))
  (let ((forced (runtime-fenced-force session spec)))
    (unless (runtime-fenced-plain-data-p forced)
      (error "fenced: spec is not serializable data"))
    (unless (pp.kernel:encode-value forced)
      (error "fenced: spec is not serializable data"))
    (runtime-session-add-fenced-action session (cons kind forced))))

(defun runtime-fenced-result-hash (value)
  (pp.kernel:hash-value value))

(defun runtime-fenced-current (session kind spec)
  (let* ((epoch (runtime-fenced-ensure-epoch session))
         (spec-hash (runtime-fenced-spec-hash session spec))
         (key (runtime-fenced-action-key epoch kind spec-hash))
         (objects (runtime-domain-service-value session :store-objects)))
    (unless (runtime-journal-has-fenced-done-p session key)
      (when objects
        (pp.rt.store:object-repository-put-fenced objects :hash spec-hash
                                                  :value (runtime-fenced-force session spec)))
      (runtime-journal-append
       session (make-runtime-journal-fenced-intent key epoch kind spec-hash))
      (let ((result (runtime-fenced-run-command session spec)))
        (runtime-journal-append
         session (make-runtime-journal-fenced-done
                  key (runtime-fenced-result-hash result)))))
    key))

(defun runtime-fenced-aborted-value (entry reason)
  (make-vmap
   (list (cons (make-vstring "aborted") (make-vbool t))
         (cons (make-vstring "reason") (make-vstring reason))
         (cons (make-vstring "kind")
               (make-vstring (pp.rt.journal:runtime-journal-fenced-intent-kind entry)))
         (cons (make-vstring "spec-hash")
               (make-vstring (pp.rt.journal:runtime-journal-fenced-intent-spec-hash entry))))))

(defun runtime-fenced-recover-entry (session entry decision)
  (let* ((key (pp.rt.journal:runtime-journal-fenced-intent-key entry))
         (epoch (pp.rt.journal:runtime-journal-fenced-intent-epoch entry))
         (kind (pp.rt.journal:runtime-journal-fenced-intent-kind entry))
         (spec-hash (pp.rt.journal:runtime-journal-fenced-intent-spec-hash entry))
         (expected (runtime-fenced-action-key epoch kind spec-hash))
         (result nil))
    (if (not (string= key expected))
        (setf result (runtime-fenced-aborted-value entry "action identity mismatch"))
        (let ((objects (runtime-domain-service-value session :store-objects))
              (spec nil))
          (setf spec (and objects
                          (pp.rt.store:object-repository-get-fenced objects :hash spec-hash)))
          (if (null spec)
              (setf result (runtime-fenced-aborted-value entry "spec missing from store"))
              (setf result
                    (if (member decision '(:retry retry) :test #'equal)
                        (runtime-fenced-run-command session spec)
                        (runtime-fenced-aborted-value entry
                                                      "recovery policy aborted action"))))))
    (runtime-journal-append
     session (make-runtime-journal-fenced-done
              key (runtime-fenced-result-hash result)))
    (when (string= key expected)
      (pp.rt.session:runtime-session-resume-fenced-epoch session epoch))
    (string= key expected)))

(defun runtime-fenced-recover-unknown (session decision)
  (let ((entries (runtime-journal-pending-fenced-actions session)))
    (dolist (entry entries) (runtime-fenced-recover-entry session entry decision))
    (length entries)))

(defun runtime-fenced-drain (session)
  (runtime-fenced-ensure-epoch session)
  (dolist (action (runtime-session-take-fenced-actions session))
    (runtime-fenced-current session (car action) (cdr action)))
  (runtime-session-clear-fenced-epoch session)
  t)

