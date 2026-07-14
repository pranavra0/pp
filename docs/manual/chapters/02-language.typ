#import "/lib.typ": example

= The language in brief

This chapter is enough pp to read the rest of the manual. pp is a Lisp-1:
functions and variables share one namespace, and evaluation is inner-first and
strict. The language reference appendix has the full detail of every form.
Here is the working subset.

== Values

pp has the atoms you expect: integers and floats, strings, the booleans `true`
and `false`, `nil`, keywords like `:host`, and quoted symbols like
`quote { name }`. Arithmetic and comparison are variadic. `if` is an
expression: it returns a value.

#example("hello")

== Bindings

`let` introduces local bindings. They are mutual: every binding can see every
other, whatever order you write them in. For the ordinary top-down behaviour,
where each binding sees only the ones above it, use `let*`.

#example("lang-bindings")

Both forms bind names to the values of their right-hand sides. `def` does the
same at the top level, and also defines functions.

== Functions

A function definition and a function value are the same idea written two ways.
`def` names one; `fn` produces one anonymously. There is no loop keyword:
recursion is the loop. Both back ends eliminate tail calls, so recursion does
not grow the stack.

#example("lang-functions")

== Types

Type annotations are optional. When present, pp checks them at the moment a
function's body runs, not before. A mismatch names the offending value and
location:

#example("type-error")

== Laziness

`delay` builds a thunk: a computation that has not run yet. `force` runs it and
memoizes the result. The work happens at most once, however many times you
force it.

#example("lang-laziness")

This is more than a convenience. Two identical thunks with the same inputs and
environment are the same thunk: computed once, shared everywhere. Wrapping a
computation in `node` (the next chapter) extends that sharing across separate
runs of the program.

== Effects and handlers

Side effects go through `perform`, which dispatches to the nearest enclosing
handler. Handling an effect yourself needs no capability. The authority model
in the chapter on capabilities governs only the effects that reach out and touch
the world.

#example("lang-effects")

== Config

Config is ambient data: dynamically scoped values that any code in the dynamic
extent can read. It is deliberately not a capability. Config is information,
capabilities are authority, and the manual keeps them apart.

#example("lang-config")

That is the surface. Everything from here on is about what happens when you wrap
a computation in `node` and give pp the authority to act on the world.
