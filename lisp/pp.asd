;;;; ASDF definitions for the saved-image Common Lisp implementation.

(asdf:defsystem "pp/kernel"
  :description "Durable-safe pp kernel data and identity operations"
  :serial t
  :components
  ((:file "packages")
   (:module "kernel"
    :serial t
    :components
    ((:file "identity-types")
     (:file "source")
     (:file "paths")
     (:file "hasher")
     (:file "core-model")
     (:file "capability")
     (:file "cap-token")
     (:file "cell")
     (:file "identity")
     (:file "codec")))))

(asdf:defsystem "pp/frontend"
  :description "pp source frontend"
  :depends-on ("pp/kernel")
  :serial t
  :components
  ((:module "frontend"
    :serial t
    :components ((:file "frontend")))))

(asdf:defsystem "pp/runtime"
  :description "pp language runtime, evaluator, durable store, effects, observations, cache, nodes, artifacts, distribution, lifecycle, and session state"
  :depends-on ("pp/frontend")
  :serial t
  :components
  ((:module "runtime"
    :serial t
    :components
    ((:file "protocol")
     (:file "language")
     (:file "primitives")
     (:module "evaluator-support"
      :serial t
      :components ((:file "state")))
     (:file "evaluator")
     (:file "dynamic-scope")
     (:file "session")
     (:file "store")
     (:file "artifacts")
     (:file "effects")
     (:file "configuration")
     (:file "observations")
     (:file "cache")
     (:file "nodes")
     (:file "distribution")
     (:module "lifecycle-support"
      :pathname "lifecycle"
      :serial t
      :components
      ((:file "journal")
       (:file "executor")
       (:file "process")
       (:file "sandbox")
       (:file "island")
       (:file "domains")
       (:file "fenced")
       (:file "watch")))
     (:file "lifecycle")))))

(asdf:defsystem "pp/app"
  :description "pp command-line application"
  :depends-on ("pp/runtime")
  :serial t
  :components
  ((:module "app"
    :serial t
    :components ((:file "main")))))

(asdf:defsystem "pp"
  :description "Saved-image pp Common Lisp implementation"
  :depends-on ("pp/app"))
