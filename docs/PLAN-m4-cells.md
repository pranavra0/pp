# M4 design — the world as cells (Q13, probes, sealed cells, network)

Architect pass + adversarial review; the implementation contract. Line refs
against commit `6e3f320`. Four pieces, ONE model: a cell whose
write-discipline core enforces mechanically. The trusted boundary
throughout is the node/non-node boundary M3 built — reused, never
reinvented.

## Q13 — the in-language reconciler-domain protocol

- **Registration:** `(register-domain {:name :namespace :observe :diff
  :apply :write-cap [:observe-cell]})` — ordinary primitive, script-tier
  only (trace_stack guard, the fenced pattern). `:write-cap` is consumed
  into a core-side registry, never re-exposed. Returns nil.
- **A probe IS a domain with ⊥ write authority:** `(register-probe name
  observe-fn read-cap)` ≡ a domain with no :diff/:apply — core never
  converges it, only exposes its observe result as `probe:<name>` cells.
  One mechanism, two hats.
- **No CapDomain kind.** A domain's write authority IS the underlying
  resource capability (fs:<root>:rw, process, net:<host>) — narrowed by the
  program via cap-restrict and handed to register-domain. A domain-shaped
  wrapper cap would be a second name for the same ceiling.
- **Types:** `observe : () -> value` (fresh every pass — caching it would
  resurrect Terraform's trusted-state-file bug, Q4); `diff : (observed,
  desired) -> plan`, PURE — enforced by threading an EMPTY capability set
  for its extent (any gated perform inside diff = Capability_error; no new
  purity checker). plan = ordered list of tagged items, hashable — core
  wraps the diff call in the ordinary node/store machinery
  (H(diff-code-hash ‖ observed-hash ‖ desired-hash)) so "plans cache" (Q4)
  falls out of the existing store. `apply : plan -> nil`, NOT a node, runs
  under with_ref current_capabilities [write_cap] — the M3 threading
  mechanism verbatim; nodes built inside apply that close over the cap
  hard-error via the existing free-var ban.
- **Stratification (LAW 30 full form):** :namespace = cell-id prefixes the
  domain owns (fs: ["file:" "tree:" "stat:"] under root; proc: ["proc:"]).
  After root evaluation, core scans observed_all per registered
  write-domain and rejects on overlap — today's check generalized from
  hardwired-to-one-domain to declared-per-domain. **Load-bearing core
  change:** observed_all collection is SUSPENDED (exception-safe with_ref,
  never hand-rolled) for the extent of observe/diff/apply — otherwise a
  domain's own bookkeeping trips its own stratification. Do NOT suspend
  trace_stack (node caching inside domain fns keeps working).
- **New generic cell kind** `Cell.Domain {name; sub}` → `domain:<n>:<sub>`
  for third-party domains; fs/proc keep their existing cell kinds (no
  store-format bump). Authorization: cap_subseteq of the registered
  write_cap against the caller's set — zero new authority code.
  Optional `:observe-cell (fn (sub) -> hash|nil)` gives Store.observe_cell
  an O(1) targeted re-observation (the proc_observer pattern generalized).
- **Journaling — byte-compatibility is BINDING:** core wraps every apply in
  a generic per-pass intent/done bracket whose counts are tallied from the
  plan's own :kind tags; per-item entries belong to the trusted primitives
  (proc-spawn/proc-stop own "intent proc start/stop" lines exactly as
  today). Journal line formats are FROZEN (journal.ml:5) and tests/018+033
  grep literal substrings — READ Journal.to_line and the tests' greps
  FIRST and make the generic bracket reproduce today's bytes for fs/proc
  passes. If a truly generic format cannot reproduce the frozen bytes,
  STOP: that is a wall, not a license to special-case.
- **Verify-after-write:** core re-runs observe after apply and re-diffs
  against desired (the same cached-diff machinery); non-empty = hard error
  ("reconcile: verify-after-write failed" text preserved). Whole-domain,
  deliberately stronger than today's per-file inline check.
- **Fenced (Q3) unchanged:** drained once per pass after all domains'
  convergent work; apply may register fenced actions (script-tier).
- **Driver wiring / back-compat (the exit criterion):** --reconcile ROOT
  auto-loads bundled stdlib/domain-fs.pp and registers it with write-cap
  cap-restrict'd to ROOT, wrapping the program's value as {"fs" -> v};
  --supervise likewise with stdlib/domain-proc.pp; programs may call
  register-domain themselves and return {name -> desired} directly (N
  domains, one evaluation). **The OCaml Reconciler/Supervisor modules are
  DELETED** — the flags run the pp libraries; all POLICY (tree walk,
  create/update/delete, start/stop/restart) is pp source; what stays OCaml
  is the generic orchestration + the trusted primitives below. Salvage by
  MOVING OCaml code into the primitives (atomic write, fork/exec, reaping),
  not rewriting. tests/018 and tests/033 must pass UNCHANGED.
  **Loader reachability:** stdlib domain files must load from any cwd —
  resolve relative to the executable (bin/../stdlib) and add that dir to
  Runtime.source_roots.
- **E2 revision (DESIGN.md):** trusted core = journal + fence +
  stratification + cap threading + verify-after-write; observe/diff/apply
  are untrusted library code bounded by one threaded cap and the node
  boundary; worst case = a domain mis-converges its OWN namespace under
  authority it was granted. "The reconciler's code is small" retires;
  "core enforces discipline mechanically around the domain" replaces it.

## Probes

- Driver-evaluated, at most once per pass, LAZILY on first read
  (demand-pruning extended to probes; an unread probe never fires).
  observe-fn runs under with_ref [read_cap], OUTSIDE any node body.
- `(probe name)` reads the pinned value inside nodes — a distinct
  primitive from performing; records `(probe:<name>, hash_value(v))` via
  ordinary record_read; capability-free at the read site (authority was
  consumed by the probe's own evaluation — the file-cell pattern).
- Values live in Runtime.probe_values (in-memory), cleared at exactly the
  three points the watch loop clears run_pins. NEVER persisted: LAW 38's
  volatility exclusion (serving yesterday's health check would be wrong) —
  deliberately distinct in rationale from sealed cells' confidentiality
  exclusion.
- This one mechanism flips LAW 37 (declared nondeterminism: probes are the
  only sanctioned nondeterministic dependency) and LAW 38 (containment at
  one cell edge) to holds.

## Sealed cells

- `--grant secret:<path>` mints CapSecret {path}. The READ surface is
  unchanged (slurp/read-file); the grant decides: covered by secret: and
  not by fs: → returns new value kind `VSealed of string`, records
  `sealed:<canonical-path>` cell (hash of bytes), NEVER calls store_blob;
  bytes pin in in-memory Runtime.sealed_pins (Q11 consistency without
  touching blobs/). Program text stays deployment-agnostic.
- VSealed joins the node-boundary ban exactly like VCapability (free-var
  ban + result ban, the M3 walk extended); Codec.encode_value returns None
  for it (every store path refuses it for free); **string_of_value/print
  MUST redact** (`#<sealed>`) — a print leaking bytes defeats the feature;
  hash_value hashes the bytes (rotation invalidation needs it) — that hash
  appears only in trace lines, which is the design (hash-in-trace, LAW 39).
- `(unseal v)` → VString, the explicit greppable boundary. Derived data is
  ordinary data — NO dataflow tainting, by design (the Vault/SOPS line);
  the hit gate already prevents laundering the SOURCE (cell_authorized_for
  gains the sealed:/CapSecret arm; LAW 23c redaction is already generic).
- Exit test: store-wide scan finds no secret bytes; rotation invalidates
  exactly the observers.

## Network

- Islands already cover content-addressed fetch (closed, not deferred).
- CapNetwork {protocol} → {host; port option} (a Types shape change:
  update hash_capability/string_of_capability/grant parser AND add a
  net-grant fuzzer arm IN THE SAME CHANGE — LAW 36 risk).
- New effects `(perform http-get url)` / `(perform http-post url body)`:
  implemented by forking curl via Process.exec (E6: zero new OCaml
  networking/TLS surface) but AUTHORIZED against CapNetwork host[:port] —
  not CapProcess (granularity: "may read this host" ≠ "may exec
  anything"). Banned inside node bodies (trace_stack guard, the fenced
  pattern); legal in probe observe-fns, domain observe/apply, script tier.

## Primitives gap list (the real deliverable for the library domains)

domain-fs.pp: `(perform tree-observe root)` → {relpath -> hash} (new;
today's tree_hash is one aggregate, and observed_files is OCaml-only);
`(perform materialize-file path content [:executable])` — temp-in-target +
rename(2), mkdir -p, chmod (new; scripting write-file is NOT atomic and
must not be used for domain writes); `(perform remove-file path)` + empty
-dir pruning (new); blob-get exists.

domain-proc.pp: `(perform proc-spawn spec)` → pid immediately (fork/exec/
stdio-to-files; owns its intent/done journal lines); `(perform proc-alive?
pid)`; `(perform proc-stop pid)` (TERM→poll→KILL; owns its journal lines);
`(perform proc-reap)`; `(perform domain-state-get/put key [value])` —
domain-private persistent state scoped implicitly to the currently-running
domain (replaces procs/ state files' role; no OS process enumeration — the
supervisor tracks its OWN pids, preserve that honesty).

## SPEC flips

LAW 30 → holds (full form, per-domain stratification); LAW 37 → holds;
LAW 38 → holds; new LAW 39 (sealed cells); LAW 22/26 amendments for
CapNetwork + http effects. DESIGN.md gains Q13 (this design) and the E2
revision; STATUS/ROADMAP/MASTERPLAN/TESTING/CHANGELOG in the same commits.

## Rejected (kill-list)

Probes as fenced actions (read-only vs at-most-once are different
disciplines); perform-in-node for probes/network (the LAW 37/38 hazard
itself); dataflow tainting (a security-typed IR, not M4); CapSecret as an
fs_mode (the read must return a distinct VALUE KIND for the boundary ban
to pattern-match); native HTTP client (E6); http under CapProcess
(granularity); CapDomain kind (second name for the same ceiling); uniform
per-item journaling (fs is legitimately coarser; granularity belongs to
the trusted primitive); a parallel new flag keeping OCaml domains alive
(fails the exit criterion's own bar).

## Walls / residuals

observed_all suspension is THE load-bearing new dynamic scope — with_ref
only, exception-safe, wrong = stratification silently defeated. diff
purity doesn't catch ungated side channels (print/log) — bounded,
documented. Sealed confidentiality ends at unseal — by design. Per-domain
stratification stays whole-program-coarse — sound, documented, unchanged
in character. Implementation order: stage 1 = probes + sealed + network
(additive); stage 2 = Q13 + primitives + library domains + OCaml
reconciler/supervisor deletion + flag rewiring.
