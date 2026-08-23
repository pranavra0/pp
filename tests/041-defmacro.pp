# defmacro: an expected-output test proving macro expansion is total, giving
# metaprogramming without needing fexprs.
#
# Expansion happens at one shared point before evaluation sees a form.
# This test checks observable values only; a cache hit replays no node-body
# log (SPEC law 17). Editing a macro definition re-keys a node built from its
# expansion (SPEC law 20), covered by tests/042-defmacro-rekey.sh.
#
# Authored here in the brace surface, via quote{}/quasiquote{}/
# unquote()/splice() — homoiconicity still lives at the AST layer (`quote`
# yields sexpr data in both surfaces), but a template no longer has to be
# spelled out as hand-nested cons/list calls. tests/041-defmacro.ppl is
# this SAME test, authored in the sexpr surface (the AST-native notation
# `defmacro` has always used); tests/056-defmacro-both-surfaces.sh proves
# the two files produce byte-identical output — a macro author may write
# braces or sexprs and the language does not know the difference.

print("=== control-flow macro (unless), via quasiquote ===")
defmacro unless(cond, then-branch) {
  quasiquote { if unquote(cond) { nil } else { unquote(then-branch) } } }
print(unless(false, 42))  # expect 42
print(unless(true, 42))  # expect nil

print("")
print("=== gensym: a macro's own temp binding must not capture a ===")
print("=== caller variable of the same name (M3 hygiene discipline) ===")
# The macro's gensym prefix is deliberately "tmp" — the SAME name the
# caller binds below. Without gensym, the expansion's own
# `let (tmp = unquote(a)) { ... }` would capture the caller's `tmp`;
# `gensym("tmp")` produces a fresh, unwritable name (e.g. "tmp~3"), so the
# caller's `tmp` (bound to 7) is what `unquote(a)` refers to, not the
# macro's own temporary. This is the same computed-binding-name shape
# quasiquote{} needs `unquote(...)` in a name slot for
# (src/frontend/reader_braces.ml's parse_qq_name_slot) — `unquote(g)` names the
# binding itself, not just its value.
defmacro first-truthy(a, b) {
  let* (g = gensym("tmp")) {
    quasiquote {
      let (unquote(g) = unquote(a)) {
        if unquote(g) { unquote(g) } else { unquote(b) }
      }
    }
  }
}
let (tmp = 7) { print(first-truthy(tmp, 5)) }
# expect 7 (no capture)
print(first-truthy(false, 9))  # expect 9

print("")
print("=== a macro building a (node ...) form ===")
defmacro memo(e) { quasiquote { force(node { unquote(e) }) } }
print(memo(2 + 3))  # expect 5

print("")
print("=== nested macro use: one macro's expansion calls another macro ===")
defmacro twice(e) { quasiquote { do { unquote(e); unquote(e) } } }
defmacro say-twice(x) { quasiquote { twice(print(unquote(x))) } }
say-twice("hi")  # expect "hi" printed twice

print("")
print("=== macro-generated def ===")
# Another computed-name-slot use of parse_qq_name_slot: `unquote(name)` is
# the def's OWN function name, not one of its arguments.
defmacro defadder(name, n) {
  quasiquote { def unquote(name)(x) { x + unquote(n) } } }
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
