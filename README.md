# pp

pp is a content-addressed, capability-scoped language with a single
tree-walking evaluator engine.

Every value has a content hash. Two computations with the same code and
inputs are the same computation, so caching and deduplication follow from
identity. Side effects need capabilities: authority tokens, minted at the
root, that a computation must hold before it can touch the world.

## Getting started

```sh
opam install .
dune build
pp file.pp
```

The package is authored by Pranav Rao and distributed under the MIT License;
see [LICENSE](LICENSE).

Run `pp --help` to see all flags.

Highlights:

- incremental computation: persistent nodes validate their recorded world
  reads, reuse results across processes, and cut off unchanged dependents
- artifact builds: the Dune adapter performs precise working-tree rebuilds,
  returns immutable artifact trees, and restores deleted outputs from the store
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

Foreign execution is provider-owned. The bundled Linux executor closes the
filesystem, environment, loader, and network but reports its remaining ambient
inputs, so it is scripting-only. A trusted provider may classify an immutable
request as cacheable when it can guarantee that the request accounts for every
semantic input. Toolchain and execution-policy schemas remain ordinary pp
libraries; the optional `:policy` field is canonical pp data that only the
provider interprets.

## A tour

```
let digest = force(node { hash-string($file("src/main.c")) })

with-config({:host -> "db1"}) {
  let key = perform read-file("/run/secrets/key") |> unseal
  print(key)
}

let (m = module { def double(x) { x * 2 } }) {
  import(m); double(21)
}
```

## Documentation

Read more:

- [docs/manual/](docs/manual/) — reference manual, all examples run by pp
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — how the code fits together
- [docs/SPEC.md](docs/SPEC.md) — semantic laws and current status table
- [AGENTS.md](AGENTS.md) — for AI coding agents

Run `dune runtest` for the test suite.
