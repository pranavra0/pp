;;;; Focused store probes.  Load after pp/kernel and runtime/store.lisp.
(in-package #:pp.runtime)

(defun m4-store-fixtures (&optional (root "/tmp/pp-m4-store-fixture"))
  (let* ((layout (make-store-layout root))
         (objects (make-object-repository layout))
         (blobs (make-blob-repository layout))
         (traces (make-trace-repository layout))
         (fixture (with-open-file (stream "lisp/tests/golden/canonical-value.object")
                    (let ((text (make-string (file-length stream))))
                      (read-sequence text stream) text)))
         (value (pp.kernel:decode-value fixture))
         (object-hash (pp.kernel:hash-value value))
         (trace-line "(trace ok \"d98fba09338648079975ad61b2a3ca43cb3ddf4e2c36c7724f66aab333224012\" ())")
         (version-bytes (vector 112 112 45 115 116 111 114 101 32 50 10)))
    (assert value)
    (store-layout-init layout)
    (assert (equal (truename (store-layout-root layout))
                   (truename root)))
    (assert (equalp (store-read-octets
                     (merge-pathnames "VERSION" (store-directory-pathname root)))
                    version-bytes))
    #+sbcl
    (dolist (entry (list (cons root #o700)
                         (cons (store-layout-area layout :objects) #o700)
                         (cons (store-layout-area layout :traces) #o700)
                         (cons (merge-pathnames "VERSION"
                                                (store-directory-pathname root))
                               #o600)))
      (let ((stat (sb-posix:stat (namestring (car entry)))))
        (assert (= (logand (sb-posix:stat-mode stat) #o7777)
                   (cdr entry)))))
    (object-repository-put objects :key object-hash :value value)
    (assert (pp.kernel:equal-value value
                                    (object-repository-get objects :key object-hash)))
    (assert (null (object-repository-get objects :key (make-string 64 :initial-element #\0))))
    (let ((trace (trace-repository-of-line trace-line)))
      (assert trace)
      (assert (string= (trace-repository-to-line trace) trace-line))
      (trace-repository-put traces :key (pp.kernel:cache-key-of-string
                                         "4fd253ec30afc9223a64014727ecf6125921edc56dfcd0470e45de121ca4f73c")
                            :outcome :ok
                            :result-hash (store-trace-result-hash trace)
                            :reads nil)
      (assert (= 1 (length (trace-repository-load traces :key
                                                   "4fd253ec30afc9223a64014727ecf6125921edc56dfcd0470e45de121ca4f73c")))))
    (let* ((bytes (vector 0 1 127 128 255))
           (hash (blob-repository-put blobs bytes)))
      (assert (string= hash (store-hash-octets bytes)))
      (assert (equalp bytes (blob-repository-get blobs hash))))
    (let ((root-value (make-store-gc-root object-hash nil)))
      (gc-roots-record layout root-value)
      (assert (equalp
               (store-read-octets (gc-roots-path layout))
               (store-string-octets
                (concatenate 'string
                             (pp.kernel:encode-value (gc-roots-root-value root-value))
                             (string #\Newline)))))
      (let ((roots (gc-roots-read-all layout)))
        (assert (= 1 (length roots)))
        (assert (string= object-hash (store-gc-root-hash (first roots)))))
      (let ((report (store-gc-run layout traces objects :grace-seconds 1000000)))
        (assert (equal '(1 . 0) (getf report :objects)))))
    (dolist (bad '("" "(trace ok \"UPPER\" ())"
                   "(trace ok \"d98fba09338648079975ad61b2a3ca43cb3ddf4e2c36c7724f66aab333224012\" (x))"
                   "(trace ok \"d98fba09338648079975ad61b2a3ca43cb3ddf4e2c36c7724f66aab333224012\" ())x"))
      (assert (null (trace-repository-of-line bad))))
    :ok))
