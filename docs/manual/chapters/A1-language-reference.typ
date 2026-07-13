#import "/lib.typ": example

= Language reference

This appendix gives the full detail the language chapter summarized. Each
section covers one construct and shows it running. pp is a Lisp-1: functions and
variables share one namespace, code is parenthesized lists, and evaluation is
inner-first and strict — a form's arguments are values by the time it runs.

The special forms — the syntax the reader treats specially, rather than
ordinary function calls — are: `if`, `do`, `let`, `let*`, `fn`, `def`,
`defnode`, `quote`, `quasiquote` with `unquote` and `unquote-splicing`, `and`,
`or`, `delay`, `force`, `node`, `perform`, `with-handler`, `with-caps`,
`with-config`, `config`, `module`, `import`, `load`, `load-module`, `island`,
and the `:` type annotation. `defmacro` is recognized structurally at the top
level. Everything else is a function.

== Value types

Integers, floats, strings, the booleans `true` and `false`, `nil`, keywords
(`:name`), and quoted symbols (`'name`) are the atoms. `print` shows strings
quoted and prints one value per call.

#example("ref-atoms")

The collections are lists, vectors, maps, and sets, each with its own printed
form.

#example("ref-collections")

== Arithmetic and comparison

`+` and `*` are variadic. `-` and `/` take exactly two arguments. `mod` is the
integer remainder.

#example("ref-arith")

Comparisons are variadic and chain left to right — `(< 1 2 3)` means `1 < 2`
and `2 < 3`.

#example("ref-compare")

== Booleans and conditionals

Only `nil` and `false` are falsy; every other value, including `0`, is truthy.
`and` and `or` short-circuit and return the deciding value rather than a
boolean.

#example("ref-bool")

`if` is an expression that evaluates exactly one branch. The untaken branch
never runs — no effects, no errors.

#example("ref-if")

== Bindings

`let` bindings are mutual: every binding is visible in every right-hand side
and in the body, regardless of the order written.

#example("ref-let")

`let*` is the sequential form. Each binding sees only the ones above it, so a
name may shadow itself.

#example("ref-letstar")

At the top level, `(def name value)` evaluates the value once and binds it;
`(def (name args...) body)` defines a function.

#example("ref-def")

== Functions

`fn` produces an anonymous function; `def` with a list head names one. There is
no loop keyword — recursion is the loop, and both back ends run tail calls in
constant stack.

#example("ref-fn")

== Sequencing

`do` forces each form in order for its effects and returns the value of the
last.

#example("ref-do")

== Type annotations

Annotations are optional gradual claims, written with `:`, and checked when the
function's body runs — not before. A well-typed call passes through unchanged.

#example("ref-types")

A mismatch names the offending value and its source location.

#example("ref-type-error")

== Quotation

Quotation is total: any form the reader accepts, `quote` turns into data.
Quasiquote builds structure with holes — `unquote` splices one value,
`unquote-splicing` splices a list.

#example("ref-quote")

== Laziness

`delay` suspends a computation; `force` runs it and memoizes the result, so the
body runs at most once however many times it is forced. `force` is the identity
on non-thunks.

#example("ref-delay")

== Effects and config

`perform` dispatches an effect to the nearest handler installed by
`with-handler`. Handling an effect yourself needs no capability.

#example("ref-perform")

Config is ambient, dynamically-scoped data, distinct from capabilities.
`config` reads a key, with an optional default for when it is absent.

#example("ref-config")

== Macros

`defmacro` defines a macro: it receives its arguments as unevaluated forms and
returns a new form, expanded before either back end sees it. Quasiquote is the
usual way to assemble the expansion.

#example("ref-defmacro")

== Modules

A module is a block whose definitions become a value. `import` merges that
value's exports into the current scope; a module's own body is a fresh scope.

#example("ref-module")

== Lists

The core list operations are builtins and need no library: `list`, `cons`,
`car`, `cdr`, and `map`.

#example("ref-list-ops")

`stdlib/list.pp` adds the higher-order functions — `foldl`, `foldr`, `filter`,
`range`, `take`, `drop`, `reverse`, `length`, `nth`, `append`, `member?`, and
`each`. A program loads it with `(load "stdlib/list.pp")`.

#example("ref-list-stdlib", sh: true)

== Maps

Maps are immutable. The builtins construct one (`hash-map`), look up a key
(`hash-map-get`), and return new maps or their components (`map-insert`,
`map-remove`, `map-keys`, `map-vals`).

#example("ref-map-ops")

`stdlib/map.pp` adds `map-has?` and `map-merge` on top of those builtins; it
depends on `stdlib/list.pp`, so load that first.

#example("ref-map-stdlib", sh: true)

== Strings

The string builtins cover appending, length, splitting, substrings, index-of,
trimming, and conversion to and from numbers.

#example("ref-string-ops")

`stdlib/string.pp` adds `string-join`, `starts-with?`, `ends-with?`, and
`lines`.

#example("ref-string-stdlib", sh: true)

== Type predicates

Each predicate forces its argument and tests its shape. The full set is
`int?`, `float?`, `string?`, `bool?`, `keyword?`, `symbol?`, `pair?`,
`vector?`, `map?`, `set?`, and `fn?`.

#example("ref-predicates")
