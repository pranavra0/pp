#import "/lib.typ": example

= Introduction

pp is a content-addressed, capability-scoped Lisp. It is an experiment in using
one evaluation model for work usually split among build systems, supervisors,
and orchestrators. Each manages computations, dependencies, reuse, and effects.
pp supplies that substrate; toolchains and domain policy remain ordinary
libraries and narrow trusted providers.

Two ideas carry the whole design. First, every value has a content hash. So two
computations with the same code and inputs are the same computation. Second,
side effects require capabilities: unforgeable tokens, granted only at the
command line, that code must hold to touch the world. Everything else in this
manual follows from those two ideas.

The fastest way to learn pp is to read it running. Every example here is a real
program run by the manual build. The output shown is what it
actually printed. Here is the smallest example: values, a conditional, and
arithmetic.

#example("hello")

The output appears below the command because the manual ran that file. If an
example ever stopped producing the output shown, the build for this page would
have failed.

That extends to mistakes. pp checks optional type annotations when a function's
body runs. Feed one the wrong type and it says so, naming the offending value:

#example("type-error")

You will see errors this way throughout the manual: provoked and shown, not
described. So you know exactly what pp does when something is wrong, not just
when everything is right.

== How to read this manual

The chapters move from the surface inward. Values, bindings, and functions
come first, then laziness, then the effect-and-capability system that governs
side effects. From there the manual turns to what makes pp a build substrate:
content-addressed nodes and the store, foreign execution, modules and islands,
domains and the reconciler, and finally distribution. We introduce each
construct, give a sentence or two of motivation, then show it by running it.
