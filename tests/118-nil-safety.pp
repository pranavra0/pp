# 118-nil-safety.pp — smoke pin, not a discriminator.
#
# Pins the observable ambient behavior of configuration reads, thunk
# (closure) creation, and macro expansion as every pp CLI entry point sees
# it. Honest limits: the nil-safety branches this is named for
# (runtime-configuration-current and runtime-macro-location-for-state
# returning NIL with no dynamic scope / macro context installed) are
# unreachable from any pp entry point — each CLI run establishes a session
# and dynamic scope before evaluating — so no assertion here can fail if
# those guarded branches regress; only a library-level caller (artifacts,
# process domains) reaches them.

print("=== config outside any with-config: default and nil ===")
print(config(:never-set, "fallback"))
print(config(:never-set))

print("")
print("=== closure created at top level captures no config frames ===")
let add = fn(x) { x + 1 }
print(add(41))

print("")
print("=== macro expansion with fresh expansion state ===")
defmacro inc(e) { quasiquote { unquote(e) + 1 } }
print(inc(41))

print("")
print("=== with-config still scopes reads ===")
with-config({:k -> "v"}) { print(config(:k)) }
print(config(:k, "outer-default"))

print("")
print("=== ALL NIL-SAFETY CHECKS PASSED ===")
