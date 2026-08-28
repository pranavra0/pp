;;;; Direct SBCL bootstrap entrypoint for the canonical pp build request.
(require :asdf)
(asdf:load-asd (truename "lisp/pp.asd"))
(asdf:load-system "pp")
(sb-ext:save-lisp-and-die
 (sb-ext:posix-getenv "PP_TEMP_IMAGE")
 :toplevel #'pp.app:main
 :executable t
 :save-runtime-options t
 :purify t
 :compression 9)
