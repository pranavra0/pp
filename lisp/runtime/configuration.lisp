;;;; Ambient configuration snapshots and reads.
(in-package #:pp.rt.config)

(defun runtime-configuration-error (message &optional (code "runtime.configuration"))
  (if (fboundp 'language-fail) (language-fail message code) (error "~A" message)))


(defun runtime-configuration-normalize (config)
  (unless (typep config 'value-map)
    (runtime-configuration-error "configuration must be a map"))
  (unless (durable-value-p config)
    (runtime-configuration-error "configuration may not contain authority or code" "runtime.authority"))
  (make-vmap (canonical-map-entries (value-map-entries config))))

(defun runtime-configuration-hash (configs)
  (hash-concat (cons "cfg" (mapcar #'hash-value configs))))

(defun runtime-configuration-current ()
  ;; Configurations are dynamic extent: outside a scope there are none.
  (when (runtime-dynamic-current nil)
    (runtime-dynamic-config)))

(defun runtime-configuration-snapshot (&optional (configs (runtime-configuration-current)))
  (copy-list configs))

(defun runtime-configuration-current-hash ()
  (runtime-configuration-hash (runtime-configuration-current)))

(defun runtime-configuration-lookup (key &optional default default-p)
  (let ((key (cond ((stringp key) key)
                   ((typep key 'value-string) (value-string-value key))
                   ((typep key 'value-symbol) (value-symbol-value key))
                   ((typep key 'value-keyword) (value-keyword-value key))
                   (t nil))))
    (unless key (runtime-configuration-error "configuration key must be text"))
    (multiple-value-bind (value present) (runtime-dynamic-config-lookup key)
      (if present (values value t)
          (if default-p (values default t) (values nil nil))))))
(defun runtime-configuration-read (key &optional default default-p)
  (multiple-value-bind (value present)
      (runtime-configuration-lookup key default default-p)
    (let ((hash (if present (hash-value value) "config-cell:absent"))
          (cell-key (cond ((stringp key) key)
                          ((typep key 'value-string) (value-string-value key))
                          ((typep key 'value-symbol) (value-symbol-value key))
                          ((typep key 'value-keyword) (value-keyword-value key))
                          (t (runtime-configuration-error
                              "configuration key must be text")))))
      (when (fboundp 'pp.rt.observation:runtime-observation-record)
        (pp.rt.observation:runtime-observation-record (make-cell-config cell-key) hash))
      (values value present))))

(defun runtime-configuration-with (config thunk)
  (runtime-dynamic-push-config (runtime-configuration-normalize config))
  (unwind-protect
       (funcall thunk)
    (runtime-dynamic-pop-config)))
(defun runtime-configuration-push (config)
  (runtime-dynamic-push-config (runtime-configuration-normalize config)))
(defun runtime-configuration-pop () (runtime-dynamic-pop-config))
(defun runtime-config-hash (&optional configs) (runtime-configuration-hash (or configs (runtime-configuration-current))))
(defun runtime-config-lookup (key &optional default default-p) (runtime-configuration-lookup key default default-p))
(defun runtime-config-read (key &optional default default-p) (runtime-configuration-read key default default-p))
(defun runtime-config-with (config thunk) (runtime-configuration-with config thunk))
(defun configuration-hash (configs) (runtime-configuration-hash configs))
(defun configuration-lookup (key &optional default default-p)
  (runtime-configuration-lookup key default default-p))
(defun configuration-read (key &optional default default-p)
  (runtime-configuration-read key default default-p))
