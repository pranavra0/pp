;;;; Per-node scratch boundary.
(in-package #:pp.runtime)

(defstruct (runtime-sandbox
            (:constructor make-runtime-sandbox (root &key (owned t))))
  root (owned t))


(defun runtime-sandbox-create (&key (prefix "pp-node"))
  ;; mkdir(2) refuses existing names, so the random suffix is a uniqueness
  ;; guarantee rather than a probability — and two pp processes cannot share
  ;; scratch space even though their saved PRNG state starts out identical.
  #+sbcl
  (let ((root (store-exclusive-directory
               (or (and (sb-ext:posix-getenv "TMPDIR")
                        (plusp (length (sb-ext:posix-getenv "TMPDIR")))
                        (sb-ext:posix-getenv "TMPDIR"))
                   "/tmp")
               prefix)))
    (make-runtime-sandbox (namestring (truename root))))
  #-sbcl
  (let* ((base (or (sb-ext:posix-getenv "TMPDIR") "/tmp"))
         (root (merge-pathnames (format nil "~A-~D/" prefix (get-universal-time))
                                (pathname base))))
    (ensure-directories-exist root)
    (make-runtime-sandbox (namestring (truename root)))))

(defun runtime-sandbox-relative-p (path)
  (and (stringp path) (plusp (length path))
       (not (member (char path 0) '(#\/ #\~) :test #'char=))
       (not (some (lambda (part) (string= part ".."))
                  (let ((parts nil) (start 0))
                    (loop for at = (cl:position #\/ path :start start)
                          do (if at
                                 (progn (push (subseq path start at) parts)
                                        (setf start (1+ at)))
                                 (progn (push (subseq path start) parts)
                                        (return (nreverse parts))))))))))

(defun runtime-sandbox-path (sandbox path &key create)
  (let ((root (if (typep sandbox 'runtime-sandbox)
                  (runtime-sandbox-root sandbox)
                  sandbox)))
    (unless (and root (runtime-sandbox-relative-p path))
      (error "sandbox path must be relative and confined"))
    (let* ((root-path (pathname (ensure-directories-exist root)))
           (candidate (merge-pathnames path root-path))
           (parent (store-directory-pathname candidate)))
      (when create (ensure-directories-exist parent))
      (let ((directory (ignore-errors (truename parent)))
            (root-real (ignore-errors (truename root-path))))
        (unless (and directory root-real
                     (let ((root-text (namestring root-real))
                           (dir-text (namestring directory)))
                       (and (>= (length dir-text) (length root-text))
                            (string= root-text dir-text
                                     :end2 (length root-text)))))
          (error "sandbox parent is not a private directory"))
        (namestring candidate)))))

(defun runtime-sandbox-current (&optional (required nil))
  (let ((node (and (fboundp 'runtime-dynamic-current-node)
                   (runtime-dynamic-current-node))))
    (cond ((and node (runtime-node-frame-p node)
                (runtime-node-frame-sandbox node))
           (runtime-node-frame-sandbox node))
          (required (error "sandbox service is unavailable"))
          (t nil))))

(defun runtime-sandbox-resolve (path &key (create nil))
  (let ((sandbox (runtime-sandbox-current)))
    (when sandbox
      (runtime-sandbox-path sandbox path :create create))))

(defun runtime-sandbox-delete-tree (path)
  (when (probe-file path)
    (dolist (entry (remove-duplicates
                    (append (directory (merge-pathnames "*"
                                                        (store-directory-pathname path)))
                            (directory (merge-pathnames "*.*"
                                                        (store-directory-pathname path))))
                    :test #'equal :key #'namestring))
      (if (probe-file (store-directory-pathname entry))
          (runtime-sandbox-delete-tree entry)
          (ignore-errors (delete-file entry))))
    #+sbcl (ignore-errors (sb-posix:rmdir (store-absolute-path path)))
    #-sbcl (ignore-errors (delete-file path))))

(defun runtime-sandbox-with (sandbox thunk)
  (unless (typep sandbox 'runtime-sandbox)
    (error "invalid sandbox"))
  (funcall thunk))

(defun runtime-sandbox-with-node (key thunk &key persistent)
  (let* ((sandbox (runtime-sandbox-create))
         (frame (make-runtime-node-frame :key key :persistent persistent
                                          :sandbox sandbox)))
    (unwind-protect
         (if (fboundp 'runtime-dynamic-with-node)
             (runtime-dynamic-with-node frame thunk)
             (error "dynamic node scope is unavailable"))
      (when (runtime-sandbox-owned sandbox)
        (runtime-sandbox-delete-tree (runtime-sandbox-root sandbox))))))

(setf (symbol-function 'sandbox-resolve) #'runtime-sandbox-resolve)
