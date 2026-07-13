# defmacro (M3, D10's promise) — differential test.
#
# Expansion happens at ONE shared point before either backend ever sees a
# form (macro.ml), so this file exercises it purely through observable
# VALUES (never node-body `log` side effects — LAW 17's "a hit replays no
# log" would make repeated `dune runtest` runs against a developer's real
# ~/.pp/store flaky if this were a fresh-vs-cached-run distinction; a
# node's printed RESULT is deterministic regardless of hit/miss, so that's
# all this file checks). The LAW 20 rekey property itself — editing a
# macro's definition re-keys a node built from its expansion — is
# tests/042-defmacro-rekey.sh's job, under an isolated $HOME where hit vs.
# miss can be observed directly.

print("=== control-flow macro (unless), via quasiquote ===")
defmacro unless(cond, then-branch) {
  quasiquote(cons(quote { (if) }, cons(list(quote { (unquote) }, cond), cons(quote { nil }, cons(list(quote { (unquote) }, then-branch), quote { nil }))))) }
print(unless(false, 42))  # expect 42
print(unless(true, 42))  # expect nil

print("")
print("=== gensym: a macro's own temp binding must not capture a ===")
print("=== caller variable of the same name (M3 hygiene discipline) ===")
# The macro's gensym prefix is deliberately "tmp" — the SAME name the
# caller binds below. Without gensym, `(let [tmp ,a] ...)` would capture
# the caller's `tmp` inside the expansion; `(gensym "tmp")` produces a
# fresh, unwritable name (e.g. "tmp~3"), so the caller's `tmp` (bound to 7)
# is what `,a` refers to, not the macro's own temporary.
defmacro first-truthy(a, b) {
  let* (g = gensym("tmp")) {
    quasiquote(cons(quote { (let) }, cons([list(quote { (unquote) }, g), list(quote { (unquote) }, a)], cons(cons(quote { (if) }, cons(list(quote { (unquote) }, g), cons(list(quote { (unquote) }, g), cons(list(quote { (unquote) }, b), quote { nil })))), quote { nil })))) } }
let (tmp = 7) { print(first-truthy(tmp, 5)) }
# expect 7 (no capture)
print(first-truthy(false, 9))  # expect 9

print("")
print("=== a macro building a (node ...) form ===")
defmacro memo(e) { quasiquote(cons(quote { (force) }, cons(cons(quote { (node) }, cons(list(quote { (unquote) }, e), quote { nil })), quote { nil }))) }
print(memo(2 + 3))  # expect 5

print("")
print("=== nested macro use: one macro's expansion calls another macro ===")
defmacro twice(e) { quasiquote(cons(quote { (do) }, cons(list(quote { (unquote) }, e), cons(list(quote { (unquote) }, e), quote { nil })))) }
defmacro say-twice(x) { quasiquote(cons(quote { twice }, cons(cons(quote { print }, cons(list(quote { (unquote) }, x), quote { nil })), quote { nil }))) }
say-twice("hi")  # expect "hi" printed twice

print("")
print("=== macro-generated def ===")
defmacro defadder(name, n) {
  quasiquote(cons(quote { (def) }, cons(cons(list(quote { (unquote) }, name), cons(quote { x }, quote { nil })), cons(cons(quote { + }, cons(quote { x }, cons(list(quote { (unquote) }, n), quote { nil }))), quote { nil })))) }
defadder(add10, 10)
print(add10(5))  # expect 15

print("")
print("=== a macro built with list/quote (no quasiquote) ===")
defmacro double(x) { list(quote { + }, x, x) }
print(double(21))  # expect 42

print("")
print("=== redefining a macro changes later expansions ===")
defmacro const-val() { 1 }
print(const-val())  # expect 1
defmacro const-val() { 2 }
print(const-val())  # expect 2

print("")
print("=== EXPECTED: 42 nil / 7 9 / 5 / hi hi / 15 / 42 / 1 2 ===")
