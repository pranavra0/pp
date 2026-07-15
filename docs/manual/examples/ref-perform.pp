# `perform` dispatches to the nearest handler installed by `with-handler`.
# The `handlers:` clause takes a map of keyword -> function pairs.
print(with-handler(handlers: { :double -> fn(x) { x * 2 } }) { perform double(21) })
