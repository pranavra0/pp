(in-package :pp.kernel)

;;; Canonical paths are opaque authority values.  The resolver is deliberately
;;; required: constructing a path with IDENTITY would turn a spelling (and
;;; possibly a symlink or .. component) into authority.
(defstruct (canonical-path
            (:constructor %make-canonical-path (string))
            (:conc-name %canonical-path-))
  (string "" :type string :read-only t))

(defun canonical-path-string (path)
  "Return a copy of PATH's canonical spelling, never its retained storage."
  (copy-seq (%canonical-path-string path)))

(defun canonicalize-path (path &key realpath)
  (check-type path string)
  (unless (functionp realpath)
    (error "CANONICALIZE-PATH requires an injected REALPATH resolver"))
  (let ((resolved (funcall realpath path)))
    (check-type resolved string)
    (%make-canonical-path (copy-seq resolved))))

(defun canonical-path-to-string (path)
  (canonical-path-string path))

(defun path-under-p (root path)
  "Return true only for equality or a complete path-component descendant."
  (check-type root canonical-path)
  (check-type path canonical-path)
  (let* ((r (canonical-path-string root))
         (p (canonical-path-string path))
         (strip
           (lambda (s)
             (if (and (> (length s) 1)
                      (char= (char s (1- (length s))) #\/))
                 (subseq s 0 (1- (length s)))
                 s))))
    (setf r (funcall strip r)
          p (funcall strip p))
    (or (string= r p)
        (let ((prefix (if (string= r "/") "/"
                          (concatenate 'string r "/"))))
          (and (<= (length prefix) (length p))
               (string= prefix p :end2 (length prefix)))))))

(defun path-under (root path)
  (path-under-p root path))
