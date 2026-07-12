# Changelog

All notable changes to pp are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions before
v0.2.0 predate this file and are reconstructed from history for context.

## [Unreleased] — v0.2.0

- **Phase 1 closed**: pp is a proven incremental hermetic build engine — a
  101-TU C project builds through a real `build.pp` meeting every exit
  criterion (null rebuild, mtime-only touch, single-file recompile+link,
  byte-identical store restore, header-edit cutoff, authority-gated hits);
  `pp` builds itself (`scripts/build-self.sh`) and builds real-world Lua
  5.4.7 the same way (`scripts/build-lua.sh`). See
  [docs/STATUS.md](docs/STATUS.md), [docs/ROADMAP.md](docs/ROADMAP.md).
- **Phase 2 groundwork closed**: `pp --watch`/`--once`/`graph`, push
  `stabilize`, the process-domain reconciler (`--supervise`), and fenced
  effects (LAW 31, `(fenced KIND SPEC)` with retry/abort/ask policies) are
  all live with cross-backend parity. See
  [docs/STATUS.md](docs/STATUS.md).
- **Islands (D2) closed**: `(island <uri> "64-hex-pin")` is a
  content-addressed module — the inline pin is part of the code hash, no
  lockfile or synthetic cell — with tamper detection, opt-in fetch
  (`--fetch-islands`), and `pp --update`/`pp island-pins` tooling. See the
  discrepancy ledger in [docs/STATUS.md](docs/STATUS.md) and `tests/035`.
- **LAW 23 cell-id canonicalization (M2.1)**: absolute realpath
  canonicalization applied uniformly at every cell/grant/loader-bound site,
  so a symlinked source tree and macOS `/var` vs `/private/var` are one
  cell. See [docs/ROADMAP.md](docs/ROADMAP.md) (maturity §3), `tests/036`.
- **Portable store format (M2.2)**: `~/.pp/store`'s `objects/`, `traces/`,
  `procs/`, and `fenced-specs/` moved off OCaml `Marshal` onto a versioned,
  canonical s-expr text/byte codec (`src/codec.ml`), gated on a `VERSION`
  stamp with clean upgrade-wipe of legacy stores. See
  [docs/TESTING.md](docs/TESTING.md), `tests/037`.
- **MASTERPLAN**: added [docs/MASTERPLAN.md](docs/MASTERPLAN.md), sequencing
  the milestones (M1–M6) from the proven engine to "devops solved
  in-language."
- **CI + versioning (M2.3)**: GitHub Actions CI on Linux + macOS
  (`.github/workflows/ci.yml`); `pp --version`/REPL banner now report a
  real version via `dune-build-info` instead of a hardcoded string; see
  [docs/RELEASING.md](docs/RELEASING.md).
- **Phase 3 (M1) closed — process-pool parallelism**: `--schedule
  serial|parallel:N|race:N` (new `src/scheduler.ml`) forks worker processes
  at the dispatch point for persistent-node misses. A new non-forcing `map`
  builtin closes Wall A (the missing batch fan-out point — `EApply` forces
  every argument, so no compound value could hold several unforced node
  thunks at once); `force-deep` collects a batch of unevaluated nodes and
  dispatches them before its ordinary recursive walk. A worker runs
  `Evaluator.run_node_body` — the exact function the serial miss arm
  calls, no second force path — and the parent only ever re-enters
  `Store.hit`, so a dead worker degrades to an ordinary serial recompute,
  never a wrong answer. `--check` under a non-serial policy re-runs the
  program forced serial against the same store and fails on any
  desired-state hash mismatch (the schedule-transparency audit). Landed as
  fork-at-dispatch rather than the `Runtime` global-state refactor
  MASTERPLAN M1 originally called for — `fork()` inherits ambient state
  byte-identically via copy-on-write, so the refactor isn't on this
  critical path (documented as an M5 design item instead — see
  [docs/DESIGN.md](docs/DESIGN.md) Q9/Q11-bis,
  [docs/MASTERPLAN.md](docs/MASTERPLAN.md) M1). Store hardening: a per-key
  `lockf` around `store_trace`'s read-modify-write, and `Journal.append` as
  one `Unix.write_substring` on an O_APPEND fd, so N concurrent writers
  can't drop or tear each other's lines. The Phase-1 101-TU build is 4-5x
  faster under `parallel:N` from cold with a byte-identical result to
  serial. See [docs/STATUS.md](docs/STATUS.md), `tests/024`'s `p3-*`
  assertions, `tests/038`.
