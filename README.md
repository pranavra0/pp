# pp

pp is a content-addressed, capability-scoped language with a single
tree-walking evaluator engine.

Every value has a content hash. Two computations with the same code and
inputs are the same computation, so caching and deduplication follow from
identity. Side effects need capabilities: authority tokens, minted at the
root, that a computation must hold before it can touch the world.

## Getting started

```sh
opam install dune cryptokit
dune build
pp file.pp
```

Run `pp --help` to see all flags.

Highlights:

- hermetic builds: rebuilding this 101-file C project when nothing changed
  takes 0 processes and 130ms. `rm -rf build/` restores everything from the
  store. pp builds itself, and Lua 5.4.7 too
- reactive supervision: `pp --watch --supervise` starts services and
  restarts them when the spec changes. Kill one with `-9` and it converges
  back within one interval
- parallel builds: `--schedule parallel:4` forks workers to handle node
  misses
- cluster distribution: signed tokens, by-hash sync, remote placement,
  host-qualified distribution, and store garbage collection
- two syntaxes: `.pp` uses braces and infix notation; `.ppl` uses
  s-expressions, the AST written as text, for macros. `pp fmt` converts
  between them

## A tour

```
node {
  "src/*.c" |> each(fn(f) {
    perform run("cc", "-c", f)
  })
}

with-config({:host -> "db1"}) {
  let key = perform read-file("/run/secrets/key") |> unseal
  print(key)
}

let (m = module { def double(x) { x * 2 } }) {
  import(m); double(21)
}
```

## Layout

- `src/` — the OCaml implementation: the pure `pp.kernel` library, the `pp`
  runtime library built on it, and the `main` entry point
- `bin/` — `bin/pp`, a symlink to the built interpreter, put on PATH by direnv
- `stdlib/` — the pp standard library (`list`, `map`, `string`) and the
  domain policies (`domain-fs`, `domain-proc`) auto-loaded by
  `--reconcile`/`--supervise`
- `tests/` — the test suite (see docs/TESTING.md)
- `tools/` — the metamorphic fuzzer
- `scripts/` — build and test entry points: `run-tests.sh`, `build-self.sh`,
  `build-lua.sh`, `build-manual.sh`
- `examples/` — small standalone pp programs, executed by the suite and swept
  by the reader and `pp fmt` round-trip tests
- `demo/` — larger worked examples (deploy, agent) with their fixtures
- `docs/` — the specification, design rationale, and reference manual
- `.github/` — CI workflows
- `fuzz-failures/` — the fuzzer's output directory for shrunk counterexamples
  (generated, gitignored)

## Documentation

Read more:

- [docs/manual/](docs/manual/) — reference manual, all examples run by pp
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — how the code fits together
- [docs/SPEC.md](docs/SPEC.md) — semantic laws and current status table
- [AGENTS.md](AGENTS.md) — for AI coding agents

Run `dune runtest` for the test suite.
