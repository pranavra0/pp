;;;; Durable pp-store v2 repositories.
;;;;
;;;; The store accepts canonical kernel values and octets only.  It never
;;;; serializes host objects or follows links below the store root.
(in-package #:pp.runtime)

(deftype store-octets () '(vector (unsigned-byte 8)))

(defun store-copy-octets (bytes)
  (let ((copy (make-array (length bytes) :element-type '(unsigned-byte 8))))
    (replace copy bytes)
    copy))

(defun store-string-octets (string)
  (pp.kernel:string-octets string))

(defun store-octets-string (bytes)
  "Decode UTF-8 strictly for records whose grammar is text."
  (check-type bytes vector)
  (with-output-to-string (out)
    (labels ((continuation (i)
               (and (< i (length bytes))
                    (let ((byte (aref bytes i)))
                      (and (<= #x80 byte #xbf) byte))))
             (emit (code)
               (when (or (> code #x10ffff) (<= #xd800 code #xdfff))
                 (error "Invalid UTF-8 scalar"))
               (write-char (code-char code) out)))
      (loop with i = 0
            while (< i (length bytes)) do
        (let ((byte (aref bytes i)))
          (cond
            ((<= byte #x7f) (emit byte) (incf i))
            ((<= #xc2 byte #xdf)
             (let ((b1 (continuation (1+ i))))
               (unless b1 (error "Malformed UTF-8"))
               (emit (logior (ash (logand byte #x1f) 6)
                             (logand b1 #x3f)))
               (incf i 2)))
            ((<= #xe0 byte #xef)
             (let ((b1 (continuation (1+ i)))
                   (b2 (continuation (+ i 2))))
               (unless (and b1 b2
                            (or (/= byte #xe0) (>= b1 #xa0))
                            (or (/= byte #xed) (<= b1 #x9f)))
                 (error "Malformed UTF-8"))
               (emit (logior (ash (logand byte #xf) 12)
                             (ash (logand b1 #x3f) 6)
                             (logand b2 #x3f)))
               (incf i 3)))
            ((<= #xf0 byte #xf4)
             (let ((b1 (continuation (1+ i)))
                   (b2 (continuation (+ i 2)))
                   (b3 (continuation (+ i 3))))
               (unless (and b1 b2 b3
                            (or (/= byte #xf0) (>= b1 #x90))
                            (or (/= byte #xf4) (<= b1 #x8f)))
                 (error "Malformed UTF-8"))
               (emit (logior (ash (logand byte #x7) 18)
                             (ash (logand b1 #x3f) 12)
                             (ash (logand b2 #x3f) 6)
                             (logand b3 #x3f)))
               (incf i 4)))
            (t (error "Malformed UTF-8"))))))))

(defun store-codec-octets-string (bytes)
  "Map codec bytes one-for-one to Lisp characters."
  (check-type bytes vector)
  (map 'string (lambda (byte)
                 (unless (and (integerp byte) (<= 0 byte #xff))
                   (error "Codec record contains a non-octet"))
                 (code-char byte))
       bytes))

(defun store-codec-string-octets (string)
  "Inverse of STORE-CODEC-OCTETS-STRING without lossy transcoding."
  (check-type string string)
  (let ((bytes (make-array (length string)
                           :element-type '(unsigned-byte 8))))
    (loop for char across string
          for i from 0
          do (unless (<= (char-code char) #xff)
               (error "Codec record contains a non-byte character"))
             (setf (aref bytes i) (char-code char)))
    bytes))

(defun store-content-octets (content)
  (etypecase content
    (string (store-string-octets content))
    (vector
     (let ((copy (make-array (length content)
                             :element-type '(unsigned-byte 8))))
       (loop for item across content
             for i from 0
             do (unless (and (integerp item) (<= 0 item #xff))
                  (error "Store content must be octets"))
                (setf (aref copy i) item))
       copy))))

(defun store-hash-octets (bytes)
  (pp.kernel:sha256-octets bytes))
(defun store-hash-content (content)
  (store-hash-octets (store-content-octets content)))

(defun store-digest-p (string)
  (and (stringp string) (= (length string) 64)
       (every (lambda (char) (and (digit-char-p char 16)
                                  (or (char<= #\0 char #\9)
                                      (char<= #\a char #\f))))
              string)))

(defun store-identity-string (identity)
  (etypecase identity
    (string identity)
    (pp.kernel:node-key (pp.kernel:node-key-to-string identity))
    (pp.kernel:cache-key (pp.kernel:cache-key-to-string identity))
    (pp.kernel:object-hash (pp.kernel:object-hash-to-string identity))
    (pp.kernel:observed-hash (pp.kernel:observed-hash-to-string identity))
    (pp.kernel:cell-id (pp.kernel:cell-id-to-string identity))))

(defun store-absolute-path (path)
  (namestring (merge-pathnames (pathname path) (truename "."))))

(defun store-directory-pathname (path)
  (let* ((pathname (pathname path))
         (directory (pathname-directory pathname))
         (name (pathname-name pathname)))
    (make-pathname :directory (if name (append directory (list name)) directory)
                   :name nil :type nil :defaults pathname)))

(defun store-canonical-path (path)
  "Canonicalize an existing path, or its longest existing parent plus suffix."
  (let* ((absolute (pathname (store-absolute-path path)))
         (existing (ignore-errors (truename absolute))))
    (if existing
        (namestring existing)
        (let* ((directory (pathname-directory absolute))
               (parts (append (cdr directory)
                              (when (or (pathname-name absolute)
                                        (pathname-type absolute))
                                (list (if (pathname-type absolute)
                                          (format nil "~A.~A"
                                                  (pathname-name absolute)
                                                  (pathname-type absolute))
                                          (pathname-name absolute))))))
               (count nil))
          (loop for n from (length parts) downto 0
                for candidate = (make-pathname
                                 :directory (cons :absolute (subseq parts 0 n))
                                 :name nil :type nil :defaults absolute)
                when (probe-file candidate) do (setf count n) (return))
          (unless count (error "Cannot canonicalize store path ~A" path))
          (let ((root (namestring
                       (truename
                        (make-pathname
                         :directory (cons :absolute (subseq parts 0 count))
                         :name nil :type nil :defaults absolute)))))
            (dolist (part (subseq parts count) root)
              (setf root (namestring
                          (merge-pathnames part
                                           (store-directory-pathname root))))))))))

#+sbcl
(defun store-fsync-directory (directory)
  (unless (store-secure-directory-p directory)
    (error "Store directory is not private: ~A" directory))
  (let ((fd (sb-posix:open (store-absolute-path directory)
                           (logior sb-posix:o-rdonly sb-posix:o-directory
                                   sb-posix:o-nofollow))))
    (unwind-protect (sb-posix:fsync fd)
      (sb-posix:close fd))))

(defun store-delete-temp (path)
  #+sbcl
  (let ((parent (directory-namestring (pathname (store-absolute-path path)))))
    (when (store-secure-directory-p parent)
      (ignore-errors (sb-posix:unlink (store-absolute-path path)))))
  #-sbcl (when (probe-file path) (delete-file path)))

#+sbcl
(defun store-write-fd-all (fd bytes)
  (loop with offset = 0
        while (< offset (length bytes)) do
          (let ((chunk (if (zerop offset) bytes (subseq bytes offset))))
            (sb-sys:with-pinned-objects (chunk)
              (let ((written (sb-posix:write fd (sb-sys:vector-sap chunk)
                                             (length chunk))))
                (when (<= written 0) (error "Store write made no progress"))
                (incf offset written))))))

(defvar *store-crash-spec-read-p* nil)
(defvar *store-crash-spec* nil)
(defvar *store-crash-counters*
  (list (cons "before" 0)
        (cons "mid" 0)
        (cons "pre-rename" 0)
        (cons "post-rename" 0)))

(defun store-crash-spec ()
  (unless *store-crash-spec-read-p*
    (setf *store-crash-spec-read-p* t
          *store-crash-spec*
          #+sbcl
          (let ((value (sb-ext:posix-getenv "PP_CRASH_AT")))
            (when value
              (let ((separator (cl:position #\: value)))
                (when (and separator
                           (plusp separator)
                           (< separator (1- (length value)))
                           (not (cl:position #\: value :start (1+ separator))))
                  (let ((boundary (subseq value 0 separator))
                        (count-text (subseq value (1+ separator))))
                    (when (member boundary
                                  '("before" "mid" "pre-rename" "post-rename")
                                  :test #'string=)
                      (handler-case
                          (let ((count (parse-integer count-text)))
                            (when (plusp count)
                              (cons boundary count)))
                        (error () nil))))))))
          #-sbcl nil))
  *store-crash-spec*)

(defun store-crash-boundary (boundary)
  (let ((entry (assoc boundary *store-crash-counters* :test #'string=)))
    (when entry
      (incf (cdr entry))
      #+sbcl
      (let ((spec (store-crash-spec)))
        (when (and spec
                   (string= boundary (car spec))
                   (= (cdr entry) (cdr spec)))
          (sb-posix:kill (sb-posix:getpid) sb-posix:sigkill))))))

#+sbcl
(defun store-secure-file-fd (path flags &optional (mode #o600))
  (let ((fd (sb-posix:open (store-absolute-path path)
                           (logior flags sb-posix:o-nofollow) mode)))
    (handler-case
        (let ((stat (sb-posix:fstat fd)))
          (unless (= (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt)
                     sb-posix:s-ifreg)
            (error "Store path is not a regular file: ~A" path))
          ;; Never change permissions on an existing input file.  Newly
          ;; created lock files are private by construction and may be
          ;; tightened after opening.
          (when (logtest sb-posix:o-creat flags)
            (sb-posix:fchmod fd #o600))
          fd)
      (error (condition)
        (sb-posix:close fd)
        (error condition)))))
#+sbcl
(defun store-secure-directory-p (directory)
  (handler-case
      (let* ((absolute (namestring
                        (store-directory-pathname (store-absolute-path directory))))
             (stat (sb-posix:lstat absolute)))
        (and (= (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt)
                sb-posix:s-ifdir)
             (string= absolute (namestring (truename absolute)))))
    (error () nil)))


;;; Random names come from the OS, never from the saved image's repeatable
;;; PRNG: two pp processes start from identical random state, so PRNG-derived
;;; temp names collide deterministically.  Creation stays O_EXCL so
;;; uniqueness is an OS guarantee rather than a probability.
#+sbcl
(defun store-random-hex (octet-count)
  (let ((bytes (make-array octet-count :element-type '(unsigned-byte 8))))
    (with-open-file (stream "/dev/urandom" :direction :input
                            :element-type '(unsigned-byte 8))
      (unless (= (read-sequence bytes stream) octet-count)
        (error "unable to read secure random bytes")))
    (string-downcase
     (with-output-to-string (output)
       (loop for byte across bytes do (format output "~2,'0X" byte))))))

#+sbcl
(defun store-exclusive-temp-name (directory prefix suffix)
  "Return a freshly created regular file in DIRECTORY; the caller owns it."
  (let ((directory
          (if (and (plusp (length directory))
                   (char= (char directory (1- (length directory))) #\/))
              directory
              (concatenate 'string directory "/"))))
    (loop
      (let ((candidate (merge-pathnames
                        (format nil "~A~A~A" prefix (store-random-hex 16) suffix)
                        (pathname directory))))
        (handler-case
            (progn
              (sb-posix:close
               (sb-posix:open (namestring candidate)
                              (logior sb-posix:o-wronly sb-posix:o-creat
                                      sb-posix:o-excl sb-posix:o-nofollow)
                              #o600))
              (return (namestring candidate)))
          (sb-posix:syscall-error () nil))))))

#+sbcl
(defun store-exclusive-directory (base prefix)
  "Create a fresh directory under BASE via mkdir(2), which refuses existing
names — mkdtemp semantics without a repeatable PRNG."
  (let ((base (if (char= (char base (1- (length base))) #\/)
                  base
                  (concatenate 'string base "/"))))
    (loop
      (let ((candidate (format nil "~A~A-~A/" base prefix (store-random-hex 16))))
        (handler-case
            (progn (sb-posix:mkdir candidate #o700) (return candidate))
          (sb-posix:syscall-error () nil))))))

#-sbcl
(defun store-exclusive-temp-name (directory prefix suffix)
  (loop
    (let ((candidate (merge-pathnames
                      (format nil "~A~A~A" prefix (write-to-string (get-universal-time)) suffix)
                      (pathname directory))))
      (unless (probe-file candidate)
        (with-open-file (stream candidate :direction :output :if-exists :error
                                          :if-does-not-exist :create)
          (return (namestring candidate)))))))

(defun store-atomic-write-octets (path bytes)
  "Write BYTES through an exclusive private temporary file, then publish."
  (let* ((target (store-absolute-path path))
         (directory (directory-namestring (pathname target)))
         (tmp (store-exclusive-temp-name directory ".pp-store-" ".tmp"))
         (octets (store-content-octets bytes))
         (fd nil) (published nil))
    #+sbcl
    (unwind-protect
         (progn
           (unless (store-secure-directory-p directory)
             (error "Store parent is not a private directory: ~A" directory))
           (store-crash-boundary "before")
           ;; The temp already exists (created exclusively above); open it
           ;; for writing without re-creating.
           (setf fd (sb-posix:open tmp sb-posix:o-wronly #o600))
           (store-write-fd-all fd octets)
           (store-crash-boundary "mid")
           (sb-posix:fsync fd)
           (sb-posix:close fd)
           (setf fd nil)
           ;; Recheck immediately before publication.  SBCL does not expose
           ;; renameat, so this is the strongest directory confinement check
           ;; available without a native helper.
           (unless (store-secure-directory-p directory)
             (error "Store parent changed during write: ~A" directory))
           (store-crash-boundary "pre-rename")
           (sb-posix:rename tmp target)
           (store-crash-boundary "post-rename")
           (store-fsync-directory directory)
           (setf published t))
      (when fd (sb-posix:close fd))
      (unless published (store-delete-temp tmp)))
    #-sbcl
    (unwind-protect
         (progn
           (store-crash-boundary "before")
           (with-open-file (stream tmp :direction :output
                                   :element-type '(unsigned-byte 8)
                                   :if-exists :error :if-does-not-exist :create)
             (write-sequence octets stream)
             (store-crash-boundary "mid")
             (finish-output stream))
           (store-crash-boundary "pre-rename")
           (rename-file tmp target)
           (store-crash-boundary "post-rename")
           (setf published t))
      (unless published (store-delete-temp tmp)))))


(defun store-atomic-replace (path content)
  (store-atomic-write-octets path (store-content-octets content)))

(defun store-read-octets (path)
  #+sbcl
  (let ((fd nil))
    (unwind-protect
         (handler-case
             (progn
               (setf fd (store-secure-file-fd path sb-posix:o-rdonly))
               (let* ((size (sb-posix:stat-size (sb-posix:fstat fd)))
                      (bytes (make-array size :element-type '(unsigned-byte 8)))
                      (stream (sb-sys:make-fd-stream
                               fd :input t :output nil
                               :element-type '(unsigned-byte 8)
                               :buffering :none)))
                 (setf fd nil)
                 (unwind-protect (progn (read-sequence bytes stream) bytes)
                   (close stream))))
           (file-error () nil)
           (sb-posix:syscall-error () nil)
           (end-of-file () nil))
      (when fd (sb-posix:close fd))))
  #-sbcl
  (handler-case
      (with-open-file (stream path :direction :input
                              :element-type '(unsigned-byte 8))
        (let ((bytes (make-array (file-length stream)
                                 :element-type '(unsigned-byte 8))))
          (read-sequence bytes stream) bytes))
    (file-error () nil) (end-of-file () nil)))

(defun store-read-text (path)
  (let ((bytes (store-read-octets path)))
    (and bytes (handler-case (store-octets-string bytes)
                 (error () nil)))))

(defun store-ensure-directory (directory)
  #+sbcl
  ;; Resolve symlinked ancestors (macOS TMPDIR=/var/folders, where
  ;; /var -> private/var) to their real path first: the per-component walk
  ;; below then checks only components pp created or verified, while a
  ;; symlink swapped in later still fails the namestring vs truename
  ;; comparison and O_NOFOLLOW at open.
  (let* ((absolute (store-absolute-path (store-canonical-path directory)))
         (pathname (store-directory-pathname absolute))
         (parts (cdr (pathname-directory pathname)))
         (seen nil))
    (dolist (part parts)
      (push part seen)
      (let ((current (make-pathname :directory (cons :absolute (reverse seen))
                                    :name nil :type nil :defaults pathname)))
        (unless (probe-file current)
          (handler-case (sb-posix:mkdir (namestring current) #o700)
            (error () (unless (probe-file current)
                        (error "Cannot create store directory ~A" current))))
          (store-fsync-directory
           (make-pathname :directory (cons :absolute (butlast (reverse seen)))
                          :name nil :type nil :defaults pathname)))
        (let ((stat (sb-posix:lstat (namestring current))))
          (unless (and (= (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt)
                         sb-posix:s-ifdir)
                       (string= (namestring current)
                                (namestring (truename current))))
            (error "Store directory contains a symlink or non-directory: ~A"
                   current)))))
    (let ((fd (sb-posix:open absolute
                             (logior sb-posix:o-rdonly sb-posix:o-directory
                                     sb-posix:o-nofollow))))
      (unwind-protect (progn (sb-posix:fchmod fd #o700) (sb-posix:fsync fd))
        (sb-posix:close fd))))
  #-sbcl (ensure-directories-exist
          (merge-pathnames "dummy" (store-directory-pathname directory)))
  directory)

(defun store-valid-name-p (name)
  (and (stringp name) (plusp (length name))
       (not (member name '("." "..") :test #'string=))
       (not (find #\/ name)) (not (find #\Null name))))

(defun store-split-lines (text)
  (let ((lines nil) (start 0))
    (loop for end = (cl:position #\Newline text :start start)
          do (if end
                 (progn (push (subseq text start end) lines)
                        (setf start (1+ end)))
                 (return (nreverse (cons (subseq text start) lines)))))))

(defparameter +store-version+ (format nil "pp-store 2~%"))

#+sbcl
(defun store-layout-read-root-identity (root)
  (let ((stat (sb-posix:lstat root)))
    (unless (= (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt)
               sb-posix:s-ifdir)
      (error "Store root is not a directory: ~A" root))
    (unless (string= (namestring (store-directory-pathname root))
                     (namestring (truename root)))
      (error "Store root must not be a symlink: ~A" root))
    (cons (sb-posix:stat-dev stat) (sb-posix:stat-ino stat))))

(defstruct (store-layout (:constructor %make-store-layout (root root-identity)))
  (root "" :type string) root-identity)

(defun make-store-layout (root)
  (let ((canonical (store-canonical-path root)))
    (%make-store-layout canonical
                        #+sbcl (and (probe-file canonical)
                                    (store-layout-read-root-identity canonical))
                        #-sbcl nil)))
(defun store-layout-of-root (root) (make-store-layout root))

(defun store-layout-check-root (layout)
  #+sbcl
  (if (probe-file (store-layout-root layout))
      (let ((current (store-layout-read-root-identity
                      (store-layout-root layout))))
        (if (store-layout-root-identity layout)
            (unless (equal (store-layout-root-identity layout) current)
              (error "Store root changed while repository was open: ~A"
                     (store-layout-root layout)))
            (setf (store-layout-root-identity layout) current)))
      (when (store-layout-root-identity layout)
        (error "Store root disappeared while repository was open: ~A"
               (store-layout-root layout))))
  layout)
(defun store-layout-path (layout area name)
  (unless (store-valid-name-p name) (error "Store path must be one name"))
  ;; Validate the area on every access so reads cannot follow a replaced
  ;; area directory between lifecycle checks.
  (store-layout-ensure-area layout area)
  (store-layout-check-root layout)
  (namestring (merge-pathnames name
                               (store-directory-pathname
                                (store-layout-area layout area)))))

(defun store-layout-area-name (area)
  (ecase area
    ((:objects objects) "objects") ((:traces traces) "traces")
    ((:blobs blobs) "blobs") ((:fenced-specs fenced-specs) "fenced-specs")
    ((:procs procs) "procs") ((:locks locks) "locks")))
(defun store-layout-area (layout area)
  (store-layout-check-root layout)
  (store-directory-pathname
   (merge-pathnames (store-layout-area-name area)
                    (store-directory-pathname (store-layout-root layout)))))


(defun store-layout-ensure-area (layout area)
  (let ((directory (store-layout-area layout area)))
    (store-ensure-directory directory)
    #+sbcl
    (let* ((directory (store-directory-pathname (store-layout-area layout area)))
           (stat (sb-posix:lstat (namestring directory))))
      (unless (and (= (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt)
                      sb-posix:s-ifdir)
                   (string= (namestring directory)
                            (namestring (truename directory))))
        (error "Store area contains a symlink or non-directory: ~A" directory)))
    directory))

#+sbcl
(defun store-layout-regular-file-p (path)
  (handler-case
      (let ((fd (store-secure-file-fd path sb-posix:o-rdonly)))
        (sb-posix:close fd) t)
    (error () nil)))

(defun store-directory-entries (directory)
  ;; SBCL's "*" pattern omits names with a type; include both forms so
  ;; generated .tmp files are cleaned along with extensionless records.
  (remove-duplicates
   (append (directory (merge-pathnames "*"
                                       (store-directory-pathname directory)))
           (directory (merge-pathnames "*.*"
                                       (store-directory-pathname directory))))
   :test #'string= :key #'namestring))

(defun store-layout-list-names (layout area)
  (mapcar #'file-namestring (store-layout-list layout area)))
(defun store-layout-list (layout area)
  (store-layout-ensure-area layout area)
  (let ((directory (store-layout-area layout area)))
    (mapcar #'namestring
            (remove-if-not
             #+sbcl #'store-layout-regular-file-p
             #-sbcl (lambda (path) (declare (ignore path)) t)
             (store-directory-entries directory)))))
(defun store-layout-remove (path)
  #+sbcl
  (when (probe-file path)
    (let ((parent (directory-namestring (pathname (store-absolute-path path)))))
      (unless (store-secure-directory-p parent)
        (error "Store parent is not a private directory: ~A" parent))
      (sb-posix:unlink (store-absolute-path path))))
  #-sbcl (when (probe-file path) (delete-file path)))
(defun store-layout-clear-dir (directory)
  (when (probe-file directory)
    #+sbcl
    (unless (store-secure-directory-p directory)
      (error "Store area is not a private directory: ~A" directory))
    (dolist (path (store-directory-entries directory))
      (store-layout-remove path))))
(defun store-temp-file-p (path)
  (let* ((name (file-namestring path))
         (length (length name)))
    (or (and (>= length 4)
             (string= name ".tmp" :start1 (- length 4)))
        (search ".tmp." name)
        (search ".pp-tmp." name))))
(defun store-layout-clear-temp-files (directory)
  (when (probe-file directory)
    #+sbcl
    (unless (store-secure-directory-p directory)
      (error "Store area is not a private directory: ~A" directory))
    (dolist (path (store-directory-entries directory))
      (when (and (probe-file path) (store-temp-file-p path))
        (store-layout-remove path)))))

(defun store-layout-read-store (layout area name)
  (store-read-octets (store-layout-path layout area name)))

(defun store-layout-init (layout)
  (store-ensure-directory (store-layout-root layout))
  (store-layout-check-root layout)
  ;; A fresh store has only the two eager repositories.  Other areas are
  ;; created by the operation that first needs them.
  (dolist (area '(:objects :traces))
    (store-layout-ensure-area layout area))
  (store-layout-clear-temp-files (store-layout-root layout))
  (dolist (area '(:objects :traces :blobs :fenced-specs :procs :locks))
    (let ((directory (store-layout-area layout area)))
      (when (probe-file directory)
        (store-layout-clear-temp-files directory))))
  (let* ((version-path (merge-pathnames "VERSION"
                                        (store-directory-pathname
                                         (store-layout-root layout))))
         (current (store-read-octets version-path))
         (versioned '(:objects :traces :fenced-specs :procs)))
    (unless (and current (equalp current (store-string-octets +store-version+)))
      (when (some (lambda (area)
                    (and (probe-file (store-layout-area layout area))
                         (store-layout-list-names layout area)))
                  versioned)
        (dolist (area versioned)
          (store-layout-ensure-area layout area)
          (store-layout-clear-dir (store-layout-area layout area))))
      (store-atomic-replace version-path +store-version+)))
  layout)
(defun store-lock-fd (stream)
  #+sbcl (sb-sys:fd-stream-fd stream)
  #-sbcl (declare (ignore stream)))
(defun store-with-lock (path thunk &key (exclusive t))
  (declare (ignore exclusive))
  (store-ensure-directory (directory-namestring (pathname path)))
  #+sbcl
  (let ((fd (store-secure-file-fd path (logior sb-posix:o-rdwr sb-posix:o-creat)
                                  #o600))
        (locked nil))
    (unwind-protect
         (progn (sb-posix:lockf fd sb-posix:f-lock 0)
                (setf locked t) (funcall thunk))
      (when locked (sb-posix:lockf fd sb-posix:f-ulock 0))
      (sb-posix:close fd)))
  #-sbcl (with-open-file (stream path :direction :io :if-does-not-exist :create)
           (funcall thunk)))
(defun store-layout-with-lifecycle (layout thunk &key (exclusive t))
  (store-layout-check-root layout)
  (store-layout-ensure-area layout :locks)
  (store-with-lock (store-layout-path layout :locks "lifecycle")
                   (lambda () (store-layout-check-root layout) (funcall thunk))
                   :exclusive exclusive))
(defun store-layout-with-lifecycle-read (layout thunk)
  (store-layout-with-lifecycle layout thunk :exclusive nil))
(defun store-layout-with-lifecycle-write (layout thunk)
  (store-layout-with-lifecycle layout thunk :exclusive t))

(defstruct (object-repository (:constructor %make-object-repository (layout))) layout)
(defun make-object-repository (layout) (%make-object-repository layout))
(defun object-repository-create (layout) (make-object-repository layout))
(defun object-repository-write (repository area key value)
  (object-repository-put-verified repository area key value))

(defun object-repository-put-verified (repository area key value)
  (let* ((name (store-identity-string key))
         (encoded (pp.kernel:encode-value value)))
    (unless (and (store-digest-p name) encoded
                 (string= name (pp.kernel:hash-value value)))
      (error "Object key does not match canonical value"))
    (store-layout-ensure-area (object-repository-layout repository) area)
    (let ((path (store-layout-path (object-repository-layout repository) area name))
          (bytes (store-string-octets encoded)))
      (let ((old (store-read-octets path)))
        (unless (and old (equalp old bytes))
          (store-atomic-write-octets path bytes))))
    name))
(defun object-repository-put (repository &key key value)
  (object-repository-put-verified repository :objects
                                  (store-identity-string key) value))
(defun object-repository-put-fenced (repository &key hash value)
  (object-repository-put-verified repository :fenced-specs
                                  (store-identity-string hash) value))

(defun object-repository-get-verified (repository area key)
  (let* ((name (store-identity-string key))
         (content (and (store-digest-p name)
                       (store-read-octets
                        (store-layout-path (object-repository-layout repository)
                                           area name)))))
    (when content
      (handler-case
          (multiple-value-bind (text raw)
              (handler-case (values (store-octets-string content) nil)
                (error () (values (store-codec-octets-string content) t)))
            (let* ((value (pp.kernel:decode-value text))
                   (encoded (and value (pp.kernel:encode-value value)))
                   (encoded-bytes (and encoded
                                       (if raw
                                           (store-codec-string-octets encoded)
                                           (store-string-octets encoded))))
                   (hash (and value
                              (if raw (store-codec-hash-value value)
                                  (pp.kernel:hash-value value)))))
              (when (and value encoded-bytes (string= hash name)
                         (equalp encoded-bytes content))
                value)))
        (error () nil)))))
(defun object-repository-get (repository &key key)
  (object-repository-get-verified repository :objects (store-identity-string key)))
(defun object-repository-get-fenced (repository &key hash)
  (object-repository-get-verified repository :fenced-specs
                                  (store-identity-string hash)))
(defun object-repository-keys (repository)
  (store-layout-list-names (object-repository-layout repository) :objects))

(defstruct (blob-repository (:constructor %make-blob-repository (layout))) layout)
(defun make-blob-repository (layout) (%make-blob-repository layout))
(defun blob-repository-create (layout) (make-blob-repository layout))
(defun blob-repository-put (repository content)
  (let* ((bytes (store-content-octets content))
         (hash (store-hash-octets bytes))
         (layout (blob-repository-layout repository)))
    (store-layout-ensure-area layout :blobs)
    (let ((path (store-layout-path layout :blobs hash))
          (old (store-read-octets (store-layout-path layout :blobs hash))))
      (unless (and old (equalp old bytes)) (store-atomic-write-octets path bytes)))
    hash))
(defun blob-repository-get (repository hash)
  (let* ((name (store-identity-string hash))
         (bytes (and (store-digest-p name)
                     (store-read-octets
                      (store-layout-path (blob-repository-layout repository)
                                         :blobs name)))))
    (and bytes (string= (store-hash-octets bytes) name) bytes)))
(defun blob-repository-get-string (repository hash)
  (let ((bytes (blob-repository-get repository hash)))
    (and bytes (store-octets-string bytes))))
(defun blob-repository-keys (repository)
  (remove-if-not #'store-digest-p
                 (store-layout-list-names (blob-repository-layout repository)
                                          :blobs)))

(defstruct (store-trace (:constructor make-store-trace (outcome result-hash reads)))
  outcome result-hash reads)
(defstruct (trace-repository (:constructor %make-trace-repository (layout))) layout)
(defun make-trace-repository (layout) (%make-trace-repository layout))
(defun trace-repository-create (layout) (make-trace-repository layout))
(defun store-trace-outcome-ok-p (outcome)
  (or (eq outcome :ok) (eq outcome 'ok) (and (stringp outcome) (string= outcome "ok"))))
(defun store-trace-outcome-failed-p (outcome)
  (or (eq outcome :failed) (eq outcome 'failed)
      (and (stringp outcome) (string= outcome "failed"))))
(defun store-trace-outcome-name (outcome)
  (cond ((store-trace-outcome-ok-p outcome) "ok")
        ((store-trace-outcome-failed-p outcome) "failed")
        (t (error "Unknown trace outcome"))))
(defun store-trace-read-cell (read) (car read))
(defun store-trace-read-hash (read) (cdr read))
(defun store-trace-read-fields (read)
  (values (store-identity-string (store-trace-read-cell read))
          (store-identity-string (store-trace-read-hash read))))

(defun trace-repository-to-line (trace)
  (with-output-to-string (out)
    (format out "(trace ~A ~A ("
            (store-trace-outcome-name (store-trace-outcome trace))
            (pp.kernel:quote-string
             (store-identity-string (store-trace-result-hash trace))))
    (loop for read in (store-trace-reads trace)
          for first = t then nil do
      (multiple-value-bind (cell hash) (store-trace-read-fields read)
        (unless (and (store-digest-p hash)
                     (handler-case
                         (let ((parsed (pp.kernel:parse-cell cell)))
                           (string= (pp.kernel:cell-serialize parsed) cell))
                       (error () nil)))
          (error "Invalid trace read"))
        (unless first (write-char #\Space out))
        (format out "(~A . ~A)" (pp.kernel:quote-string cell)
                (pp.kernel:quote-string hash))))
    (write-string "))" out)))

(defun store-trace-parse-quoted (line position)
  (pp.kernel:parse-quoted-string line position))
(defun store-trace-prefix (line position literal)
  (and (<= (+ position (length literal)) (length line))
       (string= line literal :start1 position
                :end1 (+ position (length literal)))
       (+ position (length literal))))

(defun trace-repository-of-line (line)
  (when (stringp line)
    (handler-case
        (block invalid
          (when (or (find #\Return line) (find #\Newline line))
            (return-from invalid nil))
          (let* ((length (length line))
                 (at (store-trace-prefix line 0 "(trace "))
                 outcome)
            (unless at (return-from invalid nil))
            (cond ((store-trace-prefix line at "ok ")
                   (setf at (store-trace-prefix line at "ok ")
                         outcome :ok))
                  ((store-trace-prefix line at "failed ")
                   (setf at (store-trace-prefix line at "failed ")
                         outcome :failed))
                  (t (return-from invalid nil)))
            (multiple-value-bind (result next)
                (store-trace-parse-quoted line at)
              (unless (and result (store-digest-p result)
                           (setf at (store-trace-prefix line next " (")))
                (return-from invalid nil))
              (let ((reads nil))
                (loop
                  (when (>= at length)
                    (return-from invalid nil))
                  (cond
                    ((char= (char line at) #\))
                     (incf at)
                     (return))
                    ((char= (char line at) #\()
                     (incf at)
                     (multiple-value-bind (cell p1)
                         (store-trace-parse-quoted line at)
                       (unless (and cell
                                    (setf at
                                          (store-trace-prefix line p1 " . ")))
                         (return-from invalid nil))
                       (multiple-value-bind (hash p2)
                           (store-trace-parse-quoted line at)
                         (unless (and hash (< p2 length)
                                      (char= (char line p2) #\)))
                           (return-from invalid nil))
                         (unless
                             (and (store-digest-p hash)
                                  (ignore-errors
                                    (let ((parsed (pp.kernel:parse-cell cell)))
                                      (string= (pp.kernel:cell-serialize parsed)
                                               cell))))
                           (return-from invalid nil))
                         (push (cons (pp.kernel:cell-id-of-string cell)
                                     (pp.kernel:observed-hash-of-digest hash))
                               reads)
                         (setf at (1+ p2))
                         (cond ((= at length)
                                (return-from invalid nil))
                               ((char= (char line at) #\Space)
                                (incf at))
                               ((char= (char line at) #\))
                                nil)
                               (t (return-from invalid nil))))))
                    (t (return-from invalid nil))))
                (unless (and (< at length) (char= (char line at) #\)))
                  (return-from invalid nil))
                (incf at)
                (let ((trace (make-store-trace
                              outcome (pp.kernel:object-hash-of-digest result)
                              (nreverse reads))))
                  (and (= at length)
                       (string= (trace-repository-to-line trace) line)
                       trace))))))
      (error () nil))))

(defun trace-repository-load (repository &key key)
  (let* ((name (store-identity-string key))
         (bytes (store-read-octets
                 (store-layout-path (trace-repository-layout repository)
                                    :traces name))))
    (when (and bytes (plusp (length bytes))
               (= (aref bytes (1- (length bytes))) (char-code #\Newline)))
      (let ((text (handler-case (store-octets-string bytes) (error () nil))))
        (when text
          (loop for line in (store-split-lines text)
                for trace = (and (plusp (length line))
                                 (trace-repository-of-line line))
                when trace collect trace))))))
(defun store-trace-equal-p (left right)
  (and (string= (store-trace-outcome-name (store-trace-outcome left))
                (store-trace-outcome-name (store-trace-outcome right)))
       (string= (store-identity-string (store-trace-result-hash left))
                (store-identity-string (store-trace-result-hash right)))
       (= (length (store-trace-reads left)) (length (store-trace-reads right)))
       (every (lambda (pair)
                (find pair (store-trace-reads right)
                      :test (lambda (a b)
                              (and (string= (store-identity-string (car a))
                                            (store-identity-string (car b)))
                                   (string= (store-identity-string (cdr a))
                                            (store-identity-string (cdr b)))))))
              (store-trace-reads left))))
(defun trace-repository-put (repository &key key outcome result-hash reads)
  (let* ((layout (trace-repository-layout repository))
         (name (store-identity-string key))
         (trace (make-store-trace outcome (store-identity-string result-hash) reads))
         (path (store-layout-path layout :traces name)))
    (unless (and (store-digest-p name) (store-digest-p (store-identity-string result-hash)))
      (error "Invalid trace key"))
    (store-layout-ensure-area layout :traces)
    (store-with-lock (store-layout-path layout :locks name)
      (lambda ()
        (let ((existing (trace-repository-load repository :key name)))
          (unless (find trace existing :test #'store-trace-equal-p)
            (store-atomic-replace
             path (with-output-to-string (out)
                   (dolist (item (append existing (list trace)))
                     (write-string (trace-repository-to-line item) out)
                     (write-char #\Newline out))))))))))
(defun trace-repository-keys (repository)
  (mapcar #'pp.kernel:cache-key-of-string
          (remove-if-not #'store-digest-p
                         (store-layout-list-names
                          (trace-repository-layout repository) :traces))))

(defstruct (cell-repository (:constructor %make-cell-repository (layout blobs)))
  layout blobs)
(defun make-cell-repository (layout &optional blobs)
  (%make-cell-repository layout (or blobs (make-blob-repository layout))))
(defun cell-repository-create (layout &optional blobs)
  (make-cell-repository layout blobs))
(defun cell-repository-read-raw (repository path)
  (declare (ignore repository))
  (or (store-read-octets path) (error "Store read failed: ~A" path)))
(defun cell-repository-read-file (repository path &key pin-lookup pin-store record)
  (let* ((canonical (store-canonical-path path))
         (cell-id (pp.kernel:cell-serialize (pp.kernel:make-cell-file canonical)))
         (pinned (and pin-lookup (funcall pin-lookup cell-id)))
         (bytes (and pinned
                     (blob-repository-get (cell-repository-blobs repository) pinned))))
    (unless bytes
      (setf bytes (cell-repository-read-raw repository canonical))
      (let ((hash (blob-repository-put (cell-repository-blobs repository) bytes)))
        (when pin-store (funcall pin-store cell-id hash))
        (setf pinned hash)))
    (when record (funcall record cell-id pinned))
    bytes))
(defun cell-repository-read-sealed (repository path &key pin-lookup pin-store record)
  (let* ((canonical (store-canonical-path path))
         (cell-id (pp.kernel:cell-serialize (pp.kernel:make-cell-sealed canonical)))
         (bytes (and pin-lookup (funcall pin-lookup cell-id))))
    (unless bytes
      (setf bytes (cell-repository-read-raw repository canonical))
      (when pin-store (funcall pin-store cell-id bytes)))
    (when record (funcall record cell-id (store-hash-content bytes)))
    bytes))

(defstruct (store-inventory-entry
            (:constructor make-store-inventory-entry (id modified size)))
  id modified size)
(defun store-inventory-area (kind)
  (ecase kind
    ((:object object :objects objects) :objects)
    ((:trace trace :traces traces) :traces)
    ((:blob blob :blobs blobs) :blobs)
    ((:fenced-spec fenced-spec :fenced-specs fenced-specs) :fenced-specs)))
(defun store-inventory-entries (layout kind)
  (let ((area (store-inventory-area kind)))
    (mapcar (lambda (name)
              (let ((path (store-layout-path layout area name)))
                (make-store-inventory-entry
                 name (ignore-errors (file-write-date path))
                 (length (or (store-read-octets path)
                             (error "Store inventory read failed: ~A" path))))))
            (store-layout-list-names layout area))))
(defun store-inventory-remove (layout kind id)
  (store-layout-remove (store-layout-path layout (store-inventory-area kind)
                                          (store-identity-string id))))

(defun store-index-reverse (trace-repository)
  (let ((result (make-hash-table :test #'equal)))
    (dolist (key (trace-repository-keys trace-repository) result)
      (dolist (trace (trace-repository-load trace-repository :key key))
        (dolist (read (store-trace-reads trace))
          (let ((cell (store-identity-string (car read)))
                (key-text (store-identity-string key)))
            (pushnew key-text (gethash cell result) :test #'string=)))))))
(defun store-index-dirty-keys (changed reverse dependency-cells)
  (labels ((visit (seen cells)
             (if (null cells) seen
                 (let* ((cell (car cells))
                        (keys (gethash cell reverse))
                        (fresh (remove-if (lambda (key)
                                            (member key seen :test #'string=)) keys)))
                   (visit (append fresh seen)
                          (append (mapcan dependency-cells fresh)
                                  (cdr cells)))))))
    (sort (remove-duplicates (visit nil changed) :test #'string=) #'string<)))

(defstruct (store-gc-root (:constructor make-store-gc-root (hash nodes)))
  hash nodes)
(defun gc-roots-path (layout)
  (namestring (merge-pathnames "gc-roots"
                               (store-directory-pathname (store-layout-root layout)))))
(defun gc-roots-root-value (root)
  (pp.kernel:make-vmap
   (list (cons (pp.kernel:make-vkeyword "hash")
               (pp.kernel:make-vstring (store-identity-string
                                        (store-gc-root-hash root))))
         (cons (pp.kernel:make-vkeyword "nodes")
               (pp.kernel:make-vvector
                (coerce (mapcar (lambda (node)
                                  (pp.kernel:make-vstring
                                   (store-identity-string node)))
                                (store-gc-root-nodes root))
                        'vector))))))
(defun gc-root-field (entries name)
  (let ((matches (remove-if-not
                  (lambda (entry)
                    (let ((key (car entry)))
                      (and (typep key 'pp.kernel:value-keyword)
                           (string= (pp.kernel:value-keyword-value key) name))))
                  entries)))
    (when (= (length matches) 1) (cdr (first matches)))))
(defun gc-roots-value-root (value)
  (when (typep value 'pp.kernel:value-map)
    (let ((entries (pp.kernel:value-map-entries value)))
      (when (= (length entries) 2)
        (let ((hash (gc-root-field entries "hash"))
              (nodes (gc-root-field entries "nodes")))
          (when (and (typep hash 'pp.kernel:value-string)
                     (store-digest-p (pp.kernel:value-string-value hash))
                     (typep nodes 'pp.kernel:value-vector))
            (let ((node-values nil))
              (loop for item across (pp.kernel:value-vector-values nodes)
                    do (unless (typep item 'pp.kernel:value-string)
                         (return-from gc-roots-value-root nil))
                       (let* ((text (pp.kernel:value-string-value item))
                              (parsed (handler-case
                                          (pp.kernel:node-key-of-string text)
                                        (error () nil))))
                         (unless (and parsed (store-digest-p text)
                                      (string= text
                                               (pp.kernel:node-key-to-string parsed)))
                           (return-from gc-roots-value-root nil))
                         (push parsed node-values)))
              (make-store-gc-root
               (pp.kernel:value-string-value hash)
               (nreverse node-values)))))))))
(defun gc-roots-read-all (layout)
  (let ((bytes (store-read-octets (gc-roots-path layout))))
    (if (null bytes)
        nil
        (progn
          (unless (and (plusp (length bytes))
                       (= (aref bytes (1- (length bytes))) (char-code #\Newline)))
            (error "gc-roots must end with LF"))
          (let ((text (or (handler-case (store-octets-string bytes)
                            (error () nil))
                          (error "Malformed gc-roots bytes")))
                (lines nil))
            (setf lines (store-split-lines text))
            (when (and lines (zerop (length (car (last lines)))))
              (setf lines (butlast lines)))
            (mapcar (lambda (line)
                      (when (zerop (length line))
                        (error "Malformed gc-root record"))
                      (let* ((value (or (pp.kernel:decode-value line)
                                        (error "Malformed gc-root record")))
                             (root (or (gc-roots-value-root value)
                                       (error "Noncanonical gc-root record")))
                             (encoded (or (pp.kernel:encode-value value)
                                          (error "Non-data gc-root record"))))
                        (unless (string= encoded line)
                          (error "Noncanonical gc-root record"))
                        root))
                    lines))))))
(defun store-gc-root-equal-p (left right)
  (and (string= (store-identity-string (store-gc-root-hash left))
                (store-identity-string (store-gc-root-hash right)))
       (equal
        (mapcar #'store-identity-string (store-gc-root-nodes left))
        (mapcar #'store-identity-string (store-gc-root-nodes right)))))

(defun gc-roots-record (layout root &key (keep 0))
  (unless (and (typep root 'store-gc-root)
               (store-digest-p (store-identity-string (store-gc-root-hash root)))
               (every (lambda (node)
                        (let ((text (store-identity-string node)))
                          (and (store-digest-p text)
                               (handler-case
                                   (string= text (pp.kernel:node-key-to-string
                                                  (pp.kernel:node-key-of-string text)))
                                 (error () nil)))))
                      (store-gc-root-nodes root)))
    (error "Invalid GC root"))
  (store-layout-with-lifecycle-write
   layout
   (lambda ()
     (let* ((previous (gc-roots-read-all layout))
            (roots (append previous (list root)))
            (kept (if (and (> keep 0) (> (length roots) keep))
                      (subseq roots (- (length roots) keep)) roots)))
       (store-atomic-replace
        (gc-roots-path layout)
        (with-output-to-string (out)
          (dolist (item kept)
            (write-string (pp.kernel:encode-value (gc-roots-root-value item)) out)
            (write-char #\Newline out))))))))

(defun store-codec-hash-concat (parts)
  (let ((out (make-array 0 :element-type '(unsigned-byte 8)
                         :adjustable t :fill-pointer 0)))
    (dolist (part parts)
      (let ((bytes (store-codec-string-octets part)))
        (loop for byte across (format nil "~D:" (length bytes))
              do (vector-push-extend (char-code byte) out))
        (loop for byte across bytes do (vector-push-extend byte out))))
    (store-hash-octets out)))
(defun store-codec-hash-value (value)
  (labels ((hv (active item)
             (if (member item active :test #'eq)
                 (store-codec-hash-concat
                  (list "recursive-value"
                        (format nil "~D" (cl:position item active :test #'eq))))
                 (hf (cons item active) item)))
           (hf (active item)
             (declare (ignore active))
             (typecase item
               (pp.kernel:value-nil (store-codec-hash-concat (list "nil")))
               (pp.kernel:value-bool (store-codec-hash-concat
                                      (list (if (pp.kernel:value-bool-value item)
                                                "bool:true" "bool:false"))))
               (pp.kernel:value-int (store-codec-hash-concat
                                     (list "int" (format nil "~D"
                                                          (pp.kernel:value-int-value item)))))
               (pp.kernel:value-float (store-codec-hash-concat
                                       (list "float" (pp.kernel:canonical-float-string
                                                       (pp.kernel:value-float-value item)))))
               (pp.kernel:value-string (store-codec-hash-concat
                                        (list "string" (pp.kernel:value-string-value item))))
               (pp.kernel:value-keyword (store-codec-hash-concat
                                         (list "keyword" (pp.kernel:value-keyword-value item))))
               (pp.kernel:value-symbol (store-codec-hash-concat
                                        (list "symbol" (pp.kernel:value-symbol-value item))))
               (pp.kernel:value-pair (store-codec-hash-concat
                                     (list "pair" (hv active (pp.kernel:value-pair-car item))
                                           (hv active (pp.kernel:value-pair-cdr item)))))
               (pp.kernel:value-vector (store-codec-hash-concat
                                        (cons "vector"
                                              (loop for child across
                                                  (pp.kernel:value-vector-values item)
                                                    collect (hv active child)))))
               (pp.kernel:value-map (store-codec-hash-concat
                                     (cons "map"
                                           (mapcar (lambda (entry)
                                                     (store-codec-hash-concat
                                                      (list (hv active (car entry))
                                                            (hv active (cdr entry)))))
                                                   (pp.kernel:canonical-map-entries
                                                    (pp.kernel:value-map-entries item))))))
               (pp.kernel:value-set (store-codec-hash-concat
                                     (cons "set"
                                           (sort (mapcar (lambda (child) (hv active child))
                                                         (pp.kernel:value-set-values item))
                                                 #'string<))))
               (t (error "Non-data value in codec record")))))
    (hv nil value)))

(defun store-default-reachable-blobs (value)
  (let ((found nil))
    (labels ((walk (item)
               (typecase item
                 (pp.kernel:value-string
                  (let ((text (pp.kernel:value-string-value item)))
                    (when (store-digest-p text)
                      (pushnew text found :test #'string=))))
                 (pp.kernel:value-pair (walk (pp.kernel:value-pair-car item))
                                       (walk (pp.kernel:value-pair-cdr item)))
                 (pp.kernel:value-vector
                  (loop for child across (pp.kernel:value-vector-values item)
                        do (walk child)))
                 (pp.kernel:value-map
                  (dolist (entry (pp.kernel:value-map-entries item))
                    (walk (car entry)) (walk (cdr entry))))
                 (pp.kernel:value-set
                  (dolist (child (pp.kernel:value-set-values item)) (walk child))))))
      (walk value))
    found))

(defun store-gc-mark-graph (roots trace-repository object-repository
                            &key reachable-blobs)
  (let ((live (make-hash-table :test #'equal))
        (visited (make-hash-table :test #'equal)))
    (labels ((mark-object (hash)
               (let ((name (store-identity-string hash)))
                 (unless (gethash (concatenate 'string "object:" name) live)
                   (setf (gethash (concatenate 'string "object:" name) live) t)
                   (let ((value (object-repository-get object-repository :key name)))
                     (dolist (blob (funcall (or reachable-blobs
                                                #'store-default-reachable-blobs)
                                            value))
                       (when (store-digest-p blob)
                         (setf (gethash (concatenate 'string "blob:" blob) live) t)))))))
             (mark-node (node)
               (let ((name (store-identity-string node)))
                 (unless (gethash name visited)
                   (setf (gethash name visited) t
                         (gethash (concatenate 'string "trace:" name) live) t)
                   (dolist (trace (trace-repository-load trace-repository :key name))
                     (mark-object (store-trace-result-hash trace))
                     (dolist (read (store-trace-reads trace))
                       (let ((cell (pp.kernel:cell-parse
                                    (store-identity-string (car read)))))
                         (typecase cell
                           (pp.kernel:cell-node
                            (mark-node (pp.kernel:node-key-of-string
                                        (pp.kernel:cell-node-value cell))))
                           (pp.kernel:cell-file
                            (let ((blob (store-identity-string (cdr read))))
                              (when (store-digest-p blob)
                                (setf (gethash (concatenate 'string "blob:" blob) live)
                                      t))))))))))))
      (dolist (root roots)
        (mark-object (store-gc-root-hash root))
        (dolist (node (store-gc-root-nodes root)) (mark-node node)))
    live)))

(defun store-gc-sweep (layout kind prefix live grace-seconds snapshot
                       &key snapshot-current)
  (let ((kept 0) (deleted 0) (aborted nil) (now (get-universal-time))
        (snapshot-current (or snapshot-current (lambda () snapshot))))
    (dolist (name (store-layout-list-names layout kind))
      (let ((path (store-layout-path layout kind name)))
        (if (gethash (concatenate 'string prefix name) live)
            (incf kept)
            (if (and (> grace-seconds 0)
                     (< (- now (or (file-write-date path) now)) grace-seconds))
                (incf kept)
                (let ((before (funcall snapshot-current)))
                  (if (equalp before snapshot)
                      (progn (store-layout-remove path) (incf deleted))
                      (setf aborted t)))))))
    (values kept deleted aborted)))

(defun store-gc-run (layout trace-repository object-repository
                     &key grace-seconds roots reachable-blobs snapshot-current)
  (let ((grace (or grace-seconds 2)))
    (store-layout-with-lifecycle-write
     layout
     (lambda ()
       (let ((roots (or roots (gc-roots-read-all layout))))
         (if (null roots)
             (list :objects (cons 0 0) :traces (cons 0 0)
                   :blobs (cons 0 0) :aborted nil)
             (let* ((live (store-gc-mark-graph roots trace-repository
                                               object-repository
                                               :reachable-blobs reachable-blobs))
                    (snapshot (or (and snapshot-current
                                       (funcall snapshot-current))
                                  (store-read-octets (gc-roots-path layout)))))
               (multiple-value-bind (objects-kept objects-deleted aborted1)
                   (store-gc-sweep layout :objects "object:" live grace snapshot
                                    :snapshot-current snapshot-current)
                 (multiple-value-bind (traces-kept traces-deleted aborted2)
                     (store-gc-sweep layout :traces "trace:" live grace snapshot
                                      :snapshot-current snapshot-current)
                   (multiple-value-bind (blobs-kept blobs-deleted aborted3)
                       (store-gc-sweep layout :blobs "blob:" live grace snapshot
                                        :snapshot-current snapshot-current)
                     (list :objects (cons objects-kept objects-deleted)
                           :traces (cons traces-kept traces-deleted)
                           :blobs (cons blobs-kept blobs-deleted)
                           :aborted (or aborted1 aborted2 aborted3))))))))))))

(defun runtime-store-with-repositories (layout callback)
  (let* ((objects (make-object-repository layout))
         (blobs (make-blob-repository layout))
         (traces (make-trace-repository layout))
         (cells (make-cell-repository layout blobs)))
    (funcall callback layout objects blobs traces cells)))
(defun runtime-store-put-node-result (objects traces key value outcome reads)
  (let ((hash (pp.kernel:hash-value value)))
    (object-repository-put objects :key hash :value value)
    (trace-repository-put traces :key (pp.kernel:cache-key-from-node-key key)
                          :outcome outcome :result-hash hash :reads reads)
    hash))
(defun runtime-store-load-node-traces (traces key)
  (trace-repository-load traces :key (pp.kernel:cache-key-from-node-key key)))
