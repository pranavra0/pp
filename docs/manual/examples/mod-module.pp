# (module ...) evaluates its body in a fresh scope and produces a value whose
# fields are the names it defined. (import ...) forces that value and merges
# those names into the current scope. Here the module is bound to `geo`, then
# imported, so `area` and `pi` become callable.
let (geo = module {
  let pi = 3.14159
  def area(r) { pi * (r * r) }
}) {
  import(geo)
  print(area(10))
}
