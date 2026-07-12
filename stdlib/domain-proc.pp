;; stdlib/domain-proc.pp — Q13 process-domain policy (PLAN-m4-cells.md §Q13)
;;
;; This is the POLICY that used to live in src/supervisor.ml: start/stop/
;; restart decisions on spec-hash (here: spec VALUE) change. The TRUSTED
;; MECHANICS (fork/exec/reap, TERM->poll->KILL, per-domain state
;; persistence) are OCaml primitives (src/domain_prims.ml): proc-spawn,
;; proc-alive?, proc-stop, proc-reap, domain-state-get/put. main.ml's
;; `--supervise` auto-loads this file and calls `register-proc-domain`.
;;
;; The old procs/ state-file directory is replaced by domain-state-get/put
;; — generic, per-domain-scoped persistent storage. This domain maintains
;; its OWN index of tracked service names under the "known-services" key
;; (a plain pp list) since there is no OS process enumeration — "the
;; supervisor tracks its own pids" (PLAN-m4-cells.md), preserved exactly.
;;
;;   observe = reap zombies once per pass (the natural per-pass hook —
;;             observe runs exactly once per domain per pass, same as
;;             everything else here), then {name -> spec} for every ALIVE
;;             tracked service, {name -> :stopped} for a tracked-but-dead
;;             one, and no entry at all for a name never seen.
;;   desired = {service-name -> spec-map}  (spec: "cmd"/"args"/"env"/"cwd",
;;             exactly the pre-Q13 shape)
;;   diff    = start (never seen, or seen-but-dead) / restart (alive, spec
;;             changed — compared STRUCTURALLY, `=`, no hash needed since
;;             diff has the actual values) / stop (tracked, alive, no
;;             longer desired). PURE — apply re-derives whatever mechanical
;;             state (the current pid) it needs itself, via domain-state-get
;;             (apply is not required to be pure, only diff is).
;;   apply   = proc-spawn / proc-stop + domain-state-put bookkeeping.

;; ---- domain-state bookkeeping (this domain's own index) ----
;;
;; LOAD-BEARING SHAPE, found the hard way: `perform domain-state-get KEY`
;; sits behind an ordinary pp `let` (proc-known-names' own binding) — pp's
;; content-addressed thunk cache (Q1/LAW 20's make_thunk_ca) keys a `let`
;; binding on (expr, closure-env, ambient caps/config/handlers), and
;; `proc-known-names` takes NO arguments, so its closure env NEVER varies
;; between calls. Call it a SECOND time in the same dynamic extent (same
;; ambient, same env — exactly what apply's `with_domain`-fixed cap does
;; for its whole extent) and pp replays the FIRST call's memoized result
;; instead of re-reading "known-services" — invisible staleness, not an
;; error. (Domains.ml's per-call config-stack nonce busts this ACROSS the
;; two top-level observe/apply calls a pass makes; it does nothing for
;; repeat calls WITHIN one of those two, which is what bit here.) The
;; general, robust fix is mechanical: never call an argument-free
;; domain-state accessor more than once per dynamic extent — read the
;; known-set ONCE (proc-apply, below) and thread it through explicitly as
;; an ordinary function argument, exactly like any other value a fold
;; carries — parameterized calls (proc-state-key NAME) are immune by
;; construction, since a differing argument value changes the callee's
;; extended env and therefore its thunk key.
(def (proc-state-key name) (string-append "svc:" name))

(def (proc-known-names)
  (let [v (perform domain-state-get "known-services")]
    (if (nil? v) nil v)))

;; Pure with respect to `known` (returns the updated list; the ONE caller,
;; proc-apply, does the ONE write) — still performs the per-service state
;; write, which is fine (apply is not required to be pure, only diff is)
;; and immune to the memoization trap above (its key is parameterized by
;; `name`).
(def (proc-remember! name pid spec known)
  (do
    (perform domain-state-put (proc-state-key name) {:pid pid :spec spec})
    (if (member? name known) known (cons name known))))

(def (proc-forget! name known)
  (do
    (perform domain-state-put (proc-state-key name) nil)
    (filter (fn (n) (not (= n name))) known)))

;; ---- observe: reap once per pass, then {name -> spec | :stopped} ----

(def (proc-observe-one name)
  (let [st (perform domain-state-get (proc-state-key name))]
    (if (nil? st)
        nil
        (if (perform proc-alive? (hash-map-get st :pid))
            (hash-map-get st :spec)
            :stopped))))

(def (proc-observe)
  (do
    (perform proc-reap)
    (foldl (fn (acc name)
             (let [v (proc-observe-one name)]
               (if (nil? v) acc (map-insert acc name v))))
           {}
           (proc-known-names))))

;; ---- diff ----

(def (proc-plan-item kind name spec)
  {:kind kind :name name :spec spec})

;; `desired`'s spec VALUES are lazy (hash-map/map literals force keys only,
;; PLAN-m4-cells.md / primitives.ml convention) — `observed`'s spec values
;; are NOT (they round-tripped through domain-state's Codec encode/decode).
;; Two more traps found the hard way, both closed the same way (force-deep
;; + compare by `hash-value`, never raw `=`, whenever one side may have
;; come back through domain-state):
;;   1. an unforced thunk vs an already-concrete value are different
;;      SHAPES to `=`, not merely different values — force-deep first;
;;   2. Codec's on-disk map encoding SORTS entries for canonical text
;;      (codec.ml), so a spec map that round-tripped through domain-state
;;      compares "different" from the in-memory original via `=` — an
;;      ORDER difference, not a content difference. `hash-value` (Hasher.
;;      hash_value) canonicalizes map/set order the SAME way Codec does,
;;      so it is the one comparison that cannot be fooled by either trap.
(def (proc-spec-eq? a b) (= (hash-value a) (hash-value b)))

(def (proc-diff observed desired)
  (let [dnames (map-keys desired)
        onames (map-keys observed)
        dspec (fn (n) (force-deep (hash-map-get desired n)))
        starts (filter (fn (n)
                          (let [ov (hash-map-get observed n)]
                            (or (nil? ov) (= ov :stopped))))
                        dnames)
        restarts (filter (fn (n)
                            (let [ov (hash-map-get observed n)]
                              (and (not (nil? ov))
                                   (not (= ov :stopped))
                                   (not (proc-spec-eq? ov (dspec n))))))
                          dnames)
        stops (filter (fn (n)
                         (and (nil? (hash-map-get desired n))
                              (not (= (hash-map-get observed n) :stopped))))
                       onames)
        items (append
                (map (fn (n) (proc-plan-item "start" n (dspec n))) starts)
                (append
                  (map (fn (n) (proc-plan-item "restart" n (dspec n))) restarts)
                  (map (fn (n) (proc-plan-item "stop" n nil)) stops)))]
    {:items items
     ;; A VECTOR of pairs, not a map — see domain-fs.pp's fs-diff-for for
     ;; why (Codec's canonical on-disk form sorts map keys but preserves
     ;; vector order; plan caching round-trips a MISS through the store).
     :summary [[:started (number->string (length starts))]
               [:restarted (number->string (length restarts))]
               [:stopped (number->string (length stops))]]}))

;; ---- apply ----

(def (proc-stop-current! name)
  (let [st (perform domain-state-get (proc-state-key name))]
    (if (nil? st) nil (perform proc-stop name (hash-map-get st :pid)))))

;; (proc-apply-item known item) -> updated known-list, folded across every
;; plan item by proc-apply (below) — the known-set is read ONCE (the
;; fold's seed) and written ONCE (proc-apply's own single domain-state-put
;; after the fold completes), never re-queried mid-pass.
(def (proc-apply-item known item)
  (let [kind (hash-map-get item :kind)
        name (hash-map-get item :name)]
    (if (= kind "stop")
        (do (proc-stop-current! name) (proc-forget! name known))
        (do
          (if (= kind "restart") (proc-stop-current! name) nil)
          (let [spec (hash-map-get item :spec)
                pid (perform proc-spawn (map-insert spec :name name))]
            (proc-remember! name pid spec known))))))

(def (proc-apply plan)
  (perform domain-state-put "known-services"
    (foldl proc-apply-item (proc-known-names) (hash-map-get plan :items))))

;; ---- registration ----

(def (register-proc-domain write-cap)
  (register-domain
    {:name "proc"
     :namespace ["proc:"]
     :observe proc-observe
     :diff proc-diff
     :apply proc-apply
     :write-cap write-cap}))
