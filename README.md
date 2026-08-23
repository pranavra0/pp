# pp

pp is a content-addressed, capability-scoped language with a single
tree-walking evaluator implemented in Common Lisp.

Every value has a content hash. Two computations with the same code and
inputs are the same computation, so caching and deduplication follow from
identity. Side effects need capabilities: authority tokens, minted at the
root, that a computation must hold before it can touch the world.

## Getting started

```sh
scripts/build-lisp.sh --output lisp/pp
bin/pp file.pp
```

The build requires SBCL and creates a saved executable image. Ordinary
invocations run that image; pp never asks the host reader to parse source.

The package is authored by Pranav Rao and distributed under the MIT License;
see [LICENSE](LICENSE).

Run `bin/pp --help` to see all flags.

Highlights:

- incremental computation: persistent nodes validate recorded world reads,
  reuse results across processes, and cut off unchanged dependents
- artifact builds: `stdlib/dune.pp` observes a working tree and returns
  immutable artifact trees, or creates a closed execution request
- reactive supervision: `pp --watch --supervise` starts services and
  restarts them when the spec changes
- parallel builds: `--schedule parallel:4` forks workers to handle node misses
- cluster distribution: signed tokens, by-hash sync, remote placement, and
  store garbage collection, within the tested transport and store scenarios
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

- [docs/manual/](docs/manual/): reference manual, all examples run by pp
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): how the code fits together
- [docs/SPEC.md](docs/SPEC.md): semantic laws and current status table
- [AGENTS.md](AGENTS.md): contributor and coding-agent guide

Run `scripts/run-tests.sh bin/pp` for the test suite.
