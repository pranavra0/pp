;;;; Durable append-only lifecycle journal.
(in-package #:pp.rt.journal)

(defstruct (runtime-journal-exec (:constructor make-runtime-journal-exec (argv))) argv)
(defstruct (runtime-journal-domain-intent
            (:constructor make-runtime-journal-domain-intent (hash fields)))
  hash fields)
(defstruct (runtime-journal-domain-done
            (:constructor make-runtime-journal-domain-done (hash))) hash)
(defstruct (runtime-journal-proc-start-intent
            (:constructor make-runtime-journal-proc-start-intent (name spec-hash)))
  name spec-hash)
(defstruct (runtime-journal-proc-start-done
            (:constructor make-runtime-journal-proc-start-done (name spec-hash pid)))
  name spec-hash pid)
(defstruct (runtime-journal-proc-stop-intent
            (:constructor make-runtime-journal-proc-stop-intent (name))) name)
(defstruct (runtime-journal-proc-stop-done
            (:constructor make-runtime-journal-proc-stop-done (name))) name)
(defstruct (runtime-journal-fenced-intent
            (:constructor make-runtime-journal-fenced-intent
                (key epoch kind spec-hash)))
  key epoch kind spec-hash)
(defstruct (runtime-journal-fenced-done
            (:constructor make-runtime-journal-fenced-done (key result-hash)))
  key result-hash)
(defstruct (runtime-journal-island-fetch
            (:constructor make-runtime-journal-island-fetch (uri pin))) uri pin)
(defstruct (runtime-journal-epoch
            (:constructor make-runtime-journal-epoch (hash))) hash)

(defun runtime-journal-digest-p (value)
  (and (stringp value) (= (length value) 64)
       (every (lambda (char)
                (and (digit-char-p char 16)
                     (or (char<= #\0 char #\9)
                         (char<= #\a char #\f)))) value)))
(defun runtime-journal-token-p (value)
  (and (stringp value) (plusp (length value))
       (every (lambda (char) (<= 33 (char-code char) 126)) value)))
(defun runtime-journal-pid-p (value)
  (and (runtime-journal-token-p value) (every #'digit-char-p value)
       (or (= (length value) 1) (char/= (char value 0) #\0))
       (ignore-errors (parse-integer value))))

(defun runtime-journal-entry-line (entry)
  (typecase entry
    (runtime-journal-exec
     (format nil "exec ~{~A~^ ~}" (runtime-journal-exec-argv entry)))
    (runtime-journal-domain-intent
     (with-output-to-string (out)
       (format out "intent ~A" (runtime-journal-domain-intent-hash entry))
       (dolist (field (runtime-journal-domain-intent-fields entry))
         (format out " ~A=~A" (car field) (cdr field)))))
    (runtime-journal-domain-done
     (format nil "done ~A" (runtime-journal-domain-done-hash entry)))
    (runtime-journal-proc-start-intent
     (format nil "intent proc start ~A ~A"
             (runtime-journal-proc-start-intent-name entry)
             (runtime-journal-proc-start-intent-spec-hash entry)))
    (runtime-journal-proc-start-done
     (format nil "done proc start ~A ~A pid=~D"
             (runtime-journal-proc-start-done-name entry)
             (runtime-journal-proc-start-done-spec-hash entry)
             (runtime-journal-proc-start-done-pid entry)))
    (runtime-journal-proc-stop-intent
     (format nil "intent proc stop ~A" (runtime-journal-proc-stop-intent-name entry)))
    (runtime-journal-proc-stop-done
     (format nil "done proc stop ~A" (runtime-journal-proc-stop-done-name entry)))
    (runtime-journal-fenced-intent
     (format nil "intent fenced ~A ~A ~A ~A"
             (runtime-journal-fenced-intent-key entry)
             (runtime-journal-fenced-intent-epoch entry)
             (runtime-journal-fenced-intent-kind entry)
             (runtime-journal-fenced-intent-spec-hash entry)))
    (runtime-journal-fenced-done
     (format nil "done fenced ~A ~A"
             (runtime-journal-fenced-done-key entry)
             (runtime-journal-fenced-done-result-hash entry)))
    (runtime-journal-island-fetch
     (format nil "island fetch ~A ~A"
             (runtime-journal-island-fetch-uri entry)
             (runtime-journal-island-fetch-pin entry)))
    (runtime-journal-epoch
     (format nil "epoch ~A" (runtime-journal-epoch-hash entry)))
    (t (error "Unknown lifecycle journal entry"))))

(defun runtime-journal-split-words (line)
  (let ((words nil) (start 0) (length (length line)))
    (loop for at = (cl:position #\Space line :start start)
          do (if at
                 (progn (push (subseq line start at) words)
                        (setf start (1+ at)))
                 (progn (push (subseq line start length) words)
                        (return (nreverse words)))))))

(defun runtime-journal-parse-line (line)
  (when (and (stringp line) (plusp (length line))
             (not (find #\Return line)) (not (find #\Newline line)))
    (let ((words (runtime-journal-split-words line)))
      (labels ((digest (s) (and s (runtime-journal-digest-p s)))
               (token (s) (and s (runtime-journal-token-p s))))
        (cond
          ((and (string= (first words) "exec") (> (length words) 1)
                (every #'runtime-journal-token-p (rest words)))
           (make-runtime-journal-exec (rest words)))
          ((and (= (length words) 2) (string= (first words) "epoch")
                (digest (second words)))
           (make-runtime-journal-epoch (second words)))
          ((and (= (length words) 4) (string= (first words) "island")
                (string= (second words) "fetch")
                (token (third words)) (token (fourth words)))
           (make-runtime-journal-island-fetch (third words) (fourth words)))
          ((and (= (length words) 6) (string= (first words) "intent")
                (string= (second words) "fenced")
                (digest (third words)) (digest (fourth words))
                (token (fifth words)) (digest (sixth words)))
           (make-runtime-journal-fenced-intent
            (third words) (fourth words) (fifth words) (sixth words)))
          ((and (= (length words) 4) (string= (first words) "done")
                (string= (second words) "fenced")
                (digest (third words)) (digest (fourth words)))
           (make-runtime-journal-fenced-done (third words) (fourth words)))
          ((and (= (length words) 5) (string= (first words) "intent")
                (string= (second words) "proc") (string= (third words) "start")
                (token (fourth words)) (digest (fifth words)))
           (make-runtime-journal-proc-start-intent (fourth words) (fifth words)))
          ((and (= (length words) 6) (string= (first words) "done")
                (string= (second words) "proc") (string= (third words) "start")
                (token (fourth words)) (digest (fifth words))
                (let ((field (sixth words)))
                  (and (>= (length field) 4)
                       (string= "pid=" field :end2 4)
                       (runtime-journal-pid-p (subseq field 4)))))
           (make-runtime-journal-proc-start-done
            (fourth words) (fifth words) (parse-integer (subseq (sixth words) 4))))
          ((and (= (length words) 4) (string= (first words) "intent")
                (string= (second words) "proc") (string= (third words) "stop")
                (token (fourth words)))
           (make-runtime-journal-proc-stop-intent (fourth words)))
          ((and (= (length words) 4) (string= (first words) "done")
                (string= (second words) "proc") (string= (third words) "stop")
                (token (fourth words)))
           (make-runtime-journal-proc-stop-done (fourth words)))
          ((and (= (length words) 2) (string= (first words) "done")
                (digest (second words)))
           (make-runtime-journal-domain-done (second words)))
          ((and (> (length words) 2) (string= (first words) "intent")
                (digest (second words)))
           (let ((fields nil))
             (dolist (word (cddr words))
               (let ((at (cl:position #\= word)))
                 (unless (and at (> at 0) (< at (1- (length word))))
                   (return-from runtime-journal-parse-line nil))
                 (let ((key (subseq word 0 at)) (value (subseq word (1+ at))))
                   (unless (and (token key) (token value)
                                (not (find #\= value)))
                     (return-from runtime-journal-parse-line nil))
                   (when (assoc key fields :test #'string=)
                     (return-from runtime-journal-parse-line nil))
                   (push (cons key value) fields))))
             (make-runtime-journal-domain-intent (second words) (nreverse fields))))
          (t nil))))))

(defun runtime-journal-entry-valid-p (entry)
  (handler-case
      (let ((line (runtime-journal-entry-line entry)))
        (and (plusp (length line))
             (not (find #\Return line)) (not (find #\Newline line))
             (runtime-journal-parse-line line)))
    (error () nil)))

(defun runtime-journal-layout (session)
  (and (fboundp 'pp.rt.session:runtime-session-store-layout)
       (pp.rt.session:runtime-session-store-layout session)))
(defun runtime-journal-path (session)
  (let ((layout (runtime-journal-layout session)))
    (unless layout (error "lifecycle journal store is unavailable"))
    (let ((directory (merge-pathnames "journal/"
                                     (store-directory-pathname
                                      (store-layout-root layout)))))
      (store-ensure-directory directory)
      (namestring (merge-pathnames "log" directory)))))

(defun runtime-journal-append (session entry)
  (let ((line (runtime-journal-entry-line entry)))
    (unless (runtime-journal-entry-valid-p entry)
      (error "lifecycle journal entry is not canonical"))
    (let* ((path (runtime-journal-path session))
           (directory (directory-namestring path)))
      (store-ensure-directory directory)
      #+sbcl
      (let ((fd (sb-posix:open path (logior sb-posix:o-wronly sb-posix:o-creat
                                            sb-posix:o-append sb-posix:o-nofollow)
                                #o600)))
        (unwind-protect
             (progn
               (sb-posix:lockf fd sb-posix:f-lock 0)
               (store-write-fd-all
                fd (store-copy-octets
                    (store-string-octets
                     (concatenate 'string line (string #\Newline)))))
               (sb-posix:fsync fd))
          (ignore-errors (sb-posix:lockf fd sb-posix:f-ulock 0))
          (sb-posix:close fd)))
      #-sbcl
      (store-with-lock (merge-pathnames "lifecycle.lock" directory)
        (lambda ()
          (with-open-file (stream path :direction :output :if-exists :append
                                  :if-does-not-exist :create)
            (write-line line stream)))))))

(defun runtime-journal-fold (session function &optional initial-value)
  (let ((path (runtime-journal-path session)))
    (if (probe-file path)
        (with-open-file (stream path :direction :input :element-type 'character)
          (let ((length (file-length stream)))
            (when (and (plusp length)
                       (progn (file-position stream (1- length))
                              (char/= (read-char stream) #\Newline)))
              (error "lifecycle journal has an unterminated final line"))
            (file-position stream 0))
          (let ((value initial-value) (line-number 0))
            (loop for line = (read-line stream nil nil) while line do
              (incf line-number)
              (let ((entry (runtime-journal-parse-line line)))
                (unless entry
                  (error "lifecycle journal malformed line ~D" line-number))
                (setf value (funcall function value entry))))
            value))
        initial-value)))

(defun runtime-journal-pending-fenced-actions (session)
  (let ((pending (make-hash-table :test #'equal))
        (intents (make-hash-table :test #'equal)))
    (runtime-journal-fold
     session
     (lambda (ignored entry)
       (declare (ignore ignored))
       (typecase entry
         (runtime-journal-fenced-intent
          (setf (gethash (runtime-journal-fenced-intent-key entry) intents) t
                (gethash (runtime-journal-fenced-intent-key entry) pending) entry))
         (runtime-journal-fenced-done
          (unless (gethash (runtime-journal-fenced-done-key entry) intents)
            (error "invalid journal: lifecycle journal fenced done has no intent"))
          (remhash (runtime-journal-fenced-done-key entry) pending)))
       nil)
     nil)
    (let (entries)
      (maphash (lambda (key entry)
                 (declare (ignore key))
                 (push entry entries))
               pending)
      (sort entries #'string< :key #'runtime-journal-fenced-intent-key))))

(defun runtime-journal-has-fenced-done-p (session key)
  (runtime-journal-fold
   session
   (lambda (state entry)
     (if (and (typep entry 'runtime-journal-fenced-done)
              (string= key (runtime-journal-fenced-done-key entry))) t state))
   nil))

