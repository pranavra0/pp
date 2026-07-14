#import "/lib.typ": example

= Language reference

This appendix gives the full detail the language chapter summarized. Each
section covers one construct and shows it running. pp is a Lisp-1: functions and
variables share one namespace, and evaluation is inner-first and strict — a
form's arguments are values by the time it runs.

The special forms — the syntax the reader treats specially, rather than
ordinary function calls — are: `if`, `do`, `let`, `let*`, `fn`, `def`,
`defnode`, `quote`, `quasiquote` with `unquote` and `unquote-splicing`, `and`,
`or`, `delay`, `force`, `node`, `perform`, `with-handler`, `with-caps`,
`with-config`, `config`, `module`, `import`, `load`, `load-module`, `island`,
and the `:` type annotation. `defmacro` is recognized structurally at the top
level. Everything else is a function.

== Value types

Integers, floats, strings, the booleans `true` and `false`, `nil`, keywords
(`:name`), and quoted symbols (`quote { name }`) are the atoms. `print` shows
strings quoted and prints one value per call.

#example("ref-atoms")

The collections are lists, vectors, maps, and sets, each with its own printed
form.

#example("ref-collections")

== Arithmetic and comparison

`+` and `*` are variadic. `-` and `/` take exactly two arguments. `mod` is the
integer remainder.

#example("ref-arith")

Comparisons are variadic and chain left to right — `<(1, 2, 3)` means `1 < 2`
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

At the top level, `let name = value` evaluates the value once and binds it;
`def name(args…) { body }` defines a function.

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

Braces are pp's surface syntax; s-expressions are its AST. `quote { ... }` is
the bridge: it turns the one form inside into that AST, as data. This is the
same position Elixir takes — homoiconicity lives at the AST layer, not the
surface. The brace text you type is not itself a data structure, but the tree
it reads to is, and `quote` hands you that tree. Quotation is total: any form
the reader accepts, `quote` turns into data.

Quasiquote builds structure with holes. The body of `quasiquote { ... }` is a
template written in ordinary brace syntax, denoting the s-expression data it
reads to; `unquote(e)` fills one hole with a computed value, `splice(e)`
splices a list into a list position.

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

`defmacro` defines a macro: it receives its arguments as unevaluated forms —
s-expression data, the same trees `quote` yields — and returns a new form,
expanded before either back end sees it. You write the macro in braces; it
consumes and produces the AST. A `quasiquote { ... }` template is the usual
way to assemble the expansion: ordinary brace syntax with `unquote(e)` holes
where the caller's forms go.

#example("ref-defmacro")

Because a macro's real domain is the AST, the s-expression notation remains a
first-class way to write one: a `.ppl` file is the same language in AST-native
form — `pp` reads it with the s-expression reader, and the template
#raw("`(if ,test nil ,body)") there builds the identical tree the brace
template above does. Data operations work on either origin: where quasiquote
gets awkward, assemble the form directly with `list`/`cons` —
`list(quote { + }, x, x)` is a complete macro body. `gensym` supplies fresh
names for any binding a macro introduces; pp macros are unhygienic, so the
discipline is manual.

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
`each`. A program loads it with `load("stdlib/list.pp")`.

#example("ref-list-stdlib", sh: true)

== List and vector literals

The brace surface distinguishes lists from vectors at the literal level. A bare
`[...]` produces a list, while `vec[...]` produces a vector. Both support
spread to splice an existing collection:

#table(
  columns: (auto, 1fr),
  inset: (x: 6pt, y: 4pt),
  align: (left, left),
  stroke: (x: none, y: 0.5pt + luma(220)),
  table.header([*Form*], [*Meaning*]),
  [`[a, b, c]`], [List literal `(list a b c)`],
  [`vec[a, b, c]`], [Vector literal `(vector a b c)`],
  [`[head, ...tail]`], [Spread: `cons(head, tail)` — only at trailing position],
)

#example("ref-list-vec-literals")

== Maps

Maps are immutable. The builtins construct one (`hash-map`), look up a key
(`hash-map-get`), and return new maps or their components (`map-insert`,
`map-remove`, `map-keys`, `map-vals`).

#example("ref-map-ops")

`stdlib/map.pp` adds `map-has?` and `map-merge` on top of those builtins; it
depends on `stdlib/list.pp`, so load that first.

#example("ref-map-stdlib", sh: true)

== Index access

Bracket indexing works on maps and vectors, lowering to the appropriate
builtin. A numeric key calls `vector-get`; any other key calls `hash-map-get`.

#table(
  columns: (auto, 1fr),
  inset: (x: 6pt, y: 4pt),
  align: (left, left),
  stroke: (x: none, y: 0.5pt + luma(220)),
  table.header([*Form*], [*Meaning*]),
  [`m[:key]`], [`hash-map-get(m, :key)` — map lookup],
  [`v[0]`], [`vector-get(v, 0)` — vector index],
)

#example("ref-index-access")

== Map update

The update syntax produces a new map with one or more keys inserted or
replaced, without mutating the original.

#table(
  columns: (auto, 1fr),
  inset: (x: 6pt, y: 4pt),
  align: (left, left),
  stroke: (x: none, y: 0.5pt + luma(220)),
  table.header([*Form*], [*Meaning*]),
  [`{ m | k1 -> v1, k2 -> v2 }`], [Nested `map-insert`: `map-insert(map-insert(m, k1, v1), k2, v2)`],
)

#example("ref-map-update")

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

== The cond conditional

`cond` is a multi-way conditional that lowers to nested `if` expressions.
Each arm pairs a test with a result separated by `=>`. The last arm should
use `true` as its test to serve as the else clause.

#table(
  columns: (auto, 1fr),
  inset: (x: 6pt, y: 4pt),
  align: (left, left),
  stroke: (x: none, y: 0.5pt + luma(220)),
  table.header([*Form*], [*Meaning*]),
  [`cond { t1 => r1; t2 => r2 }`], [Nested `if`: `if t1 { r1 } else { if t2 { r2 } }`],
  [`cond { ...; true => r }`], [Else clause: the `true` arm acts as the final branch],
)

#example("ref-cond")

== Spread in lists

The `...` prefix splices a collection into a list or vector literal. Spread is
only allowed as the last element.

#table(
  columns: (auto, 1fr),
  inset: (x: 6pt, y: 4pt),
  align: (left, left),
  stroke: (x: none, y: 0.5pt + luma(220)),
  table.header([*Form*], [*Meaning*]),
  [`[a, ...rest]`], [`cons(a, rest)`],
  [`vec[a, ...rest]`], [`cons(a, rest)` in vector context],
  [`[a, b, ...more]`], [`cons(a, cons(b, more))`],
)

#example("ref-spread")

== Observation sigils

The `$` sigil introduces world observations — reads that cross the boundary
between pure computation and the outside world. Every observation records
the corresponding trace cell, making it visible to the cache-validity system.

#table(
  columns: (auto, 1fr, auto),
  inset: (x: 6pt, y: 4pt),
  align: (left, left, left),
  stroke: (x: none, y: 0.5pt + luma(220)),
  table.header([*Form*], [*Lowering*], [*Trace cell*]),
  [`$file("path")`], [`slurp("path")`], [`file:`],
  [`$env("VAR")`], [`env-get("VAR")`], [`env:`],
  [`$env("VAR", "default")`], [`if nil?(env-get("VAR")) "default" env-get("VAR")`], [`env:`],
  [`$glob("pattern")`], [`list-dir("pattern")`], [`tree:`],
  [`$probe("name")`], [`probe("name")`], [`probe:`],
  [`$secret("path")`], [`slurp("path")`], [`sealed:`],
)

#example("ref-sigils")

== Error propagation: try

The `try` block introduces a region where bindings unwrap `[:ok, v]` /
`[:err, e]` pairs automatically. Each `name <- expr` extracts the value on
success or propagates the error on failure. A trailing `?` on an expression
does the same inline.

Inside a `try` block, `let name = expr?` is equivalent to `name <- expr`.
The block's last expression is the overall value (reachable only when every
binding succeeded).

#table(
  columns: (auto, 1fr),
  inset: (x: 6pt, y: 4pt),
  align: (left, left),
  stroke: (x: none, y: 0.5pt + luma(220)),
  table.header([*Form*], [*Meaning*]),
  [`try { a <- f(); body }`], [Bind `a` to the unwrapped value; propagate on `:err`],
  [`try { let x = g()?; body }`], [Same, using the `?` suffix],
  [`try { body }`], [Plain body — no unwrapping, evaluates as usual],
)

#example("ref-try")

== Collecting results

`collect` is a plain function used in pipelines: it partitions a list of
`[:ok, v]` / `[:err, e]` results, returning `[:ok, values]` if every element
succeeded or `[:err, errors]` if any failed. It is the validation counterpart
to `try` — where `try` short-circuits at the first error, `collect` runs
everything and accumulates. There is no `collect { }` block form.

#table(
  columns: (auto, 1fr),
  inset: (x: 6pt, y: 4pt),
  align: (left, left),
  stroke: (x: none, y: 0.5pt + luma(220)),
  table.header([*Form*], [*Meaning*]),
  [`srcs |> map(f) |> collect`], [`[:ok, [v…]]` if all ok, else `[:err, [e…]]`],
)

#example("ref-collect")
