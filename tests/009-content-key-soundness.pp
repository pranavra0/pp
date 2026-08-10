# Soundness of the content-addressed thunk key: two things the key omitted.
# pins: LAW-19
#
# The content-addressed key includes captured values and handler reads.
# This regression keeps both dependencies observable across distinct forces.

print("=== D6: closure capture must be part of the key ===")
# make returns a closure capturing x; run wraps its call in a let-thunk.
# run's param `c` binds a closure whose hash ignores the capture, so the
# two calls share an env_hash and the `let (r = c()) { r }` thunk collides.
def make(x) { fn() { x } }
def run(c) { let (r = c()) { r } }
print("d6a =>", run(make(1)))  # expect 1
print("d6b =>", run(make(2)))

print("")
print("=== D17: installed handler must be part of the key ===")
# The `perform ask(0)` thunk is identical across both calls; only the
# ambient handler differs, and the handler is absent from the key.
def ask-run() { let (r = perform ask(0)) { r } }
with-handler(ask = fn(n) { 1 }) { print("d17a =>", ask-run()) }  # expect 1
with-handler(ask = fn(n) { 2 }) { print("d17b =>", ask-run()) }

print("")
print("=== EXPECTED: d6a=1 d6b=2 d17a=1 d17b=2 ===")
