(lang dune 3.0)
(name pp)
(version 0.2.0-dev)
(generate_opam_files true)

(package
 (name pp)
 (synopsis "A content-addressed, capability-scoped Lisp")
 (description
  "pp is a content-addressed, capability-scoped Lisp with a single \
   tree-walking evaluator. See README.md and docs/ for details.")
 (authors "Pranav Rao")
 (maintainers "Pranav Rao")
 (license MIT)
 (homepage "https://github.com/pranavra0/pp")
 (bug_reports "https://github.com/pranavra0/pp/issues")
 (source (uri "git+https://github.com/pranavra0/pp.git"))
 (depends
  (ocaml (>= 5.1))
  dune-build-info
  cryptokit))
