# M6 design — devops-complete demonstration + diagonal oracle

Architect pass + adversarial review; the implementation contract. Refs
against commit `3066b35`. The capstone: prove the substrate is
devops-complete by expressing the whole end-state as LIBRARIES — no new
core for the demo (the plan's thesis, now auditable). Two stages: A =
demo + per-clause tests + the demo's diagonal oracle + doc corrections
(all-library, zero core); B = the `--pin-file`/`pin-probe` observability
seam + its adversarial oracle test (the one small, justified core
addition, kept separate).

## The demo (all-library, three new files under demo/)

- **demo/src/greeter.c** — a tiny socket-free C service: reads a config
  file each loop, writes a heartbeat+greeting to a status file. No
  network dependency (keeps the exit tests free of curl/python3).
- **demo/deploy.pp** — the pitch: ONE readable pure function from input
  cells (C source, per-host greeting fixtures, per-host SEALED secrets)
  to a `{host -> {domain -> desired}}` value. Builds the binary once
  (`run-dep` cc, shared blob ref both hosts materialize), renders each
  host's config inside a `(node ...)` that `(unseal (slurp key))` — the
  node RESULT is a plain string (unseal already converted), so the sealed
  node-result ban doesn't fire; the sealed CELL's hash is what enters the
  trace. Registers NO domains itself — run only via `--publish-object`,
  so it holds no write authority (a pure plan step).
- **demo/agent.pp** — identical text on every host: loads the domain
  libraries, `register-fs-domain "." (cap-restrict (current-capabilities)
  "." :wo)` + `register-proc-domain (current-capabilities)`, registers a
  report-only health probe reading the status file. Run as `pp --watch
  --member-name <HOST> --desired-object <HASH> <SHARED> --grant
  fs:<root>:rw --grant process agent.pp`. `--desired-object` overrides
  the agent's own value with the dispatcher's published slice
  (tests/051's proven dispatcher/agent split).

Per-host secret isolation is structural: leaf node thunks are unforced
until a domain's apply/verify walks the SLICED value, and slicing
(`--member-name`) happens before `Domains.run_all` forces anything, so a
host's agent never even attempts to read another host's secret. Only the
dispatcher (run once, by whoever publishes the plan) holds both secrets.

## Per-clause tests (tests/052-devops-complete.sh; isolated HOMEs, three
$HOMEs control/web1/web2, both backends where not scheduler-specific)

1. **builds-from-source**: cold publish = exactly 2 execs (one cc,
   depfile-refined), null re-run = 0; materialized bin is `-x` and runs.
2. **deploys-across-2**: both hosts' `bin/greeter` byte-identical (one
   cc, two materializations from CAS); each `etc/greeter.conf` has only
   its own greeting/key; web2's file must NOT contain web1's key (cross-
   host leak check); both greeter processes running.
3. **converges-after-drift**: edit web1's greeting fixture (a pp mutator)
   → exactly web1's config node recomputes, web1's proc restarts
   (CONFIG_HASH env changed), web2 untouched; tamper a deployed file →
   restored zero-recompile; delete the binary → re-materialized from CAS,
   zero tool re-runs.
4. **converges-after-kill-9**: `kill -9` a member's greeter → new pid
   within one poll interval; the other host unaffected.
5. **secret-rotation** (§ below): the precision test.
6. **auditable**: `pp why` with the secret grant names the render node's
   read cells incl. `sealed:<...>` (id only, `#<sealed>` redaction — never
   bytes); without the grant, that cell is `<redacted unauthorized cell>`
   (LAW 23c, tests/019 pattern); the real key bytes absent from both
   runs' output.

## Secret rotation — causality chain (all existing mechanisms) + precision

Rotate web1.key bytes → `sealed:<web1.key>` cell hash changes →
`render-config "web1"`'s trace (which read it, LAW 23b transitive) fails
verification, and ONLY that key (`render-config "web2"` is a different
node key — different arg value hash, different sealed cell — its trace
re-verifies clean) → web1's config string recomputes → `host-desired`
re-derives (config + CONFIG_HASH change together, one binding, cannot
drift apart) → web1's fs domain diff sees changed content → rewrites just
that file → web1's proc diff sees spec-hash change → restarts just that
greeter. Web2's slice never even reaches its agent.

**Test asserts EXACTLY, nothing else**: web1 conf changed (grep a
synthetic marker, never the real bytes), web2 conf byte-identical; web1
greeter pid changed, web2 pid unchanged (`kill -0` original still
succeeds); web1 journal gained exactly one fs-update + one proc-restart
intent, web2 journal gained zero; the real rotated key bytes ABSENT from
all three $HOMEs' stores (M4b: store_blob never called for a sealed
read).

## Diagonal oracle

**Key finding: the demo's oracle needs zero pinning.** deploy.pp's
desired root is a pure function of `file:` and `sealed:` cells, whose
hashes `Store.observe_cell` computes from disk bytes with zero dependence
on backend/scheduler/placement (LAW 20's key definition). So all 12
combinations observe identical cells with no replay machinery.

The 2×2×3 = 12 combinations (backend tw/vm × scheduler pull/push ×
placement serial/parallel:N/remote:B):
- **Pull rows (1-6)**: `--publish-object` prints `hash_value` of the
  forced value; assert all six printed hashes string-equal. Placement
  transparency ALSO proven directly and cheaply by the EXISTING `--check`
  (re-runs Serial, compares hash, fails on mismatch — main.ml's
  schedule-transparency audit, whose `policy_name` already enumerates
  Remote): run `--schedule parallel:N --check` and `--schedule remote:B
  --check`, two green runs.
- **Push rows (7-12)**: `--publish-object` can't combine with `--watch`
  (by design), so use the tree-diff evidence form — `--watch --stabilize`
  settled tree `diff -rq`-clean against the pull rows' materialized tree
  (Q7's store-level collapse, already proven generically by tests/031/032,
  re-exercised on the demo's tree). Seed push with a different fixture
  first so a real dirty→re-force pass is exercised.
- `race:N` correctly EXCLUDED (intentionally non-deterministic; its
  is-served-correctly test is tests/038).

Assertion: the six pull hashes pairwise equal; the six push trees
pairwise diff-clean; row 7's tree diff-clean against a fresh `--reconcile`
of row 1's hash (tying the two evidence forms).

## Stage B — the pin seam (the one justified core addition)

Needed only to generalize the oracle's "probe cells are pinned inputs"
claim to a DIFFERENT adversarial program that folds a volatile probe into
desired state (the demo deliberately keeps probes report-only). Cannot be
done library-side: `Runtime.probe_values` has no pp-level bulk-populate.
Reuses Q11-bis's existing pin machinery (`Store.run_pins`,
`Remote.preseed_pins_from_file`/`parse_pin_line`, currently only behind
`--remote-node`):
- `--pin-file <path>`: `preseed_pins_from_file` minus the token/keys/reply
  ceremony (file cells — already-solved half).
- `(pin-probe "NAME" <codec-value>)` line kind: `Codec.decode_value` +
  `Hashtbl.replace Runtime.probe_values` (the ~15 genuinely-new lines).
- `--dump-pins <path>`: after run_files, write run_pins + probe_values as
  pin/pin-probe lines (non-data probe values skipped, mirroring node
  results).

Purely observability: no new authority, no write path, no key/hash change,
no desired-state-law change — completes an existing abstraction (§0.1
bar). tests/053-pin-observations.sh: an adversarial probe-in-desired-state
program run twice UNPINNED (legitimately different hashes — proves the
probe is really volatile) then across all 12 combinations PINNED
(identical) — the falsifiable proof of the masterplan's literal words,
fully separate from the demo.

## Doc corrections (with whichever commit lands them)

- `proc:` cells are dead code post-Q13 (runtime.ml:153-162; domain-proc
  reads domain-state directly, not a proc: cell). MASTERPLAN §1's oracle
  text names them as pinned inputs — stale; the real volatile surface is
  `probe:` alone. One-line correction to MASTERPLAN/DESIGN.
- register-proc-domain's write-cap: `cap-restrict` with a path mode
  against a bare CapProcess is a no-op/possible-error; pass
  `(current-capabilities)` unnarrowed. Verify against cap_restrict's
  signature at implementation.

## All-library audit (the thesis, made auditable)

Every demo ingredient maps to a landed, tested primitive/flag/stdlib:
node/LAW20 (tests/011), run-dep (022), blob (023), unseal/sealed (044),
register-*-domain (018/033), register-probe/probe (043), cap-restrict/
current-capabilities/with-caps (040), --watch (033/051), --member-name
(049), --publish/--desired-object (051), --schedule parallel/remote
(024/048), --check incl. remote (024/048), --bytecode parity (014),
pp why (019), pp gc (050), cluster transport (047). Zero src/*.ml changes
for the demo — the concrete evidence for "everything above the core is
libraries/islands."

## Exit

Stage A green (demo builds/deploys/converges/rotates/audits; 12-way
oracle holds) with ZERO core changes = the thesis proven. Stage B green =
the oracle claim generalized. Then MASTERPLAN M6 checked, the plan
complete.
