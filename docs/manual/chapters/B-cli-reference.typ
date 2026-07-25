#import "/lib.typ": example

= Command-line reference

This appendix lists every flag `pp` accepts, grouped by what you use it for.
It comes from the argument parser in `src/app/main.ml`. Where the built-in
`pp --help` and this table disagree, the source wins. A few flags marked
internal are dispatch machinery that `pp` invokes on itself. They are here for
completeness; you should not need to type them by hand.

Flags compose the way you would expect: `--grant`, `--schedule`,
and `--watch` all layer onto whichever run mode you pick. Anything after a bare
`--` becomes the program's own argument vector, which you read with `argv()`.

== Running programs

#table(
  columns: (auto, 1fr),
  inset: (x: 6pt, y: 4pt),
  align: (left, left),
  stroke: (x: none, y: 0.5pt + luma(220)),
  table.header([*Invocation*], [*Meaning*]),
  [`pp`], [Start the REPL (tree-walker).],
  [`pp <file.pp>`], [Read and run a source file; the program's value is its last top-level form.],
  [`pp run <file>`], [Same as `pp <file>` — `run` is an explicit subcommand spelling.],
  [`pp -e '<expr>'`], [Evaluate one expression string and print each top-level value.],
  [`pp --once <file.pp>`], [Run once and exit. A no-op: this is already the default; the flag is for symmetry with `--watch`.],
  [`pp -- <args…>`], [Everything after `--` becomes the program's argv, read via the `argv()` builtin.],
  [`pp --version`, `pp -v`], [Print the version and exit.],
  [`pp --help`, `pp -h`], [Print the usage summary and exit.],
)

== Back ends

pp has a single tree-walking interpreter over the content-addressed store.
Tail calls run in constant stack, and node results persist across runs.

#table(
  columns: 2,
  stroke: none,
  inset: 8pt,
  align: (left, left),
  table.header([*Flag*], [*Meaning*]),
  [`--once <file.pp>`], [Run once and exit (the default).],
  [`--watch <file.pp>`], [Run, then re-run when observed cells change.],
  [`--reconcile <root> <file.pp>`], [Treat the program's final value as a desired file tree and converge `<root>` to it.],
)

== Capabilities and grants

Side effects that touch the world require a capability, and capabilities enter
a run only here, on the command line. `--grant` is repeatable; each grant is a
colon-separated spec. Paths are canonicalized at the grant, so downstream
authority checks and cell identities see one spelling.

#table(
  columns: (auto, 1fr),
  inset: (x: 6pt, y: 4pt),
  align: (left, left),
  stroke: (x: none, y: 0.5pt + luma(220)),
  table.header([*Grant spec*], [*Authority granted*]),
  [`fs:<path>:ro`], [Read access to a filesystem path (and everything under it).],
  [`fs:<path>:rw`], [Read and write access to a path.],
  [`fs:<path>:wo`], [Write-only access to a path.],
  [`net:<host>`], [Network access to a host, any port.],
  [`net:<host>:<port>`], [Network access to a host on one port.],
  [`secret:<path>`], [Read a path as a sealed value (bytes never enter the store; `unseal` is the one way out).],
  [`process`], [Spawn, signal, and reap child processes.],
)

Usage: `pp --grant fs:/tmp/build:rw --grant process <file.pp>`. Any of the
world-touching primitives (`slurp`, the `fs`/`proc` domains, network effects)
raises a capability error if the matching grant is absent.

== The store and auditing

Every node's result is content-addressed and cached in `~/.pp/store`. These
flags inspect, bypass, audit, and reclaim that store.

#table(
  columns: (auto, 1fr),
  inset: (x: 6pt, y: 4pt),
  align: (left, left),
  stroke: (x: none, y: 0.5pt + luma(220)),
  table.header([*Flag*], [*Meaning*]),
  [`why <file.pp>` (`--why`)], [Run the file and explain each node's cache hit or miss. Capability-filtered: you only see nodes you had authority to observe.],
  [`--no-cache <file.pp>`], [Skip cache reads and recompute every node; results are still written to the store.],
  [`--check <file.pp>`], [Determinism audit: run each node twice and flag any whose result differs (a volatile node). With a non-serial `--schedule`, also re-runs the whole program serially and compares the desired-state hash. Exits 1 if anything is flagged.],
  [`graph`], [Print the cell→node dependency graph reconstructed from stored traces. Needs no file.],
  [`gc`], [Explicit store garbage collection (never automatic). Marks the store reachable from the last N reconcile/supervise epochs by replaying them, then sweeps the rest.],
  [`gc --gc-keep-epochs <N>`], [Keep the last N epochs (a small built-in default; N > 0).],
  [`gc --gc-grace-seconds <S>`], [Spare anything younger than S seconds from the sweep (S ≥ 0).],
)

== Reconcile, watch, and supervise

These turn a program's value into managed state in the world. `--reconcile`
materializes a `{relpath → content}` map as a file tree; `--supervise` drives a
`{name → spec}` map of long-running processes. Both auto-load their domain
policy from the stdlib and both are effectful, so both need grants.

#table(
  columns: (auto, 1fr),
  inset: (x: 6pt, y: 4pt),
  align: (left, left),
  stroke: (x: none, y: 0.5pt + luma(220)),
  table.header([*Flag*], [*Meaning*]),
  [`--reconcile <root> <file.pp>`], [Materialize the program's map value as a file tree under `<root>`, creating/updating/deleting by content hash. Auto-loads `stdlib/domain-fs.pp`. Needs `fs:<root>:wo` (or `:rw`).],
  [`--supervise <file.pp>`], [Converge the program's process map: start/restart/stop services to match it. Auto-loads `stdlib/domain-proc.pp`. Needs `process`. Pair with `--watch` to keep services alive.],
  [`--watch <file.pp>`], [Run, then poll the observed cells and re-evaluate whenever one changes. Combines with `--reconcile`/`--supervise` to re-converge on drift.],
  [`--stabilize`], [With `--watch`: propagate changes by dirtying only the affected nodes (push stabilization) rather than re-running cold.],
  [`--watch-interval <s>`], [Poll interval for `--watch`, in seconds (default 1.0).],
  [`--fenced-policy retry|abort|ask`], [How to treat a fenced (non-convergent) action left in an unknown state by a prior crash. Default `abort`.],
)

== Islands

Islands are content-addressed module pins — a git ref resolved to a hash and
recorded inline in the source. These flags manage the pins.

#table(
  columns: (auto, 1fr),
  inset: (x: 6pt, y: 4pt),
  align: (left, left),
  stroke: (x: none, y: 0.5pt + luma(220)),
  table.header([*Flag*], [*Meaning*]),
  [`island-pins <file.pp>`], [List the file's island forms with their pin and cache status. Does not run the program.],
  [`--update <file.pp>`], [Re-resolve each island ref and rewrite the inline pins in place, then run. Implies `--fetch-islands`.],
  [`--fetch-islands`], [Allow a git fetch for island pins not already cached (off by default — an offline run only uses what the store already holds).],
)

== Scheduling and distribution

By default, pp computes node misses serially, in-process. `--schedule` changes
where and how they run, up to placing them on other cluster members. The M5
cluster flags establish trust (`cluster-init`, `--mint-token`) and move desired
state between machines by hash (`--publish-object`, `--desired-object`).

#table(
  columns: (auto, 1fr),
  inset: (x: 6pt, y: 4pt),
  align: (left, left),
  stroke: (x: none, y: 0.5pt + luma(220)),
  table.header([*Flag*], [*Meaning*]),
  [`--schedule serial`], [Compute node misses one at a time, in-process (the default).],
  [`--schedule parallel:<N>`], [Fan out independent misses across up to N workers.],
  [`--schedule race:<N>`], [Race up to N redundant computations, taking the first to finish.],
  [`--schedule remote:<member>`], [Place misses on a named cluster member.],
  [`cluster-init`], [Mint `~/.pp/cluster/{secret,id}` — the cluster's trust anchor.],
  [`--mint-token <out> <ttl-secs>`], [Mint a signed cluster token into `<out>`, carrying whatever `--grant` specs accompany it, valid for `<ttl-secs>`.],
  [`--member-name <n> <file.pp>`], [Host-qualified distribution: treat the desired state as a `{host → {domain → desired}}` map and converge only host `<n>`'s slice. Combine with `--reconcile`/`--supervise`.],
  [`--publish-object <shared-root> <file.pp>`], [Run the program, store its fully-forced value and canonical tree blobs in a shared local-dir store by hash, and print the hash.],
  [`--desired-object <hash> <shared-root>`], [Pull a published value by `<hash>` from `<shared-root>` and converge it directly — never runs a program to derive it. Takes `--member-name` and the reconcile/supervise flags.],
)

=== Internal transport (not for hand use)

`pp` invokes these on itself to move artifacts and dispatch remote work. They
are low-level and explicit by design; a normal run never types them.

#table(
  columns: (auto, 1fr),
  inset: (x: 6pt, y: 4pt),
  align: (left, left),
  stroke: (x: none, y: 0.5pt + luma(220)),
  table.header([*Flag*], [*Meaning*]),
  [`--transport-push object|blob|trace <id> <root>`], [Copy one artifact into a shared local-dir store.],
  [`--transport-pull object|blob|trace <id> <root>`], [Copy one artifact out of a shared local-dir store (re-hash-verified on ingest).],
  [`--serve-hit <key> <token-file> <shared-root> <reply-file>`], [Capability-gated cache lookup served to a dispatcher.],
  [`--recv-hit <reply-file> <shared-root>`], [Ingest a `serve-hit` reply.],
  [`--remote-node <token> <pins> <root> <keys> <reply>`], [The cluster-member side of remote placement; authority comes from the verified token, not `--grant`.],
  [`--gc-mark <outfile>`], [Used only by `pp gc`'s own replay subprocess to record the live set.],
)

== Observation pinning

These capture and replay the exact set of world observations a run made — the
seam that lets one machine pin another's reads (and the basis of remote
placement's pin wire).

#table(
  columns: (auto, 1fr),
  inset: (x: 6pt, y: 4pt),
  align: (left, left),
  stroke: (x: none, y: 0.5pt + luma(220)),
  table.header([*Flag*], [*Meaning*]),
  [`--pin-file <path> <file.pp>`], [Preseed the run's cell observations and probe values from a file of `(pin …)` / `(pin-probe …)` lines before the program runs, so it never observes its own disk for a pinned cell.],
  [`--dump-pins <path> <file.pp>`], [After the run, write every observed cell and probe value to `<path>` as `(pin …)` / `(pin-probe …)` lines. A probe value that is not plain data (code, a handle, a sealed secret) is skipped with a warning.],
)

The pin-file's `(pin …)` / `(pin-probe …)` lines are their own small wire
format (`src/runtime/remote.ml`'s `parse_pin_line`), not pp source — they are not
read by either pp reader, so they keep their fixed parenthesized shape
regardless of the surface a program is written in.
