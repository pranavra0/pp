# tests/039 — global-scope holes: a bare top-level do-block binds
# its defs as local slots (never globals), and a module body evaluates as
# a fresh closure so sibling defs resolve like letrec*.
#
# (a) a bare top-level `do { def x ... ... }` must keep its defs
# BLOCK-LOCAL — visible inside the `do`, gone once it closes
# (evaluator.ml EDo threads a local env_ref that is never merged back
# into the caller).
# (b) module-body expressions (including value defs) must see EARLIER
# siblings defined in the SAME module body — a function def, a value
# def, and a bare statement may all reference names bound earlier in
# the module (evaluator.ml EModule folds env_acc left-to-right).
#
# This file is checked against its expected-output oracle by
# scripts/run-tests.sh.

# ---- (b) module-body sibling references ----
import(module {
  def base(n) { n + 1 }
  def double(n) { 2 * base(n) }
  let a = 10
  let b = a + double(a)
  print(b + double(b)) })
print(double(20))
print(b)

# ---- (a) bare top-level do-with-def is block-local ----
# scoped-x is visible only inside the do; referencing it afterward is an
# unbound-symbol error (before the fix, the name leaked into globals and
# this last line printed 111 instead of erroring).
do { let scoped-x = 111; print(scoped-x) }
print(scoped-x)
