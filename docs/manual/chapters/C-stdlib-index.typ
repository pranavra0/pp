#import "/lib.typ": example

= Builtins and the standard library

This appendix indexes the two layers of pp's vocabulary that are not special
forms: the builtins compiled into the binary (`src/runtime/primitives.ml`) and the
standard library written in pp itself (`stdlib/*.pp`). Special forms — `if`,
`let`, `def`, `fn`, `delay`, `force`, `node`, `perform`, `with-handler`, `quote`, and
the rest — belong to the language reference, not here.

Signatures use pp calling syntax: `name(arg, …)`. A trailing `…` marks a
variadic position; `[arg]` marks an optional one. Unless noted, a builtin
forces the arguments it inspects; `cons`, `list`, `hash-map`, and `map` are
deliberately lazy in the values they carry.

== Dune adapter

`load("stdlib/dune.pp")` provides `dune-build(adapter, spec)`.
`:working-tree` observes a development tree and returns selected Dune output
as a canonical artifact tree. `:closed-source` executes the equivalent
immutable source/tool request through `run-closed!`. The library also exposes
`dune-closed-request(spec)` so release requests can be inspected, hashed, and
transported without execution. Dune target and output policy lives entirely
in this library.

== Core builtins

These are always in scope — no `load` needed.

=== Arithmetic and comparison

#table(
  columns: (auto, 1fr),
  inset: (x: 6pt, y: 4pt),
  align: (left, left),
  stroke: (x: none, y: 0.5pt + luma(220)),
  table.header([*Signature*], [*Description*]),
  [`+(n, …)`], [Variadic sum; identity 0. Mixing ints and floats promotes to float.],
  [`-(a, b)`], [Subtraction of exactly two numbers.],
  [`*(n, …)`], [Variadic product; identity 1.],
  [`/(a, b)`], [Division of two numbers; the divisor must be non-zero.],
  [`mod(a, b)`], [Integer remainder; the divisor must be non-zero.],
  [`=(a, …)`], [Structural equality; true iff all arguments are equal.],
  [`<(a, …)`, `>(a, …)`], [Variadic chained ordering: true iff each adjacent pair is strictly ordered.],
  [`<=(a, …)`, `>=(a, …)`], [As above, non-strict.],
)

=== Lists and pairs

#table(
  columns: (auto, 1fr),
  inset: (x: 6pt, y: 4pt),
  align: (left, left),
  stroke: (x: none, y: 0.5pt + luma(220)),
  table.header([*Signature*], [*Description*]),
  [`cons(a, b)`], [Build a pair, storing both parts unforced (lazy).],
  [`car(p)`], [First element of a pair; `nil` for `nil`.],
  [`cdr(p)`], [Rest of a pair; `nil` for `nil`.],
  [`list(x, …)`], [Build a proper list from its arguments (lazy in the elements).],
  [`apply(f, …segments)`], [Apply `f` to the concatenated argument lists; used by call-spread syntax.],
  [`map(f, lst)`], [Apply `f` to each element, consing the results without forcing them — the parallel fan-out point the scheduler batches on.],
  [`nil?(x)`], [True if `x` is `nil`.],
)

=== Vectors, maps, and sets

#table(
  columns: (auto, 1fr),
  inset: (x: 6pt, y: 4pt),
  align: (left, left),
  stroke: (x: none, y: 0.5pt + luma(220)),
  table.header([*Signature*], [*Description*]),
  [`vector(x, …)`], [Build a vector (lazy in the elements).],
  [`vector-get(v, i)`], [Element `i` of vector `v`; out-of-bounds is an error.],
  [`hash-map(k, v, …)`], [Build a map from alternating keys and values; keys are forced, values stay lazy.],
  [`hash-map-get(m, k)`], [Value bound to `k` in `m`, or `nil`.],
  [`map-insert(m, k, v)`], [A new map with `k` bound to `v` (replacing any existing binding).],
  [`map-remove(m, k)`], [A new map without key `k`.],
  [`map-keys(m)`], [The keys of `m` as a list.],
  [`map-vals(m)`], [The values of `m` as a list.],
  [`hash-set(x, …)`], [Build a set (lazy in the elements).],
)

=== Type predicates

Each takes one argument, forces it, and returns a boolean.

#table(
  columns: (auto, 1fr),
  inset: (x: 6pt, y: 4pt),
  align: (left, left),
  stroke: (x: none, y: 0.5pt + luma(220)),
  table.header([*Predicate*], [*True when the value is…*]),
  [`int?(x)`, `float?(x)`], [an integer / a float.],
  [`string?(x)`, `bool?(x)`], [a string / a boolean.],
  [`keyword?(x)`, `symbol?(x)`], [a keyword / a symbol.],
  [`pair?(x)`], [a pair or `nil`.],
  [`vector?(x)`, `map?(x)`, `set?(x)`], [a vector / a map / a set.],
  [`fn?(x)`], [a closure or builtin.],
  [`thunk?(x)`], [an unforced thunk (does not force its argument).],
  [`capability?(x)`], [a capability.],
)

=== Strings and numbers

#table(
  columns: (auto, 1fr),
  inset: (x: 6pt, y: 4pt),
  align: (left, left),
  stroke: (x: none, y: 0.5pt + luma(220)),
  table.header([*Signature*], [*Description*]),
  [`string-append(s, …)`], [Concatenate; non-string arguments are rendered first.],
  [`string-length(s)`], [Length of a string in bytes.],
  [`->string(v)`], [Render any value without string quotes; strings are returned unchanged.],
  [`string-split(s, sep)`], [Split `s` on the single-character `sep`, dropping empty fields.],
  [`string-index(s, sub)`], [Index of the first occurrence of `sub`, or `nil`.],
  [`string-trim(s)`], [`s` with leading and trailing whitespace removed.],
  [`string-sub(s, start, len)`], [The `len`-byte substring at `start`; out-of-bounds is an error.],
  [`number->string(n)`], [Decimal rendering of an int or float.],
  [`string->number(s)`], [Parse to an int, else a float, else `nil`.],
)

=== I/O and control

#table(
  columns: (auto, 1fr),
  inset: (x: 6pt, y: 4pt),
  align: (left, left),
  stroke: (x: none, y: 0.5pt + luma(220)),
  table.header([*Signature*], [*Description*]),
  [`print(x, …)`], [Deep-force each argument, print them concatenated with a trailing newline, and return `nil`.],
  [`not(x)`], [Logical negation; `nil` counts as false.],
  [`error(msg)`], [Raise an error with string message `msg`.],
  [`exit([n])`], [Terminate the run with status `n` (default 0).],
  [`slurp(path)`], [Read a file to a string. Needs an `fs` read grant (or a `secret` grant, which yields a sealed value); capability-free inside a node's scratch sandbox.],
  [`argv()`], [The program arguments after `--`, as a list of strings. Recorded as an `argv:` observation.],
  [`env-get(name)`], [The environment variable `name`, or `nil`. Recorded as an `env:` observation.],
)

=== Filesystem observation

Capability-gated presence checks, recorded as `stat:` cells so a node
recomputes exactly when the path appears, disappears, or changes kind — never
reading contents.

#table(
  columns: (auto, 1fr),
  inset: (x: 6pt, y: 4pt),
  align: (left, left),
  stroke: (x: none, y: 0.5pt + luma(220)),
  table.header([*Signature*], [*Description*]),
  [`file-exists?(path)`], [True if anything exists at `path`. Needs an `fs` read grant.],
  [`dir?(path)`], [True if `path` is a directory. Needs an `fs` read grant.],
)

=== Hashing and the content store

#table(
  columns: (auto, 1fr),
  inset: (x: 6pt, y: 4pt),
  align: (left, left),
  stroke: (x: none, y: 0.5pt + luma(220)),
  table.header([*Signature*], [*Description*]),
  [`hash-value(v)`], [A canonical structural content hash of any value — order-independent for maps and sets.],
  [`hash-string(s)`], [The SHA-256 hex digest of a string's raw bytes (pure; no store I/O).],
  [`blob(s)`], [Ingest bytes into the content store, returning the SHA-256 identity.],
  [`blob-get(hash)`], [The inverse of `blob`: the stored bytes for a blob identity.],
)

=== Capabilities

#table(
  columns: (auto, 1fr),
  inset: (x: 6pt, y: 4pt),
  align: (left, left),
  stroke: (x: none, y: 0.5pt + luma(220)),
  table.header([*Signature*], [*Description*]),
  [`current-capabilities()`], [Reify the ambient capability set as of the call — an observation of the ceiling, never a mint.],
  [`cap-compose(c, …)`], [Compose several capabilities into one.],
  [`cap-restrict(cap, scope, [:ro|:rw|:wo])`], [Narrow `cap` to a scope string and, optionally, a weaker mode.],
  [`cap-none()`], [The empty capability (grants nothing).],
)

=== Effects, domains, and metaprogramming

`stdlib/runtime.pp` provides `schedule-serial`, `schedule-parallel`,
`schedule-race`, `schedule-custom`, `runtime-manifest`, reporter constructors,
and policy helpers. `configure-runtime` installs a manifest at script scope.
`stdlib/domain.pp` provides generic domain and probe registration helpers.

#table(
  columns: (auto, 1fr),
  inset: (x: 6pt, y: 4pt),
  align: (left, left),
  stroke: (x: none, y: 0.5pt + luma(220)),
  table.header([*Signature*], [*Description*]),
  [`register-domain({…})`], [Register a write-domain from a spec map (`:name`, `:namespace`, `:observe`, `:diff`, `:apply`, `:write-cap`). Script-tier only — not inside a node body.],
  [`register-probe(name, observe-fn, read-cap)`], [Register a read-only probe: a domain with no write authority. Script-tier only.],
  [`probe(name)`], [Read a registered probe's value, pinned once per pass and recorded as a `probe:` cell.],
  [`fenced(kind, spec)`], [Register a non-convergent (fenced) action for the reconciler to drain after convergent state is applied.],
  [`collect(results)`], [Partition `[:ok, value]` and `[:err, error]` results into one aggregate result.],
  [`unseal(v)`], [Convert a sealed value to a string — the one sanctioned exit from `secret:` bytes.],
  [`eval-pp(code)`], [Parse and evaluate a code string in the current run's environment and macro table.],
  [`apply-pp(fn, args)`], [Apply `fn` to a list of already-evaluated arguments.],
  [`force-deep(v)`], [Fully force a value and everything reachable from it.],
  [`read-string(src)`], [Parse a source string to a quoted value (or a vector of them).],
  [`gensym([prefix])`], [A fresh, unwritable symbol for hygienic macro bindings.],
)

The reader forms `quasiquote`, `unquote`, and `unquote-splicing` are also
registered as builtins, and you normally reach them through the reader's
quasiquote syntax; outside a quasiquote the latter two are an error. The

== Lists

`stdlib/list.pp` — load with `load("list.pp")`. Note that `map` is not here:
it is a builtin, on purpose, so a loaded list library cannot shadow the
scheduler's fan-out point.

#table(
  columns: (auto, 1fr),
  inset: (x: 6pt, y: 4pt),
  align: (left, left),
  stroke: (x: none, y: 0.5pt + luma(220)),
  table.header([*Signature*], [*Description*]),
  [`filter(pred, lst)`], [A lazy list of the elements satisfying `pred`.],
  [`foldl(f, acc, lst)`], [Left fold, strict in the accumulator.],
  [`foldr(f, acc, lst)`], [Right fold, lazy.],
  [`range(start, end)`], [The integers from `start` (inclusive) to `end` (exclusive).],
  [`take(n, lst)`], [The first `n` elements.],
  [`drop(n, lst)`], [`lst` without its first `n` elements.],
  [`nth(n, lst)`], [Zero-based element access; `nil` past the end.],
  [`length(lst)`], [Element count (strict — forces the whole list).],
  [`each(f, lst)`], [Apply `f` to each element for effect; returns `nil`.],
  [`append(a, b)`], [Concatenate two lists (lazy in `b`).],
  [`reverse(lst)`], [Strict reversal.],
  [`member?(x, lst)`], [Structural membership test.],
)

== Maps

`stdlib/map.pp` — load with `load("map.pp")`; depends on `list.pp`.

#table(
  columns: (auto, 1fr),
  inset: (x: 6pt, y: 4pt),
  align: (left, left),
  stroke: (x: none, y: 0.5pt + luma(220)),
  table.header([*Signature*], [*Description*]),
  [`map-has?(m, k)`], [Whether `k` is a key of `m`.],
  [`map-merge(a, b)`], [`a` with every binding of `b` inserted; `b` wins on collision.],
)

== Strings

`stdlib/string.pp` — load with `load("string.pp")`; no dependencies.

#table(
  columns: (auto, 1fr),
  inset: (x: 6pt, y: 4pt),
  align: (left, left),
  stroke: (x: none, y: 0.5pt + luma(220)),
  table.header([*Signature*], [*Description*]),
  [`string-join(sep, lst)`], [Join a list of strings with `sep` between elements.],
  [`starts-with?(s, prefix)`], [Whether `s` begins with `prefix`.],
  [`ends-with?(s, suffix)`], [Whether `s` ends with `suffix`.],
  [`lines(s)`], [Split `s` into lines, dropping empty fields.],
)

== Domains

The domain policies are pp libraries that `pp` auto-loads for you:
`stdlib/domain-fs.pp` under `--reconcile`, `stdlib/domain-proc.pp` under
`--supervise` (each after `list.pp`, `map.pp`, and `string.pp`). The trusted
mechanics they call — `tree-observe`, `materialize-file`, `proc-spawn`, and so
on — are OCaml primitives reached only through `perform`. You normally interact
with a domain through the registration entry point; the rest are its internal
policy, listed here for readers of the source.

The one entry point you call directly:

#table(
  columns: (auto, 1fr),
  inset: (x: 6pt, y: 4pt),
  align: (left, left),
  stroke: (x: none, y: 0.5pt + luma(220)),
  table.header([*Signature*], [*Description*]),
  [`register-fs-domain(root, write-cap)`], [Register the filesystem domain rooted at `root`, converging a canonical tree value.],
  [`register-proc-domain(write-cap)`], [Register the process domain, converging a `{name → spec}` map (spec: `cmd`/`args`/`env`/`cwd`).],
)

=== Filesystem policy internals (`domain-fs.pp`)

#table(
  columns: (auto, 1fr),
  inset: (x: 6pt, y: 4pt),
  align: (left, left),
  stroke: (x: none, y: 0.5pt + luma(220)),
  table.header([*Signature*], [*Description*]),
  [`fs-content-hash(c)`], [A file descriptor's blob identity.],
  [`fs-content-bytes(c)`], [The bytes named by a file descriptor.],
  [`fs-validate-rel-part(rel, part)`], [Reject `..` in a desired path component.],
  [`fs-validate-rel(rel)`], [Validate that a desired path is relative and traversal-free.],
  [`fs-plan-item(kind, rel, content)`], [Build one create/update/delete plan item.],
  [`fs-diff-for(root)`], [Return the pure `(observed desired) → plan` diff, closed over `root`.],
  [`fs-apply-item(root, item)`], [Materialize or remove one file per plan item.],
  [`fs-apply-for(root)`], [Return the apply function that runs each plan item.],
)

=== Process policy internals (`domain-proc.pp`)

#table(
  columns: (auto, 1fr),
  inset: (x: 6pt, y: 4pt),
  align: (left, left),
  stroke: (x: none, y: 0.5pt + luma(220)),
  table.header([*Signature*], [*Description*]),
  [`proc-state-key(name)`], [The domain-state key under which a service's record is stored.],
  [`proc-known-names()`], [The domain's own index of tracked service names.],
  [`proc-remember!(name, pid, spec, known)`], [Record a running service and add it to the known set.],
  [`proc-forget!(name, known)`], [Clear a service's record and drop it from the known set.],
  [`proc-observe-one(name)`], [Observe one service: its spec if alive, `:stopped` if tracked-but-dead, else `nil`.],
  [`proc-observe()`], [Reap zombies, then observe every tracked service.],
  [`proc-plan-item(kind, name, spec)`], [Build one start/restart/stop plan item.],
  [`proc-spec-eq?(a, b)`], [Compare two specs by canonical `hash-value` (immune to map-order differences).],
  [`proc-diff(observed, desired)`], [The pure diff: start / restart / stop by spec change.],
  [`proc-stop-current!(name)`], [Stop a service at its currently-recorded pid.],
  [`proc-apply-item(known, item)`], [Apply one plan item, returning the updated known set.],
  [`proc-apply(plan)`], [Fold every plan item, then persist the known set once.],
)
