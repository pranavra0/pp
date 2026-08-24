;;;; Islands: content-addressed modules with inline pins.
;;;;
;;;; An island is a module that lives elsewhere, referenced by URI and pinned
;;;; INLINE by the canonical content hash of its source tree:
;;;;
;;;;   island("file:./lib", "a1b2...64hex")
;;;;
;;;; The pin is part of the code (the island form hashes uri+pin), so island
;;;; identity is structural: no lockfile, no synthetic cell.  ~/.pp/islands
;;;; is a pure content-addressed cache:
;;;;
;;;;   index        — append-only resolution log (advisory, never authoritative)
;;;;   src/<pin>/   — immutable materialized tree; entry.pp is the module root
;;;;
;;;; Resolution NEVER touches the network.  Fetching (git:/github:) happens
;;;; only under --fetch-islands / --update.  An unpinned island form is a
;;;; hard error naming the fix: eval stays pure and hermetic; the only
;;;; impure step lives in `pp --update`.

(in-package #:pp.runtime)

(defvar *island-fetch-enabled* nil)
(defvar *island-update-mode* nil)

;;; ---- URI surface ----

(defun island-parse-uri (raw)
  "Return (values scheme locator ref-hint); scheme is one of :file :git :github."
  (labels ((split-ref (s)
             (let ((pos (cl:position #\# s)))
               (if pos
                   (values (subseq s 0 pos) (subseq s (1+ pos)))
                   (values s nil))))
           (make (scheme rest)
             (multiple-value-bind (locator ref-hint) (split-ref rest)
               (when (string= locator "")
                 (language-fail
                  (format nil "island: empty locator in URI: ~A" raw)
                  "runtime.island"))
               (values scheme locator ref-hint))))
    (cond ((string-starts-with-p raw "file:") (make :file (subseq raw 5)))
          ((string-starts-with-p raw "git:") (make :git (subseq raw 4)))
          ((string-starts-with-p raw "github:") (make :github (subseq raw 7)))
          (t (language-fail
              (format nil "island: unknown scheme in URI: ~A ~
(expected file:, git:, or github:)" raw)
              "runtime.island")))))

(defun string-starts-with-p (string prefix)
  (and (>= (length string) (length prefix))
       (string= string prefix :end1 (length prefix))))

;;; A pin is the 64-hex canonical tree hash — anything else in pin position
;;; is an error (refs go in the URI after '#').
(defun island-pin-p (s)
  (and (stringp s) (= (length s) 64)
       (every (lambda (c) (or (char<= #\0 c #\9) (char<= #\a c #\f))) s)))

(defun island-short (pin)
  (if (> (length pin) 12) (subseq pin 0 12) pin))

;;; ---- The content-addressed cache ----

(defun island-root ()
  ;; Deliberately NOT store-canonical-path: the cache is a plain HOME-derived
  ;; directory, and canonicalization mangles paths whose tail does not exist.
  (let* ((home (or (and (fboundp 'sb-ext:posix-getenv)
                        (sb-ext:posix-getenv "HOME"))
                   "/tmp"))
         (home (if (char= (char home (1- (length home))) #\/)
                   home
                   (concatenate 'string home "/"))))
    (merge-pathnames ".pp/islands/" (pathname home))))

(defun island-cache-src-root () (merge-pathnames "src/" (island-root)))
(defun island-cached-tree (pin) (merge-pathnames (concatenate 'string pin "/")
                                                 (island-cache-src-root)))

(defun island-hash-file (path)
  (handler-case
      (with-open-file (stream path :element-type '(unsigned-byte 8))
        (let ((bytes (make-array (file-length stream)
                                 :element-type '(unsigned-byte 8))))
          (read-sequence bytes stream)
          (pp.kernel:sha256-octets bytes)))
    (error () nil)))

(defun island-entry-kind (path)
  #+sbcl
  (handler-case
      (let ((mode (sb-posix:stat-mode (sb-posix:lstat path))))
        (cond ((= (logand mode sb-posix:s-ifmt) sb-posix:s-ifdir) :directory)
              ((= (logand mode sb-posix:s-ifmt) sb-posix:s-ifreg) :file)
              ((= (logand mode sb-posix:s-ifmt) sb-posix:s-iflnk) :symlink)
              (t :special)))
    (error () :absent))
  #-sbcl :absent)

(defun island-readlink (path)
  #+sbcl (handler-case (sb-posix:readlink path) (error () "?"))
  #-sbcl "?")

(defun island-tree-entries (root cb)
  "Depth-first sorted walk of ROOT; calls (cb kind rel path) per entry.
The root itself yields nothing; directories are recursed into."
  (labels ((visit (rel path)
             (ecase (island-entry-kind path)
               (:directory
                (dolist (child (island-sorted-children path))
                  (visit (if (string= rel "")
                             (island-basename child)
                             (format nil "~A/~A" rel (island-basename child)))
                         child)))
               (:file
                (funcall cb "file" rel (or (island-hash-file path) "unreadable")))
               (:symlink
                (funcall cb "symlink" rel
                         (format nil "link->~A" (island-readlink path))))
               ((:special)
                (funcall cb "special" rel "special"))
               (:absent
                (funcall cb "lstat-failed" rel "unstattable")))))
    (when (probe-file root)
      (visit "" (island-strip-trailing-slash (namestring root))))))

(defun island-strip-trailing-slash (path)
  (if (and (plusp (length path)) (char= (char path (1- (length path))) #\/))
      (subseq path 0 (1- (length path)))
      path))

(defun island-basename (path)
  (let* ((path (island-strip-trailing-slash path))
         (pos (cl:position #\/ path :from-end t)))
    (if pos (subseq path (1+ pos)) path)))

(defun island-sorted-children (directory)
  ;; The pattern must hang off a DIRECTORY pathname: a trailing slash keeps
  ;; the last component out of :name, and ".*" picks up dotfiles that "*"
  ;; alone would miss.
  (let* ((base (island-strip-trailing-slash (namestring directory)))
         (entries (append
                   (ignore-errors (directory (format nil "~A/*.*" base)))
                   (ignore-errors
                     (delete-if
                      (lambda (p)
                        (member (island-basename (namestring p))
                                '("." "..") :test #'string=))
                      (ignore-errors (directory (format nil "~A/.*" base))))))))
    (sort (delete-duplicates (mapcar #'namestring entries)
                             :test #'string=)
          #'string<)))

;;; The pin IS the canonical tree digest: framed, sorted, one hasher.
(defun island-tree-hash (root)
  (let ((parts nil))
    (island-tree-entries
     root (lambda (kind rel payload)
            (push kind parts) (push rel parts) (push payload parts)))
    (hash-concat (cons "tree" (nreverse parts)))))

(defun island-verify (dir pin)
  "Return nil when DIR hashes to PIN, else the actual hash."
  (let ((actual (island-tree-hash dir)))
    (unless (string= actual pin) actual)))

(defun island-log-resolution (uri pin)
  (ignore-errors
    (ensure-directories-exist (island-root))
    (with-open-file (stream (merge-pathnames "index" (island-root))
                            :direction :output
                            :if-exists :append :if-does-not-exist :create)
      (format stream "~A~C~A~C~D~%" uri #\Tab pin #\Tab
              (get-universal-time)))))

(defun island-rm-recursive (path)
  (labels ((entries (directory)
             (let ((base (island-strip-trailing-slash (namestring directory))))
               (append (ignore-errors (directory (format nil "~A/*.*" base)))
                       (ignore-errors
                         (directory (format nil "~A/.*" base))))))
           (walk (path)
             (let ((path (island-strip-trailing-slash path)))
               (if (eq (island-entry-kind path) :directory)
                   (progn
                     (dolist (child (entries path)) (walk child))
                     (ignore-errors (sb-posix:rmdir path)))
                   (ignore-errors (delete-file path))))))
    (walk path)))

;;; Regular files and directories only: anything else would make the copy's
;;; tree hash lie about the source.
(defun island-copy-tree (src dst)
  (ecase (island-entry-kind src)
    (:directory
     ;; Merge children against an explicit DIRECTORY pathname: a plain
     ;; (pathname dst) would treat dst's last segment as a file name.
     (ensure-directories-exist (merge-pathnames
                                (make-pathname :directory '(:relative))
                                (merge-pathnames
                                 (pathname (concatenate 'string dst "/")))))
     (dolist (child (island-sorted-children src))
       (island-copy-tree
        child
        (merge-pathnames (make-pathname :name (island-basename child)
                                        :type nil :version nil)
                         (pathname (concatenate 'string dst "/"))))))
    (:file
     (with-open-file (in src :element-type '(unsigned-byte 8))
       (with-open-file (out dst :element-type '(unsigned-byte 8)
                                :direction :output
                                :if-exists :supersede
                                :if-does-not-exist :create)
         (let ((buffer (make-array 65536 :element-type '(unsigned-byte 8))))
           (loop for n = (read-sequence buffer in)
                 do (write-sequence buffer out :end n)
                 until (< n (length buffer))))))
     ;; Preserve the exec bit (does not affect the tree hash).
     #+sbcl
     (ignore-errors
       (let ((mode (sb-posix:stat-mode (sb-posix:stat src))))
         (unless (zerop (logand mode #o111))
           (sb-posix:chmod dst mode)))))
    ((:symlink :special :absent)
     (language-fail
      (format nil "island: unsupported file kind in island source: ~A" src)
      "runtime.island"))))

;;; Materialize SRC-DIR into the cache and return its pin.  Idempotent.
;;; Publication is atomic (copy to temp, re-hash the copy, rename), so a
;;; crash never leaves a half-tree at src/<pin>/.
(defun island-materialize (uri src-dir)
  (let ((src-dir (island-strip-trailing-slash (namestring src-dir))))
    (unless (and (probe-file src-dir)
                 (eq (island-entry-kind src-dir) :directory))
      (language-fail
       (format nil "island: source is not a directory: ~A (~A)" uri src-dir)
       "runtime.island"))
    (let* ((pin (island-tree-hash src-dir))
           (dst (island-strip-trailing-slash (namestring (island-cached-tree pin)))))
      (unless (probe-file dst)
        (ensure-directories-exist (island-cache-src-root))
        (let ((tmp (format nil "~A.tmp.~D" dst (sb-posix:getpid))))
          (island-rm-recursive tmp)
          (unwind-protect
               (progn
                 (island-copy-tree src-dir tmp)
                 (let ((mismatch (island-verify tmp pin)))
                   (when mismatch
                     (language-fail
                      (format nil "island: source for ~A changed while copying ~
(~A vs ~A)" uri (island-short pin) (island-short mismatch))
                      "runtime.island")))
                 ;; Raw rename(2): CL rename-file merges unspecified
                 ;; pathname components with the source's, which mangles
                 ;; directory names containing dots.
                 #+sbcl
                 (handler-case (sb-posix:rename tmp dst)
                   (sb-posix:syscall-error () nil))
                 #-sbcl
                 (ignore-errors (rename-file tmp dst))
                 (island-rm-recursive tmp))
            (island-rm-recursive tmp))))
      (island-log-resolution uri pin)
      pin)))

;;; ---- Fetch (git:/github:) — opt-in runtime authority ----
;;;
;;; Clone the URI's ref into a temp dir with plumbing only (--template=
;;; gives an empty template dir; clone never runs the remote's hooks),
;;; strip .git, and materialize the tree.  See docs/THREAT-MODEL-islands.md.

(defun island-fetch-git (scheme locator raw ref-hint)
  (unless *island-fetch-enabled*
    (language-fail
     (format nil "island: fetching is disabled; run pp --fetch-islands ~
(or --update) for ~A" raw)
     "runtime.island"))
  (let* ((url (ecase scheme (:github (format nil "https://github.com/~A" locator))
                     (:git locator)))
         (tmpdir (or (and (fboundp 'sb-ext:posix-getenv)
                          (sb-ext:posix-getenv "TMPDIR")
                          (plusp (length (sb-ext:posix-getenv "TMPDIR")))
                          (sb-ext:posix-getenv "TMPDIR"))
                     "/tmp"))
         (tmp (store-exclusive-directory tmpdir "pp-island")))
    (unwind-protect
         (progn
           (island-run-git "clone" "--quiet" "--template=" url tmp)
           (when ref-hint
             (island-run-git "-C" tmp "checkout" "--quiet" ref-hint))
           (let ((pin (island-materialize raw tmp)))
             (let ((session (ignore-errors (runtime-dynamic-session nil))))
               (when session
                 (runtime-journal-append session
                                         (make-runtime-journal-island-fetch
                                          raw pin))))
             pin))
      (island-rm-recursive tmp))))

(defun island-run-git (&rest arguments)
  (let* ((tmpdir (or (and (fboundp 'sb-ext:posix-getenv)
                          (sb-ext:posix-getenv "TMPDIR")
                          (plusp (length (sb-ext:posix-getenv "TMPDIR")))
                          (sb-ext:posix-getenv "TMPDIR"))
                     "/tmp"))
         (err (store-exclusive-temp-name tmpdir "pp-git-" ".err"))
         (process (progn
                    (sb-posix:unlink err)
                    (sb-ext:run-program "git" arguments
                                        :search t :wait t :input "/dev/null"
                                        :output nil :error err))))
    (unwind-protect
         (unless (and process (zerop (sb-ext:process-exit-code process)))
           (let ((detail (ignore-errors
                           (with-output-to-string (out)
                             (with-open-file (stream err)
                               (loop for line = (read-line stream nil nil)
                                     while line do (write-line line out)))))))
             (language-fail
              (format nil "island: git ~A failed~@[~A~]"
                      (first arguments)
                      (and detail (plusp (length detail))
                           (concatenate 'string ": "
                                        (string-trim '(#\Space #\Newline)
                                                     detail))))
              "runtime.island")))
      (ignore-errors (delete-file err)))))

;;; Fetch/derive a fresh pin for a URI — the impure step behind `pp --update`
;;; (and first-fetch).  file: re-hashes the local source dir; git:/github:
;;; clone the ref.
(defun island-repin (scheme locator raw ref-hint)
  (ecase scheme
    (:file (island-materialize raw locator))
    ((:git :github) (island-fetch-git scheme locator raw ref-hint))))

;;; ---- Resolution: pin -> immutable cached tree (never the network) ----

(defun island-resolve (uri pin)
  "Resolve an island form to the directory of its pinned tree.  Verifies the
cache against the pin on every resolve (tamper check).  For file: URIs a
missing cache entry may be filled from the local source dir — but only when
the source hashes to the pin exactly, so the fill cannot change what the pin
denotes."
  (multiple-value-bind (scheme locator ref-hint) (island-parse-uri uri)
    (declare (ignore ref-hint))
    (unless pin
      (language-fail
       (format nil "island: no pin for ~A; run pp --update" uri)
       "runtime.island"))
    (unless (island-pin-p pin)
      (language-fail
       (format nil "island: pin for ~A must be a 64-hex content hash, got ~S ~
(refs go in the URI: <scheme:locator#ref>)" uri pin)
       "runtime.island"))
    (let ((dir (island-strip-trailing-slash
                (namestring (island-cached-tree pin)))))
      (if (probe-file dir)
          (progn
            (let ((mismatch (island-verify dir pin)))
              (when mismatch
                (language-fail
                 (format nil "island: cache tamper detected for ~A: src/~A ~
now hashes ~A" uri (island-short pin) (island-short mismatch))
                 "runtime.island")))
            ;; Drift visibility (`pp why`): the pin still governs, but tell
            ;; the user when the local source has moved past it.
            (when (eq scheme :file)
              (let ((source (and (probe-file locator)
                                 (eq (island-entry-kind locator) :directory)
                                 locator)))
                (when source
                  (let ((mismatch (island-verify source pin)))
                    (when mismatch
                      (let ((fn (runtime-observation-service :diagnose)))
                        (when fn
                          (funcall fn
                                   (format nil "island ~A: source dir now ~
hashes ~A but the pin is ~A — run pp --update"
                                           uri (island-short mismatch)
                                           (island-short pin))))))))))
            dir)
          (ecase scheme
            (:file
             (unless (probe-file locator)
               (language-fail
                (format nil "island: pin ~A not cached and source missing ~
for ~A" (island-short pin) uri)
                "runtime.island"))
             (let ((mismatch (island-verify locator pin)))
               (when mismatch
                 (language-fail
                  (format nil "island: source dir for ~A hashes ~A but the ~
pin is ~A — run pp --update to re-pin"
                          uri (island-short mismatch) (island-short pin))
                  "runtime.island")))
             (island-materialize uri locator)
             dir)
            ((:git :github)
             (unless *island-fetch-enabled*
               (language-fail
                (format nil "island: pin ~A for ~A is not in the cache; run ~
pp --fetch-islands" (island-short pin) uri)
                "runtime.island"))
             (let ((fetched (island-fetch-git scheme locator uri ref-hint)))
               (unless (string= fetched pin)
                 (language-fail
                  (format nil "island: fetched ~A for ~A but the pin is ~A — ~
the ref moved; run pp --update to accept the new content"
                          (island-short fetched) uri (island-short pin))
                  "runtime.island"))
               dir)))))))

;;; The module root inside a pinned tree.  entry.pp is brace surface (the
;;; default), entry.ppb a permanent brace alias, entry.ppl the sexpr/AST
;;; surface; entry.pp wins when several exist.
(defun island-entry-file (tree-dir)
  ;; Concatenate: TREE-DIR without a trailing slash parses as a file
  ;; pathname, and merge-pathnames would drop it.
  (dolist (name '("entry.pp" "entry.ppb" "entry.ppl") nil)
    (let ((candidate (concatenate 'string
                                  (island-strip-trailing-slash
                                   (namestring tree-dir))
                                  "/" name)))
      (when (probe-file candidate)
        (return-from island-entry-file candidate))))
  (language-fail
   (format nil "island: pinned tree has no entry.pp: ~A" tree-dir)
   "runtime.island"))

;;; ---- Syntactic walk: every island form in an expression ----

(defun island-forms-in (expression)
  "Every (uri . pin) island form reachable in EXPRESSION, deduplicated.
Quoted data is not evaluated and therefore not walked."
  (let ((forms nil))
    (labels ((walk (node)
               (typecase node
                 (expr-island
                  (let ((entry (cons (expr-island-uri node)
                                     (expr-island-pin node))))
                    (unless (member entry forms :test #'equal)
                      (push entry forms))))
                 ((or expr-literal expr-symbol expr-quote
                      expr-load expr-loadmodule) nil)
                 (structure-object
                  (dolist (slot (sb-mop:class-slots (class-of node)))
                    (let ((name (sb-mop:slot-definition-name slot)))
                      (when (slot-boundp node name)
                        (walk (slot-value node name))))))
                 (cons (walk (car node)) (walk (cdr node)))
                 (vector (map nil #'walk node))
                 (t nil))))
      (walk expression)
      (nreverse forms))))
