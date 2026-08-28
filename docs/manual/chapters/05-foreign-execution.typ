#import "/lib.typ": example

= Foreign execution

pp separates computation semantics from execution policy. The language has no
compiler, package, container, platform, or Nix form. Libraries build immutable
requests as ordinary maps. A trusted host provider decides how to execute one.

`run` is the ambient process effect: command arguments, inherited host
behavior, always scripting-tier — the request does not account for everything
that can affect the result.

`run-closed!` takes immutable tool and input trees, explicit arguments,
environment, platform constraints, and selected outputs:

```pp
run-closed!({
  :tool -> tool-tree,
  :tool-path -> "bin/tool",
  :args -> ["build", "/in/source"],
  :inputs -> source-tree,
  :env -> {},
  :platform -> {"os" -> "linux"},
  :policy -> {:redundancy -> 3},
  :outputs -> ["result"]
})
```

The runtime validates the request and output trees and verifies every blob by
hash. It still does not claim that a sandbox makes execution deterministic.
Before running a request inside a node, pp asks the installed executor one
question: does this exact request account for every semantic input? A trusted
provider answers cacheable or scripting-only. pp rejects scripting-only work
before the provider executes it.

The bundled Linux provider materializes the declared tool and input trees in a
private working directory and supplies only the request's explicit environment
to its direct child. This is not OS namespace isolation: absolute filesystem
access, the ELF interpreter and shared-library loader, network access,
subprocess creation, and other kernel interfaces remain host-mediated. It
still exposes clock, randomness, CPU/kernel behavior, and resource limits, so
it honestly classifies every request as scripting-only. This makes it useful for
portable release actions without making their results silently cacheable.

== Policy belongs to libraries and providers

The classification is the whole core interface; pp does not interpret
`:platform` or `:policy`. Policy is optional canonical pp data, default `{}`
. A Nix-like provider defines its schema, verifies requests against it, and
classifies them cacheable; macros construct the request values. No AST form
or evaluator change required.

An application manifest may provide `:execution-policy` as the default for
requests that omit `:policy`. An explicit request policy always wins. The
runtime preserves policy data and asks the trusted executor whether the exact
request is cacheable; pp libraries define the policy vocabulary.

`stdlib/dune.pp` demonstrates the split. `dune-build(:working-tree, spec)` lets
Dune incrementally build an observed development tree and returns a canonical
artifact tree. `dune-build(:closed-source, spec)` sends the corresponding
immutable request to `run-closed!`. Dune targets, build-directory rules,
platform constraints, and output selection stay in the library.

This is the modular boundary: pp supplies lazy nodes, content identity,
capabilities, traces, scheduling, and reconciliation. Integrations supply
ordinary values and trusted providers.
