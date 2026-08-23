# M3 pure parity: function/value definitions, modules/import, and a macro.
def add(x, y) { x + y }
print(add(2, 3))
defmacro inc(x) { quasiquote { unquote(x) + 1 } }
print(inc(4))
let m = module {
  def twice(x) { x * 2 }
}
import(m)
print(twice(3))
