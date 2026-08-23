;;;; Package boundaries for the Common Lisp implementation.
;;;; User pp text is never read by the host reader; readers belong to the
;;;; explicit pp.frontend character/token boundary.
;; The store uses SBCL's POSIX fsync/rename/lockf bindings for its explicit
;; process-safe boundary.  Load the implementation package before cached FASLs
;; are read in the no-userinit saved-image build.
(eval-when (:compile-toplevel :load-toplevel :execute)
  #+sbcl (require :sb-posix))

(defpackage #:pp.kernel
  (:use #:cl)
  (:shadow #:position)
  (:export
   ;; Distinct durable identity wrappers.
   #:node-key #:cache-key #:object-hash #:observed-hash #:cell-id
   #:make-node-key #:make-cache-key #:make-object-hash
   #:make-observed-hash #:make-cell-id #:cache-key-from-node-key
   #:node-key-of-string #:node-key-to-string #:cache-key-of-string
   #:cache-key-of-node-key #:cache-key-to-string #:object-hash-of-digest
   #:object-hash-to-string #:observed-hash-of-digest
   #:observed-hash-to-string #:cell-id-of-string #:cell-id-to-string
   #:node-key-string #:cache-key-string #:object-hash-string
   #:observed-hash-string #:cell-id-string
   ;; Source locations and paths.
   #:position #:position-offset #:position-line #:position-column
   #:make-position #:source-range #:source-range-source
   #:source-range-path #:source-range-start #:source-range-end
   #:make-source-range #:source-range-point #:source-range-format
   #:source-range-format-start #:source-range-equal #:source-range-empty-p
   #:compare-positions #:canonicalize-path #:path-under #:path-under-p
   #:canonical-path #:canonical-path-string #:canonical-path-to-string
   ;; Framing, canonical numeric data, and identity operations.
   #:string-octets #:sha256-octets #:canonical-integer-string
   #:hash-string #:hash-concat #:node-key-skeleton
   #:canonical-float-nan-p #:canonical-float-string
   #:hash-expr #:hash-pattern #:hash-value #:free-variable-names
   #:equal-value #:same-content #:node-key
   ;; Canonical text codec seams.
   #:quote-string #:parse-quoted-string #:decode-hex-float
   #:encode-value #:decode-value #:canonical-map-entries
   #:canonical-set-elements
   ;; Explicit core model constructors, types, and accessors.
   #:env #:make-env #:env-bindings #:env-env-id #:env-env-hash
   #:pattern-literal #:pattern-variable #:pattern-wildcard #:pattern-list
   #:pattern-tagged #:make-pliteral #:make-pvariable #:make-pwildcard
   #:make-plist #:make-ptagged #:pattern-literal-value #:pattern-variable-name
   #:pattern-list-patterns #:pattern-list-rest #:pattern-tagged-tag
   #:pattern-tagged-patterns
   #:expr-literal #:expr-symbol #:expr-if #:expr-let #:expr-fn #:expr-apply
   #:expr-quote #:expr-force #:expr-with-caps #:expr-perform
   #:expr-with-handler #:expr-delay #:expr-node #:expr-defnode #:expr-do
   #:expr-def #:expr-defvalue #:expr-letstar #:expr-module #:expr-import
   #:expr-load #:expr-loadmodule #:expr-island #:expr-with-config
   #:expr-config #:expr-typed #:expr-located #:expr-match
   #:make-eliteral #:make-esymbol #:make-eif #:make-elet #:make-efn
   #:make-eapply #:make-equote #:make-eforce #:make-ewith-caps
   #:make-eperform #:make-ewith-handler #:make-edelay #:make-enode
   #:make-edefnode #:make-edo #:make-edef #:make-edefvalue #:make-eletstar
   #:make-emodule #:make-eimport #:make-eload #:make-eloadmodule
   #:make-eisland #:make-ewith-config #:make-econfig #:make-typed
   #:make-elocated #:make-ematch
   #:expr-literal-value #:expr-symbol-name
   #:expr-if-condition #:expr-if-then #:expr-if-else
   #:expr-let-bindings #:expr-let-body #:expr-fn-params #:expr-fn-body
   #:expr-apply-function #:expr-apply-arguments #:expr-quote-expression
   #:expr-force-expression #:expr-with-caps-caps #:expr-with-caps-body
   #:expr-perform-name #:expr-perform-arguments
   #:expr-with-handler-handlers #:expr-with-handler-body
   #:expr-delay-expression #:expr-node-expression
   #:expr-defnode-name #:expr-defnode-params #:expr-defnode-body
   #:expr-do-expressions #:expr-def-name #:expr-def-params #:expr-def-body
   #:expr-defvalue-name #:expr-defvalue-expression
   #:expr-letstar-bindings #:expr-letstar-body
   ;; Accessors for the less-common expression forms used by the frontend.
   #:expr-module-expressions #:expr-import-expression
   #:expr-load-path #:expr-loadmodule-path
   #:expr-island-uri #:expr-island-pin
   #:expr-with-config-map-expression #:expr-with-config-body
   #:expr-config-key-expression #:expr-config-default
   #:expr-typed-expression #:expr-typed-type
   #:expr-located-expression #:expr-located-range
   #:expr-match-scrutinee #:expr-match-arms
   #:closure #:make-closure #:closure-fn-name #:closure-params
   #:closure-body #:closure-env #:closure-closure-kind
   #:closure-kind-function #:closure-kind-node
   #:make-closure-kind-function #:make-closure-kind-node
   #:thunk #:make-thunk #:thunk-status #:thunk-hash #:thunk-expression
   #:thunk-environment #:thunk-name #:thunk-type-ann #:thunk-location
   #:thunk-config-hash #:thunk-kind
   #:thunk-kind-ephemeral #:thunk-kind-persistent
   #:make-ephemeral-thunk-kind #:make-persistent-thunk-kind
   #:thunk-kind-persistent-captured-caps
   #:thunk-kind-persistent-argument-values
   #:make-vpersistent-thunk-kind
   #:thunk-status-unevaluated #:thunk-status-evaluating
   #:thunk-status-evaluated #:make-thunk-status-unevaluated
   #:make-thunk-status-evaluating #:make-thunk-status-evaluated
   #:thunk-status-evaluated-value
   #:value-nil #:value-bool #:value-int #:value-float #:value-string
   #:value-keyword #:value-symbol #:value-pair #:value-vector #:value-map
   #:value-set #:value-closure #:value-builtin #:value-capability
   #:value-thunk #:value-env-map #:value-sealed
   #:make-vnil #:make-vbool #:make-vint #:make-vfloat #:make-vstring
   #:make-vkeyword #:make-vsymbol #:make-vpair #:make-vvector
   #:make-vvector-from-list #:make-vmap #:make-vset #:make-vclosure
   #:make-vbuiltin #:make-vcapability #:make-vthunk #:make-venvmap
   #:make-vsealed
   #:value-bool-value #:value-int-value #:value-float-value
   #:value-string-value #:value-keyword-value #:value-symbol-value
   #:value-pair-car #:value-pair-cdr #:value-vector-values
   #:value-map-entries #:value-set-values #:value-closure-closure
   #:value-builtin-name #:value-builtin-implementation
   #:value-capability-capability #:value-thunk-thunk
   #:value-env-map-bindings #:value-sealed-bytes
   ;; Capabilities and observation cells.
   #:fs-mode #:capability #:cap-filesystem #:cap-network #:cap-secret #:cap-process
   #:cap-compose #:cap-restrict #:cap-none
   #:make-capability #:make-cap-process #:make-cap-none #:no-capability
   #:*no-capability* #:capability-kind #:capability-name
   #:capability-token #:capability-rights
   #:cap-filesystem-path #:cap-filesystem-mode
   #:cap-network-host #:cap-network-port #:cap-secret-path
   #:cap-compose-capabilities #:cap-restrict-cap #:cap-restrict-scope
   #:cap-restrict-mode
   #:mint-capability #:compose-capabilities #:restrict-capability
   #:capability-allows-p #:capability-check #:capability-check-fs
   #:capability-check-fs-read-p #:capability-check-fs-write-p
   #:capability-check-network-p #:capability-check-secret-p
   #:capability-check-process-p #:capability-hash #:hash-capability
   #:capability-to-string #:capability-path-grants-p
   #:fs-mode-name #:fs-mode-code #:fs-mode-allows-p #:fs-mode-intersect
   #:capability-list-fs-paths #:list-fs-paths #:mode-name #:mode-intersect
   #:capability-subseteq #:capability-subseteq-p #:subseteq
   #:cap-tag #:*all-cap-tags* #:*atomic-cap-tags*
   #:all-cap-tags #:atomic-cap-tags #:cap-kind #:capability-cap-kind
   #:gen-cap #:cap-probe-vector #:cap-subseteq-probes
   #:cell #:make-cell #:cell-kind #:cell-data #:cell-serialize #:cell-parse
   #:serialize-cell #:parse-cell
   #:cell-file #:cell-runtime-file #:cell-tool #:cell-tree #:cell-stat
   #:cell-env #:cell-argv #:cell-config #:cell-handler #:cell-probe
   #:cell-sealed #:cell-node #:cell-domain #:cell-unknown
   #:cell-file-value #:cell-runtime-file-value #:cell-tool-value
   #:cell-tree-value #:cell-stat-value #:cell-env-value
   #:cell-config-value #:cell-handler-value #:cell-probe-value
   #:cell-sealed-value #:cell-node-value #:cell-domain-name
   #:cell-domain-sub #:cell-unknown-value
   #:make-cell-file #:make-cell-runtime-file #:make-cell-tool #:make-cell-tree
   #:make-cell-stat #:make-cell-env #:make-cell-argv #:make-cell-config
   #:make-cell-handler #:make-cell-probe #:make-cell-sealed #:make-cell-node
   #:make-cell-domain #:make-cell-unknown
   ;; Cluster capability-token boundary.
   #:cluster-dir #:secret-path #:id-path #:write-secret-file
   #:load-secret #:load-cluster-id
   #:mint-capability-token #:cap-token-parse #:verify-capability-token
   #:token-to-caps #:mint-token #:verify-token #:token-to-capabilities))

(in-package #:pp.kernel)

;; SOURCE.LISP owns the `position` structure.  Keep the host sequence
;; operation available under the same package while avoiding a package-lock
;; violation; kernel code that needs CL:POSITION can use this forwarding
;; function without reading pp source.
(defun position (&rest arguments)
  (apply #'cl:position arguments))

(defpackage #:pp.frontend
  (:use #:cl #:pp.kernel)
  ;; These wrappers preserve the frontend's narrow boundary while the
  ;; corresponding fixed kernel accessors remain available to other clients.
  (:shadow #:position
           #:expr-located-expression #:expr-located-range
           #:expr-module-expressions #:expr-import-expression
           #:expr-load-path #:expr-loadmodule-path
           #:expr-island-uri #:expr-island-pin
           #:expr-with-config-map-expression #:expr-with-config-body
           #:expr-config-key-expression #:expr-config-default
           #:expr-typed-expression #:expr-typed-type)
  (:export #:read-source #:read-stdin #:print-source
           #:read-string #:print-program
           #:scan-comments #:splice-comments #:surface-tables
           #:lint-source
           #:frontend-error #:frontend-error-code #:frontend-error-message
           #:frontend-error-range #:frontend-error-incomplete-p))

(defpackage #:pp.runtime
  (:use #:cl #:pp.kernel #:pp.frontend)
  (:shadow #:position)
  (:export
   ;; Pure language services.  These accept/return pp.kernel values and ASTs;
   ;; they never delegate to host READ, EVAL, or symbol interning.
   #:language-error #:language-error-code #:language-error-message
   #:language-fail
   #:proper-value-list #:proper-value-list-p #:value-list #:pair-values
   #:runtime-free-variable-names #:runtime-pattern-bound-names
   #:runtime-quote-pattern #:runtime-quote-to-value
   #:runtime-value-to-expr #:runtime-value-to-pattern
   #:runtime-match-pattern #:runtime-pattern-match-p
   #:runtime-string-of-value #:runtime-string-like
   #:runtime-parse-number-string
   #:runtime-expand-expression #:runtime-expand-toplevel
   #:runtime-relocate
   ;; Deterministic primitive and macro catalogs.
   #:runtime-primitive-shape #:make-runtime-primitive-shape
   #:runtime-primitive-shape-kind #:runtime-primitive-shape-minimum
   #:runtime-primitive-shape-maximum
   #:runtime-shape-any #:runtime-shape-exact #:runtime-shape-range
   #:runtime-primitive-descriptor #:make-runtime-primitive-descriptor
   #:runtime-primitive-descriptor-name
   #:runtime-primitive-descriptor-shape
   #:runtime-primitive-descriptor-category
   #:runtime-primitive-descriptor-implementation
   #:runtime-primitive-catalog #:make-runtime-primitive-catalog
   #:runtime-primitive-catalog-declarations
   #:runtime-primitive-catalog-entries
   #:runtime-primitive-catalog-aliases
   #:runtime-primitive-catalog-builtins
   #:runtime-primitive-catalog-finalized-p
   #:runtime-primitive-catalog-gensym-counter
   #:runtime-primitive-register #:runtime-primitive-alias
   #:runtime-primitive-finalize #:runtime-primitive-lookup
   #:runtime-primitive-initial-env #:runtime-primitive-render
   #:runtime-primitive-call #:runtime-install-pure-primitives
   #:runtime-macro-definition #:make-runtime-macro-definition
   #:runtime-macro-definition-name #:runtime-macro-definition-params
   #:runtime-macro-definition-body
   #:runtime-macro-state #:make-runtime-macro-state
   #:runtime-macro-state-macros #:runtime-macro-state-expansion-count
   #:runtime-macro-state-max-expansions
   #:runtime-macro-services #:make-runtime-macro-services
   #:runtime-macro-services-eval #:runtime-macro-services-force-deep
   #:runtime-macro-services-initial-env
   #:runtime-macro-set #:runtime-macro-find
   ;; Explicit evaluator state and one continuation/work-stack machine.
   #:runtime-evaluator-state #:runtime-evaluator-default-state
   #:make-runtime-evaluator
   #:runtime-evaluator-state-catalog #:runtime-evaluator-state-initial-env
   #:runtime-evaluator-state-macro-state
   #:runtime-evaluator-state-max-depth
   #:runtime-evaluator-state-depth
   #:runtime-evaluator-state-force-stack #:runtime-evaluator-state-force-count
   #:runtime-evaluator-state-persistent-cache
   #:runtime-evaluator-state-capabilities
   #:runtime-evaluator-state-config-stack
   #:runtime-evaluator-state-handler-stack
   #:runtime-evaluator-state-perform-function
   #:runtime-evaluator-state-with-capabilities-function
   #:runtime-evaluator-state-with-handlers-function
   #:runtime-evaluator-state-with-config-function
   #:runtime-evaluator-state-load-function
   #:runtime-evaluator-state-load-module-function
   #:runtime-evaluator-state-island-function
   #:runtime-evaluator-state-node-force-function
   #:runtime-evaluator-eval #:runtime-evaluator-eval-expressions
   #:runtime-evaluator-run-expression
   #:runtime-evaluator-force #:runtime-evaluator-force-deep
   #:runtime-evaluator-apply-value #:runtime-evaluator-node-key
   #:runtime-evaluator-expand-expression #:runtime-evaluator-expand-toplevel
   #:runtime-evaluator-services
   #:runtime-evaluator-depth-leave!
   ;; Immutable operation views and explicit session lifecycle/state.
   #:runtime-core-operations #:make-runtime-core-operations
   #:runtime-core-operations-force #:runtime-core-operations-eval
   #:runtime-core-operations-apply
   #:runtime-node-operations #:make-runtime-node-operations
   #:runtime-node-operations-key-of #:runtime-node-operations-run-body
   #:runtime-node-operations-resolve-hit #:runtime-node-operations-data-closed
   #:runtime-operations #:make-runtime-operations
   #:runtime-operations-core #:runtime-operations-node
   #:runtime-session #:make-runtime-session
   #:runtime-session-operations #:runtime-session-node-runtime
   #:runtime-session-runtime-context #:runtime-session-evaluator-state
   #:runtime-session-evaluation #:runtime-session-domains
   #:runtime-session-run #:runtime-session-fenced
   #:runtime-session-services
   #:runtime-session-evaluator #:runtime-session-operations-view
   #:runtime-session-core-operations #:runtime-session-node-operations
   #:runtime-session-scheduler #:runtime-session-executor
   #:runtime-session-remote-dispatch #:runtime-session-schedule-locked-p
   #:runtime-session-force #:runtime-session-call
   #:runtime-session-register-service #:runtime-session-unregister-service
   #:runtime-session-find-service #:runtime-session-service
   #:runtime-session-call-service #:runtime-session-register-callback
   #:runtime-session-register-callbacks
   #:runtime-session-reset-pass-state #:runtime-session-reset-evaluator-state
   #:runtime-session-begin-pass #:runtime-session-begin-evaluation
   #:runtime-session-begin-watch
   #:runtime-session-global-env
   #:runtime-session-find-thunk #:runtime-session-add-thunk
   #:runtime-session-find-macro #:runtime-session-set-macro
   #:runtime-session-next-gensym
   #:runtime-session-find-domain #:runtime-session-register-domain
   #:runtime-session-register-probe #:runtime-session-fold-domains
   #:runtime-session-find-probe #:runtime-session-set-probe
   #:runtime-session-preseed-probe #:runtime-session-iter-probes
   #:runtime-session-find-sealed-pin #:runtime-session-set-sealed-pin
   #:runtime-session-observations #:runtime-session-add-observation
   #:runtime-session-clear-observations #:runtime-session-add-event
   #:runtime-session-events #:runtime-session-register-reporter
   #:runtime-session-reporters #:runtime-session-set-runtime-manifest
   #:runtime-session-runtime-manifest #:runtime-session-add-wanted-node
   #:runtime-session-wanted-nodes #:runtime-session-add-fenced-action
   #:runtime-session-take-fenced-actions #:runtime-session-find-run-pin
   #:runtime-session-set-run-pin #:runtime-session-preseed-run-pin
   #:runtime-session-remove-run-pin #:runtime-session-iter-run-pins
   #:runtime-session-set-node-thunk #:runtime-session-find-node-thunk
   #:runtime-session-node-key #:runtime-session-node-key-by-id
   #:runtime-session-add-node-dependent #:runtime-session-iter-node-dependents
   #:runtime-session-force-path #:runtime-session-set-force-path
   #:runtime-session-next-cache-bust #:runtime-session-fenced-epoch
   #:runtime-session-start-fenced-epoch #:runtime-session-resume-fenced-epoch
   #:runtime-session-clear-fenced-epoch
   #:runtime-session-next-fenced-epoch-nonce
   ;; Dynamic extent stacks.  The current scope is accessed through functions,
   ;; not by exposing the special variable as a mutable package API.
   #:runtime-effect-frame #:make-runtime-effect-frame
   #:runtime-effect-frame-name #:runtime-effect-frame-function
   #:runtime-handler-frame #:make-runtime-handler-frame
   #:runtime-handler-frame-name #:runtime-handler-frame-function
   #:runtime-handler-frame-hash
   #:runtime-node-frame #:make-runtime-node-frame
   #:runtime-node-frame-key #:runtime-node-frame-persistent
   #:runtime-node-frame-sandbox
   #:runtime-dynamic-scope #:runtime-dynamic-scope-new
   #:runtime-dynamic-scope-session #:runtime-dynamic-scope-invocation
   #:runtime-dynamic-scope-effects #:runtime-dynamic-scope-capabilities
   #:runtime-dynamic-scope-configs #:runtime-dynamic-scope-handlers
   #:runtime-dynamic-scope-nodes #:runtime-dynamic-scope-domains
   #:runtime-dynamic-scope-observations #:runtime-dynamic-scope-services
   #:runtime-dynamic-scope-in-node #:runtime-dynamic-scope-sandbox
   #:runtime-dynamic-current #:runtime-dynamic-session
   #:runtime-dynamic-with-scope #:runtime-dynamic-with-top-level
   #:runtime-dynamic-with-session
   #:runtime-dynamic-push #:runtime-dynamic-pop
   #:runtime-dynamic-with-stack
   #:runtime-dynamic-push-effects #:runtime-dynamic-pop-effects
   #:runtime-dynamic-push-capabilities #:runtime-dynamic-pop-capabilities
   #:runtime-dynamic-push-config #:runtime-dynamic-pop-config
   #:runtime-dynamic-push-handlers #:runtime-dynamic-pop-handlers
   #:runtime-dynamic-push-node #:runtime-dynamic-pop-node
   #:runtime-dynamic-push-domain #:runtime-dynamic-pop-domain
   #:runtime-dynamic-push-observation-collection
   #:runtime-dynamic-pop-observation-collection
   #:runtime-dynamic-with-effects #:runtime-dynamic-with-capabilities
   #:runtime-dynamic-with-config #:runtime-dynamic-with-handlers
   #:runtime-dynamic-with-node #:runtime-dynamic-with-domain
   #:runtime-dynamic-with-observation-collection
   #:runtime-dynamic-with-tail-capabilities #:runtime-dynamic-with-tail-config
   #:runtime-dynamic-with-tail-handlers
   #:runtime-dynamic-effects #:runtime-dynamic-capabilities
   #:runtime-dynamic-config #:runtime-dynamic-handlers
   #:runtime-dynamic-nodes #:runtime-dynamic-domains
   #:runtime-dynamic-observation-collection-p #:runtime-dynamic-in-node-p
   #:runtime-dynamic-current-node #:runtime-dynamic-current-domain
   #:runtime-dynamic-config-lookup #:runtime-dynamic-find-handler
   #:runtime-dynamic-handler-identities #:runtime-dynamic-find-effect
   #:runtime-dynamic-perform #:runtime-dynamic-find-service
   #:runtime-dynamic-register-service #:runtime-dynamic-call-service
   #:runtime-dynamic-with-service #:runtime-dynamic-service
   #:runtime-dynamic-record-read #:runtime-dynamic-record-event
   #:runtime-dynamic-record-node-force
   #:runtime-dynamic-observe-config #:runtime-dynamic-observe-handler
   #:runtime-dynamic-invocation #:runtime-dynamic-current-sandbox
   #:runtime-dynamic-require-script-tier
   #:runtime-dynamic-without-observations
   #:runtime-dynamic-tail-capabilities-at
   #:runtime-dynamic-tail-capability-depth
   #:runtime-dynamic-tail-handler-identities
   #:runtime-dynamic-tail-lookup-handler
   ;; Durable store and repository boundary. These APIs accept canonical
   ;; pp.kernel values/octets only; no host persistence objects are exposed.
   #:store-octets #:store-copy-octets #:store-string-octets #:store-octets-string
   #:store-content-octets #:store-hash-octets #:store-hash-content
   #:store-digest-p #:store-identity-string
   #:store-atomic-write-octets #:store-atomic-replace
   #:store-read-octets #:store-read-text
   #:store-absolute-path #:store-directory-pathname #:store-canonical-path
   #:store-ensure-directory #:store-valid-name-p #:+store-version+
   #:store-layout #:store-layout-p #:make-store-layout #:store-layout-of-root
   #:store-layout-root #:store-split-lines #:store-layout-area-name
   #:store-layout-area #:store-layout-path #:store-layout-ensure-area
   #:store-layout-list #:store-layout-list-names #:store-layout-remove
   #:store-layout-clear-dir #:store-layout-read-store #:store-layout-init
   #:store-lock-fd #:store-with-lock
   #:store-layout-with-lifecycle #:store-layout-with-lifecycle-read
   #:store-layout-with-lifecycle-write
   #:object-repository #:object-repository-p #:make-object-repository
   #:object-repository-create #:object-repository-layout
   #:object-repository-write #:object-repository-put-verified
   #:object-repository-put #:object-repository-put-fenced
   #:object-repository-get-verified #:object-repository-get
   #:object-repository-get-fenced #:object-repository-keys
   #:blob-repository #:blob-repository-p #:make-blob-repository
   #:blob-repository-create #:blob-repository-layout
   #:blob-repository-put #:blob-repository-get #:blob-repository-get-string
   #:blob-repository-keys
   #:store-trace #:store-trace-p #:make-store-trace
   #:store-trace-outcome #:store-trace-result-hash #:store-trace-reads
   #:trace-repository #:trace-repository-p #:make-trace-repository
   #:trace-repository-create #:trace-repository-layout
   #:store-trace-outcome-ok-p #:store-trace-outcome-failed-p
   #:store-trace-outcome-name #:store-trace-read-cell #:store-trace-read-hash
   #:store-trace-read-fields #:trace-repository-to-line
   #:store-trace-parse-quoted #:store-trace-prefix
   #:trace-repository-of-line #:trace-repository-load
   #:store-trace-equal-p #:trace-repository-put #:trace-repository-keys
   #:cell-repository #:cell-repository-p #:make-cell-repository
   #:cell-repository-create #:cell-repository-layout #:cell-repository-blobs
   #:cell-repository-read-raw #:cell-repository-read-file
   #:cell-repository-read-sealed
   #:store-inventory-entry #:store-inventory-entry-p
   #:make-store-inventory-entry #:store-inventory-entry-id
   #:store-inventory-entry-modified #:store-inventory-entry-size
   #:store-inventory-area #:store-inventory-entries #:store-inventory-remove
   #:store-index-reverse #:store-index-dirty-keys
   #:store-gc-root #:store-gc-root-p #:make-store-gc-root
   #:store-gc-root-hash #:store-gc-root-nodes
   #:gc-roots-path #:gc-roots-root-value #:gc-root-field
   #:gc-roots-value-root #:gc-roots-read-all #:gc-roots-record
   #:store-gc-mark-graph #:store-gc-sweep #:store-gc-run
   #:runtime-store-with-repositories #:runtime-store-put-node-result
   #:runtime-store-load-node-traces
   ;; Effects, configuration, observations, and verified cache.
   #:runtime-effect #:runtime-effect-p #:make-runtime-effect
   #:runtime-effect-name #:runtime-effect-function #:runtime-effect-hash
   #:runtime-effect-authority #:runtime-effects-error
   #:runtime-effects-register #:runtime-effects-with
   #:runtime-effects-authorized-p #:runtime-effect-perform
   #:runtime-effects-install-session #:runtime-effects-handler
   #:runtime-effects-with-handlers #:runtime-effects-handler-identities
   #:runtime-effects-current-capabilities
   #:runtime-effects-require-capability #:runtime-effects-record-event
   #:runtime-effects-record-read
   #:runtime-configuration-error #:runtime-configuration-value-durable-p
   #:runtime-configuration-normalize #:runtime-configuration-hash
   #:runtime-configuration-current #:runtime-configuration-snapshot
   #:runtime-configuration-current-hash #:runtime-configuration-lookup
   #:runtime-configuration-read #:runtime-configuration-with
   #:runtime-configuration-push #:runtime-configuration-pop
   #:runtime-config-hash #:runtime-config-lookup #:runtime-config-read
   #:runtime-config-with #:configuration-hash #:configuration-lookup
   #:configuration-read
   #:runtime-observation-error #:runtime-observation-session
   #:runtime-observation-service #:runtime-observation-call
   #:runtime-observe-file #:runtime-observe-tree #:runtime-observe-stat
   #:runtime-observe-env #:runtime-observe-argv #:runtime-observation-probe
   #:runtime-observe-domain #:runtime-observe-node-trace
   #:runtime-observe-cell #:runtime-observe #:runtime-observe-id
   #:runtime-observation-record #:runtime-observation-record-config
   #:runtime-observation-record-handler #:runtime-observation-replay
   #:runtime-observation-authorized-p #:runtime-authorized-p
   #:observation-observe #:observation-observe-id #:observation-record
   #:observation-replay #:observation-authorized-p
   #:runtime-observation-repository
   #:runtime-cache-policy #:runtime-cache-policy-p
   #:make-runtime-cache-policy
   #:runtime-cache-policy-no-cache #:runtime-cache-policy-why
   #:runtime-cache-policy-check #:runtime-cache-policy-volatile-count
   #:runtime-cache-result #:runtime-cache-result-p
   #:make-runtime-cache-result #:runtime-cache-result-kind
   #:runtime-cache-result-value #:runtime-cache-result-trace
   #:runtime-cache-policy-create #:runtime-cache-configure
   #:runtime-cache-enable-no-cache #:runtime-cache-enable-why
   #:runtime-cache-set-why #:runtime-cache-why-enabled-p
   #:runtime-cache-enable-check #:runtime-cache-check-enabled-p
   #:runtime-cache-note-volatile #:runtime-cache-reset-volatile
   #:runtime-cache-volatile-count #:runtime-cache-short-key
   #:runtime-cache-error #:runtime-cache-event #:runtime-cache-diagnose
   #:runtime-cache-result-hit-p #:runtime-cache-hit-ok-p
   #:runtime-cache-hit-failed-p #:runtime-cache-miss-p #:runtime-cache-lookup
   #:cache-policy-create #:cache-policy-configure #:cache-policy-lookup
   #:cache-policy-note-volatile
   ;; Persistent nodes and thunk identity adapters.
   #:runtime-node-error #:runtime-node-service #:runtime-node-repository
   #:runtime-node-authority-value-p #:runtime-node-persistent-value-p
   #:runtime-node-forced-free-variables #:runtime-node-key-of
   #:runtime-node-key #:runtime-node-data-closed-p #:runtime-node-serve-hit
   #:runtime-node-persist #:runtime-node-force-in-scope
   #:runtime-node-force-with-session #:runtime-node-force-callback
   #:runtime-node-force #:runtime-node-install-session
   #:node-key-of #:node-force-persistent #:node-serve-hit
   #:runtime-thunk-error #:runtime-thunk-capabilities-hash
   #:runtime-thunk-configuration-hash #:runtime-thunk-handlers-hash
   #:runtime-thunk-location-hash #:runtime-thunk-content-hash
   #:runtime-thunk-make-with-hash #:runtime-thunk-make
   #:runtime-thunk-make-node #:runtime-thunk-make-typed
   #:runtime-thunk-persistent-p #:runtime-thunk-captured-capabilities
   #:runtime-thunk-arguments #:runtime-thunk-hash #:runtime-thunk-poison
   #:make-runtime-thunk #:make-runtime-node-thunk
   #:evaluator-thunks-make #:evaluator-thunks-make-node
   #:make-thunk-with-hash #:thunk-persistent-p
   ;; Artifact trees, blobs, and reconciliation.
   #:runtime-artifact-entry #:runtime-artifact-entry-p
   #:runtime-artifact-entry-kind #:runtime-artifact-entry-path
   #:runtime-artifact-entry-mode #:runtime-artifact-entry-blob
   #:runtime-artifact-entry-target
   #:runtime-artifact-file #:runtime-artifact-directory
   #:runtime-artifact-symlink #:runtime-artifact-error
   #:runtime-artifact-valid-path-p #:runtime-artifact-tree-from-value
   #:runtime-artifact-tree-to-value #:runtime-artifact-tree-validate
   #:runtime-artifact-blob-put #:runtime-artifact-blob-get
   #:runtime-artifact-materialize #:runtime-artifact-reconcile
   #:runtime-artifact-snapshot
   ;; Descriptor transport and process-isolated scheduling.
   #:+distribution-wire-version+ #:distribution-error
   #:distribution-error-code #:distribution-error-detail
   #:distribution-fail #:distribution-wire-encode
   #:distribution-wire-decode
   #:distribution-policy #:distribution-policy-p
   #:make-distribution-policy #:distribution-policy-kind
   #:distribution-policy-width #:distribution-policy-member
   #:distribution-job #:distribution-job-p
   #:make-distribution-job #:distribution-job-key
   #:distribution-job-width #:distribution-job-data-closed-p
   #:distribution-job-descriptor #:distribution-job-wire-descriptor
   #:distribution-job-wire
   #:distribution-result #:distribution-result-p
   #:make-distribution-result #:distribution-result-status
   #:distribution-result-payload #:distribution-result-error
   #:distribution-result-artifacts
   #:distribution-scheduler #:distribution-scheduler-p
   #:make-distribution-scheduler #:distribution-scheduler-policy
   #:distribution-scheduler-runner #:distribution-scheduler-remote-send
   #:distribution-scheduler-transport
   #:distribution-scheduler-live-children #:distribution-scheduler-closed
   #:distribution-cancel #:distribution-dispatch #:distribution-run
   #:distribution-artifact #:distribution-artifact-p
   #:make-distribution-artifact #:distribution-artifact-kind
   #:distribution-artifact-hash #:distribution-artifact-size
   #:distribution-transport-push #:distribution-transport-pull
   #:distribution-transport-move #:distribution-transport-encode-artifacts
   #:distribution-remote-descriptor #:distribution-remote-dispatch
   #:distribution-members-path #:distribution-load-members
   #:distribution-member-root #:distribution-gc-root
   #:distribution-gc-root-from-descriptor #:distribution-gc-mark
   #:distribution-gc-run
   ;; Lifecycle records and orchestration.
   #:runtime-lifecycle #:runtime-lifecycle-p
   #:make-runtime-lifecycle #:runtime-lifecycle-session
   #:runtime-lifecycle-invocation #:runtime-lifecycle-watch-state
   #:runtime-lifecycle-executor
   #:runtime-lifecycle-require-session-service
   #:runtime-lifecycle-prepare #:runtime-lifecycle-observe
   #:runtime-lifecycle-diff #:runtime-lifecycle-apply
   #:runtime-lifecycle-verify #:runtime-lifecycle-epoch
   #:runtime-lifecycle-run-pass #:runtime-lifecycle-reconcile
   #:runtime-lifecycle-fenced #:runtime-lifecycle-watch
   #:runtime-lifecycle-install-executor
   #:runtime-lifecycle-install-process-provider
   #:runtime-lifecycle-fail-closed
   ;; Domain entries, plans, and passes.
   #:runtime-domain-entry #:runtime-domain-entry-p
   #:make-runtime-domain-entry #:runtime-domain-entry-namespace
   #:runtime-domain-entry-observe #:runtime-domain-entry-diff
   #:runtime-domain-entry-apply #:runtime-domain-entry-cap
   #:runtime-domain-entry-observe-cell
   #:runtime-domain-target #:runtime-domain-target-p
   #:make-runtime-domain-target #:runtime-domain-target-name
   #:runtime-domain-target-entry #:runtime-domain-target-desired
   #:runtime-domain-observed #:runtime-domain-observed-p
   #:make-runtime-domain-observed #:runtime-domain-observed-target
   #:runtime-domain-observed-state
   #:runtime-domain-planned #:runtime-domain-planned-p
   #:make-runtime-domain-planned #:runtime-domain-planned-observed
   #:runtime-domain-planned-plan #:runtime-domain-planned-summary
   #:runtime-domain-pass #:runtime-domain-pass-p
   #:make-runtime-domain-pass #:runtime-domain-pass-invocation
   #:runtime-domain-pass-forced-desired #:runtime-domain-pass-targets
   #:runtime-domain-force #:runtime-domain-string #:runtime-domain-map
   #:runtime-domain-find #:runtime-domain-plan-items-empty-p
   #:runtime-domain-summary-pair #:runtime-domain-plan-summary
   #:runtime-domain-plan-cache-key #:runtime-domain-service-value
   #:runtime-domain-cache-plan #:runtime-domain-call
   #:runtime-domain-with-domain #:runtime-domain-call-uncached
   #:runtime-domain-observe #:runtime-domain-diff #:runtime-domain-apply
   #:runtime-domain-verify #:runtime-domain-run-target
   #:runtime-domain-prefix-p #:runtime-domain-stratification-check
   #:runtime-domain-prepare-pass #:runtime-domain-invocation-keep
   #:runtime-domain-record-epoch #:runtime-domain-run-pass
   #:runtime-domain-any-write-domain-registered-p
   ;; Journal records and durable recovery.
   #:runtime-journal-exec #:runtime-journal-exec-p
   #:make-runtime-journal-exec #:runtime-journal-exec-argv
   #:runtime-journal-domain-intent #:runtime-journal-domain-intent-p
   #:make-runtime-journal-domain-intent
   #:runtime-journal-domain-intent-hash
   #:runtime-journal-domain-intent-fields
   #:runtime-journal-domain-done #:runtime-journal-domain-done-p
   #:make-runtime-journal-domain-done #:runtime-journal-domain-done-hash
   #:runtime-journal-proc-start-intent #:runtime-journal-proc-start-intent-p
   #:make-runtime-journal-proc-start-intent
   #:runtime-journal-proc-start-intent-name
   #:runtime-journal-proc-start-intent-spec-hash
   #:runtime-journal-proc-start-done #:runtime-journal-proc-start-done-p
   #:make-runtime-journal-proc-start-done
   #:runtime-journal-proc-start-done-name
   #:runtime-journal-proc-start-done-spec-hash
   #:runtime-journal-proc-start-done-pid
   #:runtime-journal-proc-stop-intent #:runtime-journal-proc-stop-intent-p
   #:make-runtime-journal-proc-stop-intent
   #:runtime-journal-proc-stop-intent-name
   #:runtime-journal-proc-stop-done #:runtime-journal-proc-stop-done-p
   #:make-runtime-journal-proc-stop-done
   #:runtime-journal-proc-stop-done-name
   #:runtime-journal-fenced-intent #:runtime-journal-fenced-intent-p
   #:make-runtime-journal-fenced-intent
   #:runtime-journal-fenced-intent-key
   #:runtime-journal-fenced-intent-epoch
   #:runtime-journal-fenced-intent-kind
   #:runtime-journal-fenced-intent-spec-hash
   #:runtime-journal-fenced-done #:runtime-journal-fenced-done-p
   #:make-runtime-journal-fenced-done
   #:runtime-journal-fenced-done-key
   #:runtime-journal-fenced-done-result-hash
   #:runtime-journal-island-fetch #:runtime-journal-island-fetch-p
   #:make-runtime-journal-island-fetch
   #:runtime-journal-island-fetch-uri #:runtime-journal-island-fetch-pin
   #:runtime-journal-epoch #:runtime-journal-epoch-p
   #:make-runtime-journal-epoch #:runtime-journal-epoch-hash
   #:runtime-journal-digest-p #:runtime-journal-token-p
   #:runtime-journal-pid-p #:runtime-journal-entry-line
   #:runtime-journal-split-words #:runtime-journal-parse-line
   #:runtime-journal-entry-valid-p #:runtime-journal-layout
   #:runtime-journal-path #:runtime-journal-append #:runtime-journal-fold
   #:runtime-journal-pending-fenced-actions
   #:runtime-journal-has-fenced-done-p
   ;; Fenced actions and recovery.
   #:+runtime-fenced-retry+ #:+runtime-fenced-abort+
   #:runtime-fenced-aborted #:runtime-fenced-aborted-p
   #:make-runtime-fenced-aborted #:runtime-fenced-aborted-kind
   #:runtime-fenced-aborted-spec-hash #:runtime-fenced-aborted-reason
   #:runtime-fenced-force #:runtime-fenced-new-epoch
   #:runtime-fenced-ensure-epoch #:runtime-fenced-action-key
   #:runtime-fenced-spec-hash #:runtime-fenced-plain-data-p
   #:runtime-fenced-map-find #:runtime-fenced-run-command
   #:runtime-fenced-register #:runtime-fenced-result-hash
   #:runtime-fenced-current #:runtime-fenced-aborted-value
   #:runtime-fenced-recover-entry #:runtime-fenced-recover-unknown
   #:runtime-fenced-drain
   ;; Watch state and dependency stabilization.
   #:runtime-watch-state #:runtime-watch-state-p
   #:make-runtime-watch-state #:runtime-watch-state-session
   #:runtime-watch-state-interval #:runtime-watch-state-stabilize
   #:runtime-watch-state-once
   #:runtime-watch-snapshot #:runtime-watch-snapshot-p
   #:make-runtime-watch-snapshot #:runtime-watch-snapshot-cells
   #:runtime-watch-register-node-key #:runtime-watch-runtime-edges
   #:runtime-watch-dependency-cells #:runtime-watch-reset-dirty
   #:runtime-watch-observation-hash
   #:runtime-watch-evaluated-dependencies-changed-p
   #:runtime-watch-build-reverse-index #:runtime-watch-stabilize
   #:runtime-watch-snapshot-equal-p #:runtime-watch-call-sleep
   #:runtime-watch-run #:runtime-watch-create
   ;; Executor and confined process/sandbox services.
   #:runtime-executor-request #:runtime-executor-request-p
   #:make-runtime-executor-request #:runtime-executor-request-tool
   #:runtime-executor-request-tool-path
   #:runtime-executor-request-arguments #:runtime-executor-request-inputs
   #:runtime-executor-request-environment #:runtime-executor-request-platform
   #:runtime-executor-request-policy #:runtime-executor-request-outputs
   #:runtime-executor-result #:runtime-executor-result-p
   #:make-runtime-executor-result #:runtime-executor-result-exit-status
   #:runtime-executor-result-stdout #:runtime-executor-result-stderr
   #:runtime-executor-result-outputs #:runtime-executor-result-evidence
   #:runtime-executor-result-resources
   #:runtime-executor-cacheable #:runtime-executor-cacheable-p
   #:make-runtime-executor-cacheable
   #:runtime-executor-scripting-only #:runtime-executor-scripting-only-p
   #:make-runtime-executor-scripting-only
   #:runtime-executor-scripting-only-reason
   #:runtime-executor #:runtime-executor-p
   #:make-runtime-executor #:runtime-executor-classify
   #:runtime-executor-execute
   #:runtime-executor-classification-cacheable-p
   #:runtime-executor-classification-scripting-only-p
   #:runtime-executor-classification-reason
   #:runtime-executor-request-data-p #:runtime-executor-sorted-pairs
   #:runtime-executor-validate-result #:runtime-executor-classify-request
   #:runtime-executor-run #:runtime-executor-service
   #:runtime-executor-run-in-session
   #:runtime-process-record #:runtime-process-record-p
   #:make-runtime-process-record #:runtime-process-record-name
   #:runtime-process-record-spec-hash #:runtime-process-record-pid
   #:runtime-process-record-argv #:runtime-process-record-cwd
   #:runtime-process-record-environment #:runtime-process-record-status
   #:runtime-process-capability-p #:runtime-process-require-capability
   #:runtime-process-split-path #:runtime-process-resolve-command
   #:runtime-process-resolve-cmd #:runtime-process-read-file
   #:runtime-process-exec #:runtime-process-spec-hash
   #:runtime-process-argv #:runtime-process-records
   #:runtime-process-save-record #:runtime-process-record
   #:runtime-process-start #:runtime-process-alive-p
   #:runtime-process-stop #:runtime-process-reap
   #:runtime-process-start-service #:runtime-process-stop-service
   #:runtime-sandbox #:runtime-sandbox-p
   #:make-runtime-sandbox #:runtime-sandbox-root #:runtime-sandbox-owned
   #:runtime-sandbox-create #:runtime-sandbox-relative-p
   #:runtime-sandbox-path #:runtime-sandbox-current
   #:runtime-sandbox-resolve #:runtime-sandbox-delete-tree
   #:runtime-sandbox-with #:runtime-sandbox-with-node))

(defpackage #:pp.app
  (:use #:cl #:pp.kernel #:pp.frontend #:pp.runtime)
  (:shadow #:position)
  (:export #:main #:run #:version-string))
