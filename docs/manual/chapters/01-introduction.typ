#import "/lib.typ": example

= Introduction

pp is a content-addressed, capability-scoped Lisp: one evaluation model for
work usually split among build systems, supervisors, and orchestrators — each
managing computations, dependencies, reuse, and effects. pp supplies that
substrate; toolchains and domain policy stay ordinary libraries and narrow
trusted providers.

Two ideas carry the design. Every value has a content hash, so two
computations with the same code and inputs are the same computation. Side
effects require capabilities: unforgeable tokens granted only at the command
line. Everything else follows.

The fastest way to learn pp is to read it running: every example is a real
program run by the manual build; the output shown is what it printed. The
smallest example:

#example("hello")

The output appears below the command because the manual ran that file. If an
example ever stopped producing the output shown, the build for this page would
have failed.

That extends to mistakes. pp checks optional type annotations when a body
runs; feed one the wrong type and it says so, naming the value:

#example("type-error")

Errors throughout this manual are provoked and shown, not described.

== How to read this manual

The chapters move from the surface inward: values, bindings, functions,
laziness, then the effect-and-capability system, then the build substrate —
nodes and the store, foreign execution, modules and islands, domains and the
reconciler, distribution. Each construct gets a sentence of motivation, then
a run.
