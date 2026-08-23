(in-package :pp.kernel)

;;; A small, dependency-free SHA-256 implementation.  All intermediate words
;;; are explicitly reduced to 32 bits; this is portable across Lisp fixnum
;;; widths and does not rely on host hash tables or printed objects.
(defconstant +u32-mask+ #xffffffff)
(defconstant +u32-modulus+ #x100000000)

(defun u32 (x) (logand x +u32-mask+))
(defun rotr32 (x n)
  (let ((x (u32 x)))
    (u32 (logior (ash x (- n)) (ash x (- 32 n))))))
(defun sha-ch (x y z) (logxor (logand x y) (logand (lognot x) z)))
(defun sha-maj (x y z) (logxor (logand x y) (logand x z) (logand y z)))
(defun sha-big-sigma0 (x) (logxor (rotr32 x 2) (rotr32 x 13) (rotr32 x 22)))
(defun sha-big-sigma1 (x) (logxor (rotr32 x 6) (rotr32 x 11) (rotr32 x 25)))
(defun sha-small-sigma0 (x) (logxor (rotr32 x 7) (rotr32 x 18) (ash (u32 x) -3)))
(defun sha-small-sigma1 (x) (logxor (rotr32 x 17) (rotr32 x 19) (ash (u32 x) -10)))

(defparameter +sha256-k+
  #( #x428a2f98 #x71374491 #xb5c0fbcf #xe9b5dba5 #x3956c25b #x59f111f1
     #x923f82a4 #xab1c5ed5 #xd807aa98 #x12835b01 #x243185be #x550c7dc3
     #x72be5d74 #x80deb1fe #x9bdc06a7 #xc19bf174 #xe49b69c1 #xefbe4786
     #x0fc19dc6 #x240ca1cc #x2de92c6f #x4a7484aa #x5cb0a9dc #x76f988da
     #x983e5152 #xa831c66d #xb00327c8 #xbf597fc7 #xc6e00bf3 #xd5a79147
     #x06ca6351 #x14292967 #x27b70a85 #x2e1b2138 #x4d2c6dfc #x53380d13
     #x650a7354 #x766a0abb #x81c2c92e #x92722c85 #xa2bfe8a1 #xa81a664b
     #xc24b8b70 #xc76c51a3 #xd192e819 #xd6990624 #xf40e3585 #x106aa070
     #x19a4c116 #x1e376c08 #x2748774c #x34b0bcb5 #x391c0cb3 #x4ed8aa4a
     #x5b9cca4f #x682e6ff3 #x748f82ee #x78a5636f #x84c87814 #x8cc70208
     #x90befffa #xa4506ceb #xbef9a3f7 #xc67178f2))

 (defun string-octets (string)
  "Encode a Lisp string as its canonical UTF-8 byte sequence."
  (let ((out (make-array 0 :element-type '(unsigned-byte 8)
                           :adjustable t :fill-pointer 0)))
    (check-type string string)
    (labels ((put (x) (vector-push-extend (logand x #xff) out)))
      (loop for c across string
            for n = (char-code c)
            do (cond ((<= n #x7f) (put n))
                     ((<= n #x7ff) (put (+ #xc0 (ash n -6)))
                                  (put (+ #x80 (logand n #x3f))))
                     ((<= n #xffff) (put (+ #xe0 (ash n -12)))
                                   (put (+ #x80 (logand (ash n -6) #x3f)))
                                   (put (+ #x80 (logand n #x3f))))
                     ((<= n #x10ffff) (put (+ #xf0 (ash n -18)))
                        (put (+ #x80 (logand (ash n -12) #x3f)))
                        (put (+ #x80 (logand (ash n -6) #x3f)))
                        (put (+ #x80 (logand n #x3f))))
                     (t (error "Invalid Unicode code point ~D" n)))))
    out))

(defun canonical-integer-string (integer)
  "Decimal output independent of *PRINT-BASE* and locale settings."
  (check-type integer integer)
  (format nil "~D" integer))

(defun octet-word (bytes i)
  (u32 (logior (ash (aref bytes i) 24)
               (ash (aref bytes (+ i 1)) 16)
               (ash (aref bytes (+ i 2)) 8)
               (aref bytes (+ i 3)))))

(defun sha256-octets (input)
  (let* ((length (length input))
         (bit-length (* length 8))
         (padded-length (* 64 (ceiling (+ length 9) 64)))
         (bytes (make-array padded-length :element-type '(unsigned-byte 8)
                            :initial-element 0)))
    (replace bytes input)
    (setf (aref bytes length) #x80)
    (loop for j from 0 below 8
          do (setf (aref bytes (- padded-length 1 j))
                   (ldb (byte 8 (* j 8)) bit-length)))
    (let ((h (vector #x6a09e667 #xbb67ae85 #x3c6ef372 #xa54ff53a
                     #x510e527f #x9b05688c #x1f83d9ab #x5be0cd19))
          (w (make-array 64 :element-type '(unsigned-byte 32))))
      (loop for base from 0 below padded-length by 64 do
        (loop for i from 0 below 16 do (setf (aref w i) (octet-word bytes (+ base (* i 4)))))
        (loop for i from 16 below 64 do
          (setf (aref w i)
                (u32 (+ (sha-small-sigma1 (aref w (- i 2)))
                        (aref w (- i 7))
                        (sha-small-sigma0 (aref w (- i 15)))
                        (aref w (- i 16))))))
        (let ((state (vector (aref h 0) (aref h 1) (aref h 2) (aref h 3)
                             (aref h 4) (aref h 5) (aref h 6) (aref h 7))))
          (loop for i from 0 below 64 do
            (let* ((a (aref state 0)) (b (aref state 1)) (c (aref state 2))
                   (d (aref state 3)) (e (aref state 4)) (f (aref state 5))
                   (g (aref state 6)) (hh (aref state 7))
                   (t1 (u32 (+ hh (sha-big-sigma1 e) (sha-ch e f g)
                                 (aref +sha256-k+ i) (aref w i))))
                   (t2 (u32 (+ (sha-big-sigma0 a) (sha-maj a b c)))))
              (setf (aref state 0) (u32 (+ t1 t2))
                    (aref state 1) a
                    (aref state 2) b
                    (aref state 3) c
                    (aref state 4) (u32 (+ d t1))
                    (aref state 5) e
                    (aref state 6) f
                    (aref state 7) g)))
          (loop for i from 0 below 8 do
            (setf (aref h i) (u32 (+ (aref h i) (aref state i))))))
      )
      (let ((hex "0123456789abcdef")
            (out (make-string 64)))
        (loop for i from 0 below 8
              for word = (aref h i)
              do (loop for j from 0 below 8
                       for nibble = (ldb (byte 4 (* (- 7 j) 4)) word)
                       do (setf (char out (+ (* i 8) j)) (char hex nibble))))
        out))))

(defun hash-string (string) (sha256-octets (string-octets string)))

(defun hash-concat (parts)
  (let ((out (make-array 0 :element-type '(unsigned-byte 8)
                           :adjustable t :fill-pointer 0)))
    (labels ((put (x) (vector-push-extend (logand x #xff) out))
             (put-string (s) (loop for x across (string-octets s) do (put x))))
      (dolist (part parts)
        (check-type part string)
        (let ((bytes (string-octets part)))
          (put-string (canonical-integer-string (length bytes)))
          (put (char-code #\:))
          (loop for x across bytes do (put x)))))
    (sha256-octets out)))

(defun node-key-skeleton (expr-hash free-variable-hashes)
  (check-type expr-hash string)
  (hash-concat (cons "node-key" (cons expr-hash free-variable-hashes))))
