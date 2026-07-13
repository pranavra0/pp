# tests/039 — D22: VM global-scope holes (fixed; STATUS.md D22).
#
# Both come from the VM resolving names it cannot place in a frame via the
# globals table:
# (a) a bare top-level `(do (def x ...) ...)` must keep its defs
# BLOCK-LOCAL — visible inside the `do`, gone once it closes — exactly
# like the tree-walker (evaluator.ml EDo threads a local env_ref that
# is never merged back into the caller).
# (b) module-body expressions (including value defs) must see EARLIER
# siblings defined in the SAME module body — a function def, a value
# def, and a bare statement may all reference names bound earlier in
# the module, exactly like the tree-walker (evaluator.ml EModule folds
# env_acc left-to-right).
#
# This file is diffed automatically by scripts/run-tests.sh: both backends
# must produce byte-identical stdout+stderr.

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
# unbound-symbol error in BOTH backends (before the fix, the VM leaked it
# into its globals table and this last line printed 111 instead of erroring).
do { let scoped-x = 111; print(scoped-x) }
print(scoped-x)
