# Soundness of the content-addressed thunk key: two things the key omitted.
# pins: LAW-19
#
# Regression test: before the fix, the evaluator returned d6b=1 and
# d17b=1 — stale cache hits instead of the correct new values.
#
# The evaluator memoizes thunks in a global content-addressed table
# (evaluator.ml make_thunk_ca / thunk_store). The key is
# hash(expr, env.env_hash, caps, cfg)
# Two independent things the computation actually depends on are missing
# from that key, so distinct computations collide and the SECOND one
# silently returns the FIRST one's cached result:
#
# Bug 1 — env.env_hash folds in hash_value(closure), and a closure's hash
# OMITS its captured environment (identity.ml VClosure case:
# "Env deliberately NOT hashed"). Two closures with identical
# code but different captures hash identically, so an enclosing
# let-thunk collides.
#
# Bug 2 — the key omits handler_stack entirely. The same `perform ...`
# thunk forced under two different handlers collides.
#
# The bug is a live divergence the fuzzer never reached — its grammar does
# not generate def + captured-closure/handler + let nesting.

print("=== D6: closure capture must be part of the key ===")
# make returns a closure capturing x; run wraps its call in a let-thunk.
# run's param `c` binds a closure whose hash ignores the capture, so the
# two calls share an env_hash and the `let (r = c()) { r }` thunk collides.
def make(x) { fn() { x } }
def run(c) { let (r = c()) { r } }
print("d6a =>", run(make(1)))  # expect 1
print("d6b =>", run(make(2)))  # expect 2  (tree-walker currently prints 1)

print("")
print("=== D17: installed handler must be part of the key ===")
# The `perform ask(0)` thunk is identical across both calls; only the
# ambient handler differs, and the handler is absent from the key.
def ask-run() { let (r = perform ask(0)) { r } }
with-handler(ask = fn(n) { 1 }) { print("d17a =>", ask-run()) }  # expect 1
with-handler(ask = fn(n) { 2 }) { print("d17b =>", ask-run()) }  # expect 2  (tree-walker currently prints 1)

print("")
print("=== EXPECTED: d6a=1 d6b=2 d17a=1 d17b=2 ===")
