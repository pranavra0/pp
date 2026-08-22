;;;; Watch polling and push stabilization.
(in-package #:pp.runtime)

(defstruct (runtime-watch-state
            (:constructor make-runtime-watch-state (&key session interval stabilize once)))
  session (interval 1.0 :type real) stabilize once)
(defstruct (runtime-watch-snapshot
            (:constructor make-runtime-watch-snapshot (cells))) cells)

(defun runtime-watch-register-node-key (session key thunk)
  (runtime-session-set-node-thunk session key thunk))

(defun runtime-watch-runtime-edges (session reverse)
  (runtime-session-iter-node-dependents
   session
   (lambda (id keys)
     (let* ((cell (cell-serialize (make-cell-node id)))
            (old (gethash cell reverse)))
       (setf (gethash cell reverse)
             (sort (remove-duplicates
                    (append (mapcar #'runtime-session-key keys) old)
                    :test #'equal)
                   #'string<))))))

(defun runtime-watch-dependency-cells (session key)
  (let ((durable (cell-serialize (make-cell-node key)))
        (thunk (runtime-session-find-node-thunk session key)))
    (if (and thunk (thunk-hash thunk))
        (list durable
              (cell-serialize (make-cell-node (thunk-hash thunk))))
        (list durable))))

(defun runtime-watch-reset-dirty (session keys)
  (dolist (key keys)
    (let ((thunk (runtime-session-find-node-thunk session key)))
      (when thunk
        (setf (thunk-status thunk) (make-thunk-status-unevaluated)))))
  keys)

(defun runtime-watch-observation-hash (cell)
  (and (fboundp 'runtime-observe-id)
       (runtime-observe-id cell)))

(defun runtime-watch-evaluated-dependencies-changed-p (session key result)
  (let* ((traces (runtime-domain-service-value session :store-traces))
         (cache-key (and (fboundp 'cache-key-of-node-key)
                         (cache-key-of-node-key key)))
         (result-hash (pp.kernel:hash-value result))
         (traces (and traces cache-key
                      (trace-repository-load traces :key cache-key))))
    (and traces
         (some (lambda (trace)
                 (and (store-trace-outcome-ok-p (store-trace-outcome trace))
                      (string= (store-identity-string result-hash)
                               (store-identity-string
                                (store-trace-result-hash trace)))
                      (not (every
                            (lambda (read)
                              (let ((cell (store-identity-string (car read)))
                                    (expected (store-identity-string (cdr read))))
                                (if (and (>= (length cell) 5)
                                         (string= "node:" cell :end2 5))
                                    (let ((current
                                            (runtime-watch-observation-hash
                                             (cell-parse cell))))
                                      (and current
                                           (string= (store-identity-string current)
                                                    expected)))
                                    t)))
                            (store-trace-reads trace))))) traces))))

(defun runtime-watch-build-reverse-index (session)
  (let ((reverse (if (fboundp 'store-index-reverse)
                     (let ((traces (runtime-domain-service-value session :store-traces)))
                       (if traces (store-index-reverse traces)
                           (make-hash-table :test #'equal)))
                     (make-hash-table :test #'equal))))
    (runtime-watch-runtime-edges session reverse)
    reverse))

(defun runtime-watch-stabilize (session changed-cells)
  (let* ((reverse (runtime-watch-build-reverse-index session))
         (initial (remove-duplicates (mapcan (lambda (cell)
                                               (copy-list (gethash cell reverse)))
                                             changed-cells)
                                     :test #'equal))
         (dirty (if (fboundp 'store-index-dirty-keys)
                    (store-index-dirty-keys initial reverse
                                            (lambda (key)
                                              (runtime-watch-dependency-cells session key)))
                    initial)))
    (runtime-watch-reset-dirty session dirty)))

(defun runtime-watch-snapshot (session)
  (make-runtime-watch-snapshot
   (sort (copy-list (runtime-session-observations session)) #'string< :key #'car)))

(defun runtime-watch-snapshot-equal-p (left right)
  (equal (runtime-watch-snapshot-cells left)
         (runtime-watch-snapshot-cells right)))

(defun runtime-watch-call-sleep (seconds)
  (when (> seconds 0) (sleep seconds)))

(defun runtime-watch-run (state pass-function &key changed-function stop-function)
  (unless (typep state 'runtime-watch-state)
    (error "watch state is invalid"))
  (let ((session (runtime-watch-state-session state))
        (previous nil)
        (first t))
    (loop
      (when (and stop-function (funcall stop-function)) (return previous))
      (when (or first (not (runtime-watch-state-once state)))
        (setf first nil)
        (runtime-session-begin-watch session)
        (funcall pass-function session)
        (let ((current (runtime-watch-snapshot session)))
          (when (and previous (runtime-watch-state-stabilize state)
                     changed-function)
            (funcall changed-function session
                     (mapcar #'car (set-difference
                                    (runtime-watch-snapshot-cells current)
                                    (runtime-watch-snapshot-cells previous)
                                    :test #'equal))))
          (setf previous current)))
      (when (runtime-watch-state-once state) (return previous))
      (runtime-watch-call-sleep (runtime-watch-state-interval state)))) )

(defun runtime-watch-create (session &key (interval 1.0) stabilize once)
  (make-runtime-watch-state :session session :interval interval
                            :stabilize stabilize :once once))

(setf (symbol-function 'stabilize-register-node-key)
      #'runtime-watch-register-node-key)
(setf (symbol-function 'stabilize-reset-dirty) #'runtime-watch-reset-dirty)
(setf (symbol-function 'stabilize-dirty) #'runtime-watch-stabilize)
