# A side effect is a `perform` that dispatches to the nearest handler.
# This needs no capability: the authority model governs effects that touch
# the world, not ones you handle yourself. The `handlers:` clause takes a
# map-valued block — `{ :name -> fn, ... }`.
print(with-handler(handlers: { :ask -> fn(q) { 42 } }) { perform ask("the answer?") })
