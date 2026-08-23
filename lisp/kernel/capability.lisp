(in-package :pp.kernel)
(deftype fs-mode () '(member :read :write :read-write))


;;; Capability records are immutable at the boundary.  In particular, retained
;;; canonical paths are never exposed as writable strings and list-valued
;;; composition is copied both on construction and observation.
(defstruct (cap-filesystem
            (:constructor %make-cap-filesystem (path mode))
            (:conc-name %cap-filesystem-))
  (path nil :read-only t)
  (mode :read :read-only t))
(defstruct (cap-network
            (:constructor %make-cap-network (host port))
            (:conc-name %cap-network-))
  (host "" :type string :read-only t)
  (port nil :read-only t))
(defstruct (cap-secret
            (:constructor %make-cap-secret (path))
            (:conc-name %cap-secret-))
  (path nil :read-only t))
(defstruct (cap-process (:constructor make-cap-process ()) (:conc-name %cap-process-)))
(defstruct (cap-compose
            (:constructor %make-cap-compose (capabilities))
            (:conc-name %cap-compose-))
  (capabilities nil :read-only t))
(defstruct (cap-restrict
            (:constructor %make-cap-restrict (cap scope mode))
            (:conc-name %cap-restrict-))
  (cap nil :read-only t)
  (scope nil :read-only t)
  (mode nil :read-only t))
(defstruct (cap-none (:constructor make-cap-none ()) (:conc-name %cap-none-)))

;;; Safe accessors retain the historical names but never provide SETF paths or
;;; mutable composition lists.
(defun cap-filesystem-path (cap) (%cap-filesystem-path cap))
(defun cap-filesystem-mode (cap) (%cap-filesystem-mode cap))
(defun cap-network-host (cap) (copy-seq (%cap-network-host cap)))
(defun cap-network-port (cap) (%cap-network-port cap))
(defun cap-secret-path (cap) (%cap-secret-path cap))
(defun cap-compose-capabilities (cap) (copy-list (%cap-compose-capabilities cap)))
(defun cap-restrict-cap (cap) (%cap-restrict-cap cap))
(defun cap-restrict-scope (cap) (%cap-restrict-scope cap))
(defun cap-restrict-mode (cap) (%cap-restrict-mode cap))

(deftype capability ()
  '(or cap-filesystem cap-network cap-secret cap-process cap-compose cap-restrict cap-none))

(defparameter *no-capability* (make-cap-none))
(defun no-capability () (make-cap-none))

(defun ensure-fs-mode (mode)
  (if (typep mode 'fs-mode)
      mode
      (error "Invalid filesystem capability mode: ~S" mode)))

(defun ensure-canonical-path (path realpath)
  (if (typep path 'canonical-path)
      path
      (canonicalize-path (or path "") :realpath realpath)))

(defun make-capability (&key kind name token rights realpath)
  (ecase kind
    (:filesystem
     (%make-cap-filesystem
      (ensure-canonical-path name realpath)
      (ensure-fs-mode (or rights :read))))
    (:network
     (let ((host (or name "*")))
       (check-type host string)
       (when (and token (not (integerp token)))
         (error "Network capability port must be an integer or NIL"))
       (%make-cap-network (copy-seq host) token)))
    (:secret (%make-cap-secret (ensure-canonical-path name realpath)))
    (:process (make-cap-process))))

(defun capability-kind (capability)
  (typecase capability
    (cap-filesystem :filesystem)
    (cap-network :network)
    (cap-secret :secret)
    (cap-process :process)
    (cap-compose :compose)
    (cap-restrict :restrict)
    (cap-none :none)))

(defun capability-name (capability)
  (typecase capability
    (cap-filesystem (canonical-path-to-string (cap-filesystem-path capability)))
    (cap-network (cap-network-host capability))
    (cap-secret (canonical-path-to-string (cap-secret-path capability)))
    (t nil)))

(defun capability-token (capability)
  (and (typep capability 'cap-network) (cap-network-port capability)))

(defun capability-rights (capability)
  (and (typep capability 'cap-filesystem) (cap-filesystem-mode capability)))

(defun compose-capabilities (capabilities)
  (check-type capabilities list)
  (unless (every (lambda (cap) (typep cap 'capability)) capabilities)
    (error "COMPOSE-CAPABILITIES requires capability values"))
  (%make-cap-compose (copy-list capabilities)))

(defun restrict-capability (capability scope &key mode)
  (check-type capability capability)
  (check-type scope canonical-path)
  (when mode (ensure-fs-mode mode))
  (%make-cap-restrict capability scope mode))

(defun fs-mode-name (mode)
  (ecase mode (:read "ro") (:write "wo") (:read-write "rw")))

(defun fs-mode-code (mode)
  (ecase mode (:read "r") (:write "w") (:read-write "rw")))

(defun fs-mode-allows-p (granted want)
  (or (eq granted :read-write) (eq granted want)))

(defun fs-mode-intersect (a b)
  (cond ((eq a :read-write) b)
        ((eq b :read-write) a)
        ((eq a b) a)
        (t nil)))

(defun capability-path-grants-p (scope target)
  (path-under-p scope target))

(defun capability-check-fs (want capability target)
  (check-type target canonical-path)
  (typecase capability
    (cap-filesystem
     (and (fs-mode-allows-p (cap-filesystem-mode capability) want)
          (capability-path-grants-p (cap-filesystem-path capability) target)))
    (cap-compose
     (some (lambda (cap) (capability-check-fs want cap target))
           (cap-compose-capabilities capability)))
    (cap-restrict
     (and (capability-path-grants-p (cap-restrict-scope capability) target)
          (capability-check-fs want (cap-restrict-cap capability) target)
          (or (null (cap-restrict-mode capability))
              (fs-mode-allows-p (cap-restrict-mode capability) want))))
    (t nil)))

(defun capability-check-fs-read-p (capability target)
  (capability-check-fs :read capability target))
(defun capability-check-fs-write-p (capability target)
  (capability-check-fs :write capability target))

(defun capability-check-network-p (capability host &optional port)
  (check-type host string)
  (typecase capability
    (cap-network
     (and (or (string= "*" (%cap-network-host capability))
              (string= host (%cap-network-host capability)))
          (let ((granted-port (%cap-network-port capability)))
            (or (null granted-port)
                (and port (= granted-port port))))))
    (cap-compose
     (some (lambda (cap) (capability-check-network-p cap host port))
           (cap-compose-capabilities capability)))
    (cap-restrict
     (capability-check-network-p (cap-restrict-cap capability) host port))
    (t nil)))

(defun capability-check-secret-p (capability target)
  (check-type target canonical-path)
  (typecase capability
    (cap-secret (capability-path-grants-p (cap-secret-path capability) target))
    (cap-compose
     (some (lambda (cap) (capability-check-secret-p cap target))
           (cap-compose-capabilities capability)))
    (cap-restrict
     (and (capability-path-grants-p (cap-restrict-scope capability) target)
          (capability-check-secret-p (cap-restrict-cap capability) target)))
    (t nil)))

(defun capability-check-process-p (capability)
  (typecase capability
    (cap-process t)
    (cap-compose
     (some #'capability-check-process-p (cap-compose-capabilities capability)))
    (cap-restrict (capability-check-process-p (cap-restrict-cap capability)))
    (t nil)))

(defun effective-fs-path (scope path)
  (cond ((path-under-p scope path) path)
        ((path-under-p path scope) scope)
        (t nil)))

(defun capability-list-fs-paths (capability)
  "List effective filesystem grants as (canonical-path . fs-mode) pairs."
  (labels ((walk (cap)
             (typecase cap
               (cap-filesystem
                (list (cons (cap-filesystem-path cap)
                            (cap-filesystem-mode cap))))
               (cap-compose
                (mapcan #'walk (cap-compose-capabilities cap)))
               (cap-restrict
                (let ((scope (cap-restrict-scope cap))
                      (restriction (cap-restrict-mode cap)))
                  (loop for entry in (walk (cap-restrict-cap cap))
                        for path = (effective-fs-path scope (car entry))
                        for mode = (and path
                                        (if restriction
                                            (fs-mode-intersect (cdr entry) restriction)
                                            (cdr entry)))
                        when mode collect (cons path mode))))
               (t nil))))
    (walk capability)))

(defun cap-non-fs-subseteq (cap held)
  (typecase cap
    (cap-network
     (capability-check-network-p held (%cap-network-host cap)
                                 (%cap-network-port cap)))

    (cap-secret
     (capability-check-secret-p held (cap-secret-path cap)))
    (cap-compose
     (every (lambda (entry) (cap-non-fs-subseteq entry held))
            (cap-compose-capabilities cap)))
    (cap-restrict
     (cap-non-fs-subseteq (cap-restrict-cap cap) held))
    ;; Process is checked separately by CAPABILITY-SUBSETEQ.
    (t t)))
(defun list-fs-paths (capability)
  (capability-list-fs-paths capability))

(defun mode-name (mode)
  (fs-mode-name mode))

(defun mode-intersect (a b)
  (fs-mode-intersect a b))

(defun capability-subseteq (requested ambient)
  "Whether REQUESTED grants no more than the list of AMBIENT capabilities."
  (check-type requested capability)
  (check-type ambient list)
  (let ((held (compose-capabilities ambient)))
    (labels ((fs-covered-p (path mode)
               (ecase mode
                 (:read (capability-check-fs-read-p held path))
                 (:write (capability-check-fs-write-p held path))
                 (:read-write (and (capability-check-fs-read-p held path)
                                   (capability-check-fs-write-p held path))))))
      (typecase requested
        (cap-none t)
        (cap-process (capability-check-process-p held))
        (cap-network
         (capability-check-network-p held (%cap-network-host requested)
                                     (%cap-network-port requested)))
        (cap-secret
         (capability-check-secret-p held (cap-secret-path requested)))
        (cap-filesystem
         (fs-covered-p (cap-filesystem-path requested)
                       (cap-filesystem-mode requested)))
        (cap-compose
         (every (lambda (entry) (capability-subseteq entry ambient))
                (cap-compose-capabilities requested)))
        (cap-restrict
         (and (every (lambda (entry) (fs-covered-p (car entry) (cdr entry)))
                     (capability-list-fs-paths requested))
              (or (not (capability-check-process-p requested))
                  (capability-check-process-p held))
              (cap-non-fs-subseteq (cap-restrict-cap requested) held)))))))

(defun subseteq (requested ambient)
  (capability-subseteq requested ambient))
(defun capability-subseteq-p (requested ambient)
  (capability-subseteq requested ambient))

(defun split-colons (string)
  (let ((result nil) (start 0))
    (loop for i from 0 to (length string)
          when (or (= i (length string)) (char= (char string i) #\:))
            do (push (subseq string start i) result)
               (setf start (1+ i)))
    (nreverse result)))

(defun decimal-integer-string (integer)
  (format nil "~D" integer))

(defun mint-capability (spec &key realpath)
  (check-type spec string)
  (let ((parts (split-colons spec)))
    (cond
      ((and (= (length parts) 3) (string= (first parts) "fs"))
       (let ((mode (cond ((string= (third parts) "ro") :read)
                         ((string= (third parts) "wo") :write)
                         ((string= (third parts) "rw") :read-write)
                         (t (error "Invalid filesystem capability mode")))))
         (%make-cap-filesystem
          (canonicalize-path (second parts) :realpath realpath) mode)))
      ((and (= (length parts) 2) (string= (first parts) "net"))
       (%make-cap-network (copy-seq (second parts)) nil))
      ((and (= (length parts) 3) (string= (first parts) "net"))
       (%make-cap-network
        (copy-seq (second parts))
        (or (ignore-errors
              (parse-integer (third parts) :junk-allowed nil))
            (error "Invalid network port"))))
      ((and (= (length parts) 2) (string= (first parts) "secret"))
       (%make-cap-secret
        (canonicalize-path (second parts) :realpath realpath)))
      ((and (= (length parts) 1) (string= (first parts) "process"))
       (make-cap-process))
      (t (error "Invalid capability specification: ~A" spec)))))

(defun capability-hash (capability)
  (typecase capability
    (cap-filesystem
     (hash-concat (list "cap_fs"
                        (canonical-path-to-string (cap-filesystem-path capability))
                        (fs-mode-code (cap-filesystem-mode capability)))))
    (cap-network
     (hash-concat (list "cap_net" (%cap-network-host capability)
                        (if (%cap-network-port capability)
                            (decimal-integer-string (%cap-network-port capability))
                            "any"))))
    (cap-secret
     (hash-concat (list "cap_secret"
                        (canonical-path-to-string (cap-secret-path capability)))))
    (cap-process (hash-string "cap_process"))
    (cap-compose
     (hash-concat (cons "cap_compose"
                        (mapcar #'capability-hash
                                (cap-compose-capabilities capability)))))
    (cap-restrict
     (hash-concat
      (list "cap_restrict"
            (capability-hash (cap-restrict-cap capability))
            (canonical-path-to-string (cap-restrict-scope capability))
            (if (cap-restrict-mode capability)
                (fs-mode-code (cap-restrict-mode capability))
                "any"))))
    (cap-none (hash-string "cap_none"))
    (t (error "Not a capability"))))
(defun hash-capability (capability) (capability-hash capability))

(defun capability-to-string (capability)
  (typecase capability
    (cap-filesystem
     (format nil "#<cap fs ~A :~A>"
             (canonical-path-to-string (cap-filesystem-path capability))
             (fs-mode-name (cap-filesystem-mode capability))))
    (cap-network
     (format nil "#<cap net ~A~@[:~D~]>"
             (%cap-network-host capability) (%cap-network-port capability)))
    (cap-secret
     (format nil "#<cap secret ~A>"
             (canonical-path-to-string (cap-secret-path capability))))
    (cap-process "#<cap process>")
    (cap-compose
     (format nil "#<cap compose ~D>"
             (length (cap-compose-capabilities capability))))
    (cap-restrict
     (format nil "#<cap restrict ~A~@[ :~A~]>"
             (canonical-path-to-string (cap-restrict-scope capability))
             (and (cap-restrict-mode capability)
                  (fs-mode-name (cap-restrict-mode capability)))))
    (cap-none "#<cap none>")))

(defun capability-check (capability operation target)
  (ecase operation
    (:read (capability-check-fs-read-p capability target))
    (:write (capability-check-fs-write-p capability target))
    (:network (destructuring-bind (host &optional port) target
                (capability-check-network-p capability host port)))
    (:secret (capability-check-secret-p capability target))
    (:process (capability-check-process-p capability))))
(defun capability-allows-p (capability operation target)
  (capability-check capability operation target))

;;; Exhaustiveness/probe seams used by the kernel property harness.
(deftype cap-tag () '(member :ct-none :ct-filesystem :ct-network :ct-secret
                             :ct-process :ct-compose :ct-restrict))
(defparameter *all-cap-tags*
  '(:ct-none :ct-filesystem :ct-network :ct-secret :ct-process :ct-compose
    :ct-restrict))
(defparameter *atomic-cap-tags*
  '(:ct-none :ct-filesystem :ct-network :ct-secret :ct-process))
(defun all-cap-tags () (copy-list *all-cap-tags*))
(defun atomic-cap-tags () (copy-list *atomic-cap-tags*))
(defun cap-kind (capability)
  (ecase (capability-kind capability)
    (:none :ct-none) (:filesystem :ct-filesystem) (:network :ct-network)
    (:secret :ct-secret) (:process :ct-process) (:compose :ct-compose)
    (:restrict :ct-restrict)))
(defun capability-cap-kind (capability) (cap-kind capability))

(defparameter *cap-test-paths* #("/g" "/g/a" "/g/a/b" "/g/x" "/h" "/"))
(defparameter *cap-test-hosts* #("*" "example.com" "other.net"))
(defparameter *cap-test-ports* #(nil 80 443))
(defparameter *cap-test-modes* #(:read :write :read-write))
(defun random-cap-choice (state vector)
  (aref vector (random (length vector) state)))
(defun gen-cap (state depth)
  (labels ((atomic ()
             (ecase (random-cap-choice state
                                        #(:ct-none :ct-filesystem :ct-network
                                          :ct-secret :ct-process))
               (:ct-none (make-cap-none))
               (:ct-filesystem
                (%make-cap-filesystem
                 (canonicalize-path
                  (random-cap-choice state *cap-test-paths*) :realpath #'identity)
                 (random-cap-choice state *cap-test-modes*)))
               (:ct-network
                (%make-cap-network
                 (copy-seq (random-cap-choice state *cap-test-hosts*))
                 (random-cap-choice state *cap-test-ports*)))
               (:ct-secret
                (%make-cap-secret
                 (canonicalize-path
                  (random-cap-choice state *cap-test-paths*) :realpath #'identity)))
               (:ct-process (make-cap-process))))
           (make-at-depth (d)
             (if (<= d 0)
                 (atomic)
                 (ecase (random-cap-choice state
                                            #(:ct-none :ct-filesystem :ct-network
                                              :ct-secret :ct-process :ct-compose
                                              :ct-restrict))
                   (:ct-none (make-cap-none))
                   (:ct-filesystem (atomic))
                   (:ct-network (atomic))
                   (:ct-secret (atomic))
                   (:ct-process (atomic))
                   (:ct-compose
                    (compose-capabilities
                     (loop repeat (+ 1 (random 3 state))
                           collect (make-at-depth (1- d)))))
                   (:ct-restrict
                    (restrict-capability
                     (make-at-depth (1- d))
                     (canonicalize-path
                      (random-cap-choice state *cap-test-paths*) :realpath #'identity)
                     :mode (unless (zerop (random 2 state))
                             (random-cap-choice state *cap-test-modes*))))))))
    (make-at-depth depth)))

(defun cap-probe-vector (capability)
  (let ((root (canonicalize-path "/" :realpath #'identity)))
    (list (capability-check-fs-read-p capability root)
          (capability-check-fs-write-p capability root)
          (capability-check-network-p capability "*" nil)
          (capability-check-network-p capability "example.com" 80)
          (capability-check-secret-p capability root)
          (capability-check-process-p capability))))
(defun cap-subseteq-probes (a b)
  (every #'identity
         (mapcar (lambda (x y) (or (not x) y))
                 (cap-probe-vector a) (cap-probe-vector b))))
