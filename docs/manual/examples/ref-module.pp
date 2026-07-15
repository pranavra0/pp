# A module is a block whose definitions become a value; `import` merges that
# value's exports into the current scope. The module's body is a fresh scope.
let (geometry = module {
  def double(x) { x * 2 }
  let tau = 6
}) {
  import(geometry)
  print(double(tau))
}
