#import "/lib.typ": example

= The language in brief

Enough pp to read the rest of the manual. pp is a Lisp-1: functions and
variables share one namespace; evaluation is inner-first and strict. The
language reference appendix has every form in full.

== Values

pp has the atoms you expect: integers and floats, strings, the booleans `true`
and `false`, `nil`, keywords like `:host`, and quoted symbols like
`quote { name }`. Arithmetic and comparison are variadic. `if` is an
expression: it returns a value.

#example("hello")

== Bindings

`let` introduces local bindings. They are mutual: every binding sees every
other, whatever the order. For top-down behaviour use `let*`.

#example("lang-bindings")

Both bind names to right-hand-side values. `def` does the same at top level,
and also defines functions.

== Functions

A definition and a function value are the same idea written two ways: `def`
names one, `fn` produces one anonymously. No loop keyword: recursion is the
loop, and tail calls do not grow the stack.

#example("lang-functions")

== Types

Type annotations are optional, checked when a function's body runs. A
mismatch names the value and location:

#example("type-error")

== Laziness

`delay` builds a thunk: a computation that has not run yet. `force` runs it and
memoizes the result. The work happens at most once, however many times you
force it.

#example("lang-laziness")

Two identical thunks with the same inputs and environment are the same thunk:
computed once, shared everywhere. Wrapping a computation in `node` (next
chapter) extends that sharing across runs of the program.

== Effects and handlers

Side effects go through `perform`, which dispatches to the nearest enclosing
handler. Handling an effect needs no capability; only effects that touch the
world fall under the authority model (capabilities chapter).

#example("lang-effects")

== Config

Config is ambient, dynamically scoped data any code in extent can read —
deliberately not a capability. Config is information; capabilities are
authority.

#example("lang-config")

That is the surface. Everything from here on is about what happens when you wrap
a computation in `node` and give pp the authority to act on the world.
