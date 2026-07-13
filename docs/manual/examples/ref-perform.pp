# `perform` dispatches to the nearest handler installed with `with-handler`.
print(with-handler(double = fn(x) { x * 2 }) { perform double(21) })
