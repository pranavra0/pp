# pp

A content-addressed, capability-scoped language with two back ends that must
produce identical output. Every value has a content hash, so two computations
with the same code and inputs are the same computation — caching and
deduplication follow from identity. Side effects need capabilities: authority
tokens, minted at the root, that a computation must hold to touch the world.

## Getting started

```sh
opam install dune cryptokit
dune build
pp file.pp
```

`pp --help` for all flags.

- Hermetic builds. 101-file C project, null rebuild at 0 processes in 130ms.
  `rm -rf build/` restores from the store. pp builds itself. Lua 5.4.7 too.
- Reactive supervision. `pp --watch --supervise` starts and restarts services
  on spec change. Kill one with `-9`; it converges back within one interval.
- Parallel builds. `--schedule parallel:4` forks workers for node misses.
- Cluster distribution. Signed tokens, by-hash sync, remote placement,
  host-qualified distribution, store GC.
- Two syntaxes, `.pp` is braces and infix. `.ppl` is
  s-expressions (the AST as text, for macros). `pp fmt` transpiles between
  them. 

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

def double(x) { x * 2 }
let (m = module { export double }) {
  import(m); double(21)
}
```

## Documentation

- [docs/manual/](docs/manual/) — reference manual, all examples run by pp
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — how the code fits together
- [docs/STATUS.md](docs/STATUS.md) — what works, discrepancy ledger
- [AGENTS.md](AGENTS.md) — for AI coding agents

Run `dune runtest` for the test suite.
