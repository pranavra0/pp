;;;; Canonical artifact trees and filesystem reconciliation.
(in-package #:pp.runtime)

(defstruct (runtime-artifact-entry
            (:constructor %make-artifact (kind path mode blob target)))
  kind path mode blob target)

(defun runtime-artifact-file (p m b) (%make-artifact :file p m b nil))
(defun runtime-artifact-directory (p m) (%make-artifact :directory p m nil nil))
(defun runtime-artifact-symlink (p target) (%make-artifact :symlink p nil nil target))
(defun runtime-artifact-error (f &rest a) (error (apply #'format nil f a)))

(defun runtime-artifact-valid-path-p (p)
  (and (stringp p) (plusp (length p)) (char/= (char p 0) #\/)
       (not (find #\Null p))
       (every (lambda (x) (and (plusp (length x))
                                (not (member x '("." "..") :test #'string=))))
              (uiop:split-string p :separator "/"))))

(defun %af (v)
  (unless (typep v 'value-map)
    (runtime-artifact-error "tree entry must be a map"))
  (let ((r nil))
    (dolist (x (value-map-entries v))
      (unless (typep (car x) 'value-keyword)
        (runtime-artifact-error "tree fields must use keywords"))
      (push (cons (value-keyword-value (car x)) (cdr x)) r))
    r))

(defun %av (f n) (cdr (assoc n f :test #'string=)))
(defun %a-exact-fields-p (fields names)
  (and (= (length fields) (length names))
       (every (lambda (name) (assoc name fields :test #'string=))
              names)))

(defun %am (v p)
  (unless (and (typep v 'value-int) (<= 0 (value-int-value v) #o777))
    (runtime-artifact-error "invalid mode at ~A" p))
  (value-int-value v))

(defun %ae (p v)
  (unless (runtime-artifact-valid-path-p p)
    (runtime-artifact-error "non-canonical tree path: ~A" p))
  (let* ((f (%af v))
         (k (%av f "kind")))
    (cond
      ((and (typep k 'value-keyword)
            (string= (value-keyword-value k) "file"))
       (unless (%a-exact-fields-p f '("blob" "kind" "mode"))
         (runtime-artifact-error "invalid file entry at ~A" p))
       (let ((b (%av f "blob")))
         (unless (and (typep b 'value-string)
                      (store-digest-p (value-string-value b)))
           (runtime-artifact-error "invalid blob identity for tree path: ~A" p))
         (runtime-artifact-file p (%am (%av f "mode") p)
                                (value-string-value b))))
      ((and (typep k 'value-keyword)
            (string= (value-keyword-value k) "directory"))
       (unless (%a-exact-fields-p f '("kind" "mode"))
         (runtime-artifact-error "invalid directory entry at ~A" p))
       (runtime-artifact-directory p (%am (%av f "mode") p)))
      ((and (typep k 'value-keyword)
            (string= (value-keyword-value k) "symlink"))
       (unless (%a-exact-fields-p f '("kind" "target"))
         (runtime-artifact-error "invalid symlink entry at ~A" p))
       (let ((target (%av f "target")))
         (unless (and (typep target 'value-string)
                      (not (find #\Null (value-string-value target))))
           (runtime-artifact-error "invalid symlink entry at ~A" p))
         (runtime-artifact-symlink p (value-string-value target))))
      (t (runtime-artifact-error "invalid tree entry at ~A" p)))))

(defun runtime-artifact-tree-from-value (v)
  (let* ((e (and (typep v 'value-map) (value-map-entries v)))
         (top (and e (caar e)))
         (m (and e (cdar e))))
    (unless (and (= (length e) 1)
                 (typep top 'value-keyword)
                 (string= (value-keyword-value top) "tree")
                 (typep m 'value-map))
      (runtime-artifact-error
       "tree must be exactly {:tree -> {path -> entry}}"))
    (let ((r nil)
          (seen (make-hash-table :test #'equal)))
      (dolist (x (value-map-entries m))
        (unless (typep (car x) 'value-string)
          (runtime-artifact-error "tree paths must be strings"))
        (let ((p (value-string-value (car x))))
          (when (gethash p seen)
            (runtime-artifact-error "duplicate tree path: ~A" p))
          (setf (gethash p seen) t)
          (push (%ae p (cdr x)) r)))
      (let ((entries (sort r #'string< :key #'runtime-artifact-entry-path)))
        (dolist (entry entries)
          (let ((path (runtime-artifact-entry-path entry)))
            (loop for slash = (cl:position #\/ path)
                    then (and slash (cl:position #\/ path :start (1+ slash)))
                  while slash
                  for parent = (subseq path 0 slash)
                  do (let ((parent-entry
                             (find parent entries
                                   :key #'runtime-artifact-entry-path
                                   :test #'string=)))
                       (unless (and parent-entry
                                    (eq (runtime-artifact-entry-kind parent-entry)
                                        :directory))
                         (runtime-artifact-error
                          "tree path has no directory parent: ~A" path))))))
        entries))))

(defun %ad (e)
  (ecase (runtime-artifact-entry-kind e)
    (:file
     (make-vmap
      (list (cons (make-vkeyword "blob")
                  (make-vstring (runtime-artifact-entry-blob e)))
            (cons (make-vkeyword "kind") (make-vkeyword "file"))
            (cons (make-vkeyword "mode")
                  (make-vint (runtime-artifact-entry-mode e))))))
    (:directory
     (make-vmap
      (list (cons (make-vkeyword "kind") (make-vkeyword "directory"))
            (cons (make-vkeyword "mode")
                  (make-vint (runtime-artifact-entry-mode e))))))
    (:symlink
     (make-vmap
      (list (cons (make-vkeyword "kind") (make-vkeyword "symlink"))
            (cons (make-vkeyword "target")
                  (make-vstring (runtime-artifact-entry-target e))))))))

(defun runtime-artifact-tree-to-value (es)
  (make-vmap
   (list
    (cons (make-vkeyword "tree")
          (make-vmap
           (mapcar
            (lambda (e)
              (cons (make-vstring (runtime-artifact-entry-path e))
                    (%ad e)))
            (sort (copy-list es) #'string<
                  :key #'runtime-artifact-entry-path)))))))

(defun runtime-artifact-tree-validate (es)
  (runtime-artifact-tree-from-value (runtime-artifact-tree-to-value es))
  t)

(defvar *runtime-artifact-session* nil)

(defun %ab ()
  (let* ((s (or *runtime-artifact-session*
                (runtime-dynamic-session nil)))
         (f (and s (runtime-session-find-service s :store-blobs))))
    (or (and f (funcall f))
        (runtime-artifact-error "artifact blob repository unavailable"))))

(defun runtime-artifact-blob-put (x) (blob-repository-put (%ab) x))

(defun runtime-artifact-blob-get (h)
  (or (blob-repository-get (%ab) h)
      (runtime-artifact-error "tree blob is missing or corrupt: ~A" h)))

(defun %ak (p)
  #+sbcl
  (ignore-errors
    (let ((m (sb-posix:stat-mode
              (sb-posix:lstat (store-absolute-path p)))))
      (cond ((= (logand m sb-posix:s-ifmt) sb-posix:s-ifdir) :directory)
            ((= (logand m sb-posix:s-ifmt) sb-posix:s-ifreg) :file)
            ((= (logand m sb-posix:s-ifmt) sb-posix:s-iflnk) :symlink)
            (t :other))))
  #-sbcl
  (if (probe-file p) :file nil))

(defun %a-mode (p)
  #+sbcl
  (ignore-errors
    (logand (sb-posix:stat-mode
             (sb-posix:lstat (store-absolute-path p)))
            #o777))
  #-sbcl nil)


(defun %a-directory-pathname (path)
  (let* ((name (namestring (pathname path)))
         (name (if (and (plusp (length name))
                        (char= (char name (1- (length name))) #\/))
                   name
                   (concatenate 'string name "/"))))
    (pathname name)))

(defun %ap (r p)
  (merge-pathnames p
                   (%a-directory-pathname (store-absolute-path r))))

(defun %a-current-target (p)
  #+sbcl (ignore-errors (sb-posix:readlink (store-absolute-path p)))
  #-sbcl nil)

(defun %a-directory-entries (directory)
  (remove-duplicates
   (append (directory (merge-pathnames "*" directory))
           (directory (merge-pathnames "*.*" directory)))
   :test #'equal :key #'namestring))

(defun %a-children (root relative)
  (%a-directory-entries
   (%a-directory-pathname (%ap root relative))))

(defun %a-child-relative (root child)
  (string-right-trim "/"
                     (enough-namestring
                      (pathname child)
                      (%a-directory-pathname
                       (store-absolute-path root)))))
(defun %a-current-tree (root)
  (let ((result nil))
    (labels ((walk (relative)
               (dolist (child (%a-children root relative))
                 (let* ((path (%a-child-relative root child))
                        (kind (%ak child)))
                   (when kind
                     (push (cons path kind) result)
                     (when (eq kind :directory)
                       (walk path)))))))
      (walk ""))
    result))

(defun %a-delete-tree (p)
  (let ((kind (%ak p)))
    (cond
      ((eq kind :directory)
       (let ((count 0))
         (dolist (child (%a-directory-entries (%a-directory-pathname p)))
           (incf count (%a-delete-tree child)))
         #+sbcl (sb-posix:rmdir (store-absolute-path p))
         #-sbcl (delete-file p)
         count))
      ((member kind '(:file :symlink :other))
       (delete-file p)
       1)
      (t 0))))

(defun %a-parent-paths (path)
  (let ((result nil)
        (start 0))
    (loop for slash = (cl:position #\/ path :start start)
          while slash
          do (push (subseq path 0 slash) result)
             (setf start (1+ slash)))
    (nreverse result)))

(defun %a-check-parents (root path)
  (dolist (parent (%a-parent-paths path))
    (let ((kind (%ak (%ap root parent))))
      (when (member kind '(:symlink :file :other))
        (runtime-artifact-error
         "cannot traverse non-directory artifact parent: ~A" parent)))))

(defun %a-entry-matches-p (root entry)
  (let* ((p (%ap root (runtime-artifact-entry-path entry)))
         (kind (%ak p))
         (expected (runtime-artifact-entry-kind entry)))
    (and (eq kind expected)
         (case expected
           (:directory (= (%a-mode p)
                          (runtime-artifact-entry-mode entry)))
           (:file
            (and (= (%a-mode p) (runtime-artifact-entry-mode entry))
                 (let ((bytes (store-read-octets p)))
                   (and bytes
                        (string= (store-hash-octets bytes)
                                 (runtime-artifact-entry-blob entry))))))
           (:symlink
            (string= (%a-current-target p)
                     (runtime-artifact-entry-target entry)))))))

(defun %a-materialize-one (root entry &key (verify t))
  (let* ((relative (runtime-artifact-entry-path entry))
         (p (%ap root relative))
         (kind (%ak p))
         (expected (runtime-artifact-entry-kind entry)))
    (%a-check-parents root relative)
    (when (and kind (not (eq kind expected)))
      (%a-delete-tree p)
      (setf kind nil))
    (ecase expected
      (:directory
       (unless kind
         #+sbcl (sb-posix:mkdir (store-absolute-path p)
                                (runtime-artifact-entry-mode entry))
         #-sbcl (ensure-directories-exist p))
       #+sbcl (sb-posix:chmod (store-absolute-path p)
                              (runtime-artifact-entry-mode entry)))
      (:file
       (unless (and verify kind (%a-entry-matches-p root entry))
         (let ((bytes (runtime-artifact-blob-get
                       (runtime-artifact-entry-blob entry))))
           (with-open-file (s p :direction :output
                              :element-type '(unsigned-byte 8)
                              :if-exists :supersede
                              :if-does-not-exist :create)
             (write-sequence bytes s))))
       #+sbcl (sb-posix:chmod (store-absolute-path p)
                              (runtime-artifact-entry-mode entry)))
      (:symlink
       (unless (and verify kind (%a-entry-matches-p root entry))
         (when kind (%a-delete-tree p))
         #+sbcl (sb-posix:symlink
                 (runtime-artifact-entry-target entry)
                 (store-absolute-path p))
         #-sbcl (error "symlink unavailable"))))))

(defun runtime-artifact-materialize (root es &key (read-current t))
  (runtime-artifact-tree-validate es)
  (let ((kind (%ak root)))
    (cond ((null kind) (store-ensure-directory root))
          ((not (eq kind :directory))
           (runtime-artifact-error "artifact root is not a directory: ~A" root)))
    (unless (eq (%ak root) :directory)
      (runtime-artifact-error "artifact root is not a directory: ~A" root)))
  (dolist (entry es)
    (%a-check-parents root (runtime-artifact-entry-path entry))
    (%a-materialize-one root entry :verify read-current))
  t)

(defun runtime-artifact-reconcile (root desired &key (read-current t))
  (let* ((es (runtime-artifact-tree-from-value desired))
         (desired-paths (make-hash-table :test #'equal))
         (create 0)
         (update 0)
         (delete 0))
    (dolist (entry es)
      (setf (gethash (runtime-artifact-entry-path entry) desired-paths) entry))
    (let ((kind (%ak root)))
      (cond ((null kind) (store-ensure-directory root))
            ((not (eq kind :directory))
             (runtime-artifact-error "artifact root is not a directory: ~A" root)))
      (unless (eq (%ak root) :directory)
        (runtime-artifact-error "artifact root is not a directory: ~A" root)))
    (when read-current
      (dolist (current (%a-current-tree root))
        (let ((path (car current)))
          (unless (gethash path desired-paths)
            (incf delete (%a-delete-tree (%ap root path)))))))
    (dolist (entry es)
      (let ((kind (%ak (%ap root (runtime-artifact-entry-path entry)))))
        (cond
          ((null kind)
           (unless (eq (runtime-artifact-entry-kind entry) :directory)
             (incf create)))
          ((and read-current (not (%a-entry-matches-p root entry)))
           (unless (eq (runtime-artifact-entry-kind entry) :directory)
             (incf update))))))
    (runtime-artifact-materialize root es :read-current read-current)
    (values create update delete)))


(defun runtime-artifact-snapshot (root &optional paths)
  (let ((entries (make-hash-table :test #'equal)))
    (labels ((add (entry)
               (setf (gethash (runtime-artifact-entry-path entry) entries)
                     entry))
             (add-parents (path)
               (dolist (parent (%a-parent-paths path))
                 (unless (gethash parent entries)
                   (let ((parent-path (%ap root parent)))
                     (unless (eq (%ak parent-path) :directory)
                       (runtime-artifact-error
                        "selected output has a non-directory parent: ~A"
                        path))
                     (add (runtime-artifact-directory
                           parent (%a-mode parent-path)))))))
             (walk (path)
               (unless (runtime-artifact-valid-path-p path)
                 (runtime-artifact-error
                  "non-canonical selected output path: ~A" path))
               (let* ((source (%ap root path))
                      (kind (%ak source)))
                 (unless kind
                   (runtime-artifact-error
                    "selected output is missing: ~A" path))
                 (add-parents path)
                 (ecase kind
                   (:file
                    (let ((bytes (store-read-octets source)))
                      (unless bytes
                        (runtime-artifact-error
                         "selected output is missing: ~A" path))
                      (add (runtime-artifact-file
                            path (%a-mode source)
                            (blob-repository-put (%ab) bytes)))))
                   (:directory
                    (add (runtime-artifact-directory path (%a-mode source)))
                    (dolist (child
                              (sort (%a-children root path) #'string<
                                    :key (lambda (p)
                                           (%a-child-relative root p))))
                      (walk (%a-child-relative root child))))
                   (:symlink
                    #+sbcl
                    (add (runtime-artifact-symlink
                          path (sb-posix:readlink (store-absolute-path source))))
                    #-sbcl
                    (runtime-artifact-error
                     "symlink unavailable: ~A" path))
                   (:other
                    (runtime-artifact-error
                     "selected output has an unsupported entry kind: ~A"
                     path))))))
      (let ((selected (or paths
                          (mapcar (lambda (child)
                                    (%a-child-relative root child))
                                  (%a-children root "")))))
        (dolist (path (sort (remove-duplicates (copy-list selected)
                                               :test #'string=)
                            #'string<))
          (walk path)))
      (let ((result (sort (loop for entry being the hash-values of entries
                                collect entry)
                          #'string< :key #'runtime-artifact-entry-path)))
        (runtime-artifact-tree-validate result)
        result))))
(defun runtime-artifact-observe-value (root)
  (when (and (runtime-dynamic-current nil)
             (fboundp 'runtime-observation-authorize-tree-effect)
             (not (runtime-observation-authorize-tree-effect root)))
    (if (fboundp 'runtime-observation-error)
        (runtime-observation-error
         "tree-observe: capability error: no read access"
         "runtime.authority")
        (runtime-artifact-error
         "tree-observe: capability error: no read access")))
  (let ((entries nil))
    (dolist (item (%a-current-tree root))
      (let ((path (car item))
            (kind (cdr item)))
        (when (eq kind :file)
          (let ((bytes (store-read-octets (%ap root path))))
            (unless bytes
              (runtime-artifact-error "cannot observe artifact file: ~A" path))
            (push (cons (make-vstring path)
                        (make-vstring (store-hash-octets bytes)))
                  entries)))))
    (make-vmap (sort entries #'string< :key (lambda (entry)
                                              (value-string-value (car entry)))))))
